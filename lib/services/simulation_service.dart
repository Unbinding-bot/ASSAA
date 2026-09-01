import 'dart:async';
import 'dart:math' as math;

import '../math3d.dart';
import '../ml/feature_vector.dart';
import '../models/event.dart';
import '../models/node.dart';
import '../models/rescuer.dart';
import '../services/udp_audio_receiver.dart';
import 'data_source.dart';

/// 5-node array layout matching the architecture spec:
///
///   Node 1 (NW) ─────── Node 2 (NE)
///        │          ╲  ╱          │
///        │      Node 0 (centre)   │
///        │          ╱  ╲          │
///   Node 3 (SW) ─────── Node 4 (SE)
///   Node 5 = gateway (elevated, outside the slab)
///
/// Any impact excites a local 3-node triangle.  Nodes on the opposite side
/// of the slab arrive 20–50 ms later — the quadrant selector will drop them
/// automatically, giving the pipeline something real to test against.
///
/// Hidden anomaly regions:
///   _voidPos       — air void: slow V (~1800 m/s), low f_cent, high α → VOID
///   _ambiguousPos  — transitional zone: V 3000–3500 m/s → splits trees → UNKNOWN
///   (rest of slab) — solid concrete: fast V (~3500+ m/s) → SOLID
class SimulationService implements DataSource {
  SimulationService({int? seed}) : _rng = math.Random(seed ?? 42);

  final math.Random _rng;
  final _controller = StreamController<Object>.broadcast();

  Timer? _audioTimer;
  Timer? _tapTimer;
  Timer? _telemetryTimer;
  Timer? _rescuerTimer;

  late List<SensorNode> _nodes;
  late Vec3 _voidPos;
  late Vec3 _ambiguousPos;
  double _rescuerAngle = 0.0;

  int _hwClockUs = 0;
  static const int    _frameUs         = 100 * 100; // 100 samples @ 10 kHz = 10 ms
  static const double _wavespeedMps    = 3400.0;    // concrete ~3400 m/s
  static const double _sampleRateHz    = 10000.0;
  static const int    _samplesPerFrame = 100;

  @override
  Stream<Object> get messages => _controller.stream;

  @override
  Stream<ConnectionStatus> get status =>
      Stream.value(ConnectionStatus.connected);

  @override
  Future<void> start() async {
    _nodes = _buildArray();

    // Anomaly positions — not revealed to the UI, only affect physics.
    _voidPos  = const Vec3( 2.5,  2.5, 0.0); // NE quadrant
    _ambiguousPos = const Vec3(-2.0, -2.0, 0.0); // SW quadrant

    for (final n in _nodes) { _controller.add(n); }

    _emitFtmBursts();

    // Mode 2: piezo audio frames at 10 ms intervals per node.
    _audioTimer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      _hwClockUs += _frameUs;
      _emitAudioFrames();
    });

    // Mode 1: tap cycles every 6 s, rotating tapper through outer nodes.
    var tapIdx = 0;
    _tapTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      // Only outer nodes (1–4) tap; centre node (0) and gateway (5) don't.
      final outerNodes = _nodes.where((n) => n.id >= 1 && n.id <= 4).toList();
      final tapper = outerNodes[tapIdx % outerNodes.length];
      tapIdx++;
      _controller.add(_synthesizeTapCycle(tapper));
      if (_rng.nextDouble() < 0.5) { _emitLegacyCluster(); }
    });

    _telemetryTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      for (final n in _nodes) {
        n.battery  = (n.battery - (_rng.nextDouble() * 0.3)).clamp(0, 100).toInt();
        n.rssi     = -40 - _rng.nextInt(30);
        n.lastSeen = DateTime.now();
        _controller.add(n);
      }
    });

    _rescuerTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      _rescuerAngle += 0.15;
      final r = 5.0 + math.sin(_rescuerAngle * 0.3);
      final rPos = Vec3(math.cos(_rescuerAngle) * r,
                        math.sin(_rescuerAngle) * r, 1.4);
      for (final node in _nodes) {
        final d = node.position.distanceTo(rPos);
        if (d > 12.0) { continue; }
        const tx = -40.0, n = 3.0;
        final dbm = tx - 10 * n * (math.log(d.clamp(0.3, 100)) / math.ln10)
            + _rand(-3, 3);
        _controller.add(RescuerRssiSample(nodeId: node.id, dbm: dbm));
      }
    });
  }

  // ---------------------------------------------------------------------------
  // 5-node array layout
  // ---------------------------------------------------------------------------

  List<SensorNode> _buildArray() {
    const r = 3.5; // radius of outer square (half-side)
    return [
      SensorNode(id: 0, position: const Vec3( 0.0,  0.0, 0.0),
          role: NodeRole.listener, operatingMode: NodeMode.triangulation,
          ftmCapable: true, battery: 90),
      SensorNode(id: 1, position: const Vec3(-r,  r, 0.0),  // NW
          role: NodeRole.listener, operatingMode: NodeMode.triangulation,
          ftmCapable: true, battery: 80 + _rng.nextInt(20)),
      SensorNode(id: 2, position: const Vec3( r,  r, 0.0),  // NE
          role: NodeRole.listener, operatingMode: NodeMode.triangulation,
          ftmCapable: true, battery: 80 + _rng.nextInt(20)),
      SensorNode(id: 3, position: const Vec3(-r, -r, 0.0),  // SW
          role: NodeRole.listener, operatingMode: NodeMode.triangulation,
          ftmCapable: true, battery: 80 + _rng.nextInt(20)),
      SensorNode(id: 4, position: const Vec3( r, -r, 0.0),  // SE
          role: NodeRole.listener, operatingMode: NodeMode.triangulation,
          ftmCapable: true, battery: 80 + _rng.nextInt(20)),
      SensorNode(id: 5, position: const Vec3( 0.0,  0.0, 1.5), // gateway
          role: NodeRole.gateway, operatingMode: NodeMode.triangulation,
          ftmCapable: true, battery: 95),
    ];
  }

  // ---------------------------------------------------------------------------
  // Mode 2: piezo audio frame synthesis
  // ---------------------------------------------------------------------------

  bool   _eventActive          = false;
  int    _eventRemainingFrames = 0;
  late Vec3   _eventSource;
  late String _eventType;
  final Map<int, double> _phaseAcc = {};

  void _emitAudioFrames() {
    if (!_eventActive && _rng.nextDouble() < 0.012) {
      _eventActive = true;
      // Bias source toward one of the anomaly regions for realism.
      final pick = _rng.nextDouble();
      _eventSource = pick < 0.35 ? _voidPos
          : pick < 0.55 ? _ambiguousPos
          : Vec3(_rand(-3, 3), _rand(-3, 3), 0.0);
      _eventType = ['knock', 'knock', 'metallic'][_rng.nextInt(3)];
      _eventRemainingFrames = switch (_eventType) {
        'knock'    => 3 + _rng.nextInt(4),
        'metallic' => 2 + _rng.nextInt(3),
        _          => 5,
      };
    }

    for (final node in _nodes) {
      if (node.role == NodeRole.gateway) { continue; }

      List<double> samples;
      if (_eventActive) {
        final distM     = node.position.distanceTo(_eventSource);
        final delayUs   = (distM / (_wavespeedMps / 1e6)).round();
        samples = _synthesizeEventFrame(node.id, _eventType,
            amplitude: _rand(0.3, 0.85),
            frameTimestampUs: _hwClockUs + delayUs);
      } else {
        samples = _synthesizeNoiseFrame(node.id);
      }

      _controller.add(AudioFrame(
        nodeId:      node.id,
        timestampUs: _hwClockUs,
        samples:     samples,
      ));
    }

    if (_eventActive) {
      _eventRemainingFrames--;
      if (_eventRemainingFrames <= 0) { _eventActive = false; }
    }
  }

  /// Synthesise a decaying sinusoid in the NDT frequency band.
  /// Adds propagation-delay-based phase offset so GCC-PHAT gets a real peak.
  List<double> _synthesizeEventFrame(int nodeId, String type,
      {required double amplitude, required int frameTimestampUs}) {
    final freqHz = switch (type) {
      'knock'    =>  500.0,
      'metallic' => 4000.0,
      _          =>  500.0,
    };
    final decay = switch (type) {
      'knock'    => 0.982,
      'metallic' => 0.970,
      _          => 0.985,
    };

    final phase = _phaseAcc[nodeId] ?? 0.0;
    final omega = 2 * math.pi * freqHz / _sampleRateHz;
    final samples = List<double>.filled(_samplesPerFrame, 0.0);
    var env = amplitude;
    var ph  = phase;
    for (var i = 0; i < _samplesPerFrame; i++) {
      samples[i] = env * math.sin(ph) + _rand(-0.008, 0.008);
      ph  += omega;
      env *= decay;
    }
    _phaseAcc[nodeId] = ph % (2 * math.pi);
    return samples;
  }

  List<double> _synthesizeNoiseFrame(int nodeId) =>
      List<double>.generate(_samplesPerFrame, (_) => _rand(-0.01, 0.01));

  // ---------------------------------------------------------------------------
  // Mode 1: tap cycle synthesis with realistic NDT waveforms
  // ---------------------------------------------------------------------------

  TapCycle _synthesizeTapCycle(SensorNode tapper) {
    final arrivals = <int, double>{};

    for (final listener in _nodes) {
      if (listener.id == tapper.id || listener.role == NodeRole.gateway) {
        continue;
      }
      final distM = tapper.position.distanceTo(listener.position);

      // Determine material between tapper and listener.
      final midpoint = Vec3(
        (tapper.position.x + listener.position.x) / 2,
        (tapper.position.y + listener.position.y) / 2,
        0.0,
      );
      final toVoid  = midpoint.distanceTo(_voidPos);
      final toDelam = midpoint.distanceTo(_ambiguousPos);

      double effectiveVelocity;
      if (toVoid < 1.5) {
        effectiveVelocity = _wavespeedMps * _rand(0.45, 0.58); // ~1530–1972 m/s → VOID
      } else if (toDelam < 1.5) {
        effectiveVelocity = _wavespeedMps * _rand(0.88, 1.03); // ~2992–3502 m/s → borderline UNKNOWN
      } else {
        effectiveVelocity = _wavespeedMps * _rand(1.03, 1.12); // ~3502–3808 m/s → SOLID
      }

      var travelMs = (distM / effectiveVelocity) * 1000.0 + _rand(-0.2, 0.2);

      if (_rng.nextDouble() < 0.88) {
        arrivals[listener.id] =
            travelMs.clamp(0.05, double.infinity).toDouble();
      }
    }

    return TapCycle(
      tapperId: tapper.id,
      arrivalMs: arrivals,
      firedAt:  DateTime.now(),
    );
  }

  // ---------------------------------------------------------------------------
  // FTM bursts
  // ---------------------------------------------------------------------------

  void _emitFtmBursts() {
    const burstCount = 5;
    const c = 299792458.0;

    for (var i = 0; i < _nodes.length; i++) {
      for (var j = i + 1; j < _nodes.length; j++) {
        final a = _nodes[i];
        final b = _nodes[j];
        final distM   = a.position.distanceTo(b.position);
        final jitterNs = _rng.nextInt(3) - 1;

        const t1 = 100000000;
        final oneWayNs = (distM / c * 1e9).round();
        final t2 = t1 + oneWayNs + jitterNs;
        final t3 = t2 + 50000;
        final t4 = t3 + oneWayNs + jitterNs;

        for (var k = 0; k < burstCount; k++) {
          _controller.add(FtmMeasurement(
            initiatorId: a.id, responderId: b.id,
            t1Ns: t1, t2Ns: t2, t3Ns: t3, t4Ns: t4,
          ));
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Legacy RawDetectionSample path (exercises the DetectionEvent pipeline)
  // ---------------------------------------------------------------------------

  void _emitLegacyCluster() {
    final isKnock   = _rng.nextBool();
    // Bias source toward an anomaly so quadrant selection has something to find.
    final sourcePos = _rng.nextDouble() < 0.6 ? _voidPos : _ambiguousPos;
    const baseT = 0.0;

    for (final node in _nodes) {
      if (node.role == NodeRole.gateway) { continue; }
      final distM = node.position.distanceTo(sourcePos);
      if (distM > 8.0 || _rng.nextDouble() > 0.82) { continue; }
      final delayMs = baseT + (distM / (_wavespeedMps / 1000)) + _rand(-1, 1);

      final features = isKnock
          ? SignalFeatures(
              durationMs: _rand(40, 120),
              lowBandEnergy: _rand(0.55, 0.85),
              midBandEnergy: _rand(0.05, 0.15),
              vocalBandEnergy: _rand(0.0, 0.08),
              spectralCentroidHz: _rand(80, 200),
              zeroCrossingRate: _rand(15, 60),
              peakAmplitude: _rand(0.4, 0.9),
            )
          : SignalFeatures(
              durationMs: _rand(20, 80),
              lowBandEnergy: _rand(0.2, 0.45),
              midBandEnergy: _rand(0.25, 0.45),
              vocalBandEnergy: _rand(0.05, 0.15),
              spectralCentroidHz: _rand(800, 3000),
              zeroCrossingRate: _rand(80, 250),
              peakAmplitude: _rand(0.3, 0.8),
            );

      _controller.add(RawDetectionSample(
        nodeId:      node.id,
        timestampMs: delayMs,
        features:    features,
      ));
    }
  }

  double _rand(double lo, double hi) => lo + _rng.nextDouble() * (hi - lo);

  @override
  void stop() {
    _audioTimer?.cancel();
    _tapTimer?.cancel();
    _telemetryTimer?.cancel();
    _rescuerTimer?.cancel();
    if (!_controller.isClosed) { _controller.close(); }
  }
}
