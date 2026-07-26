import 'dart:async';
import 'dart:math' as math;

import '../math3d.dart';
import '../ml/feature_vector.dart';
import '../models/event.dart';
import '../models/node.dart';
import '../models/rescuer.dart';
import 'data_source.dart';

/// Generates a synthetic scenario: a scatter of nodes thrown into a
/// rubble-pile-sized bounding box, with one hidden "survivor" location
/// the algorithm has to find -- not shown anywhere in the UI, only used
/// to bias the synthetic physics, so running Sim mode is an honest test
/// of whether the TDOA/tomography pipeline actually converges on it.
class SimulationService implements DataSource {
  SimulationService({int nodeCount = 7, int? seed})
      : _rng = math.Random(seed);

  final math.Random _rng;
  final _controller = StreamController<Object>.broadcast();
  Timer? _tapTimer;
  Timer? _passiveTimer;
  Timer? _telemetryTimer;
  Timer? _rescuerTimer;

  late List<SensorNode> _nodes;
  late Vec3 _survivor;
  double _rescuerAngle = 0.0;
  static const double _wavespeedMps = 300.0; // rough rubble default

  @override
  Stream<Object> get messages => _controller.stream;

  @override
  Stream<ConnectionStatus> get status => Stream.value(ConnectionStatus.connected);

  @override
  Future<void> start() async {
    _nodes = _scatterNodes(7);
    _survivor = Vec3(
      _rand(-3.5, 3.5),
      _rand(-3.5, 3.5),
      _rand(-1.5, 0.5), // depth: negative-ish = buried
    );

    for (final n in _nodes) {
      _controller.add(n);
    }

    // Telemetry heartbeat: battery/RSSI drift, so the node panel has
    // something to show even between events.
    _telemetryTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      for (final n in _nodes) {
        n.battery = (n.battery - (_rng.nextDouble() * 0.3)).clamp(0, 100).toInt();
        n.rssi = -40 - _rng.nextInt(30);
        n.lastSeen = DateTime.now();
        _controller.add(n);
      }
    });

    // Active mode: rotate the tapper every ~5s, matching the design doc's
    // full-tomographic-coverage rotation.
    var tapperIndex = 0;
    _tapTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final tapper = _nodes[tapperIndex % _nodes.length];
      tapperIndex++;
      _controller.add(_synthesizeTapCycle(tapper));
    });

    // Passive mode: occasional knock/scream bursts, weighted toward nodes
    // near the hidden survivor location (more likely to be heard clearly
    // there), plus rare background false-positive noise elsewhere.
    _passiveTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_rng.nextDouble() < 0.55) {
        _emitPassiveCluster();
      }
    });

    // Rescuer walk: the phone-carrier orbits the pile's perimeter, and
    // each node passively reports how strongly it hears the phone from
    // wherever it currently stands. This is what the "you are here" dot
    // trilaterates from.
    _rescuerTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      _rescuerAngle += 0.15;
      final radius = 5.0 + math.sin(_rescuerAngle * 0.3);
      final rescuerPos = Vec3(
        math.cos(_rescuerAngle) * radius,
        math.sin(_rescuerAngle) * radius,
        1.4, // roughly chest/hand height above the debris surface
      );
      for (final node in _nodes) {
        final distM = node.position.distanceTo(rescuerPos);
        if (distM > 12.0) continue; // out of WiFi range
        // Inverse log-distance path loss plus noise, matching the model
        // rssi_localization.dart expects to invert.
        const txPowerAt1m = -40.0;
        const pathLossExponent = 3.0;
        final dbm = txPowerAt1m - 10 * pathLossExponent * (math.log(distM.clamp(0.3, 100)) / math.ln10) + _rand(-3, 3);
        _controller.add(RescuerRssiSample(nodeId: node.id, dbm: dbm));
      }
    });
  }

  List<SensorNode> _scatterNodes(int count) {
    final nodes = <SensorNode>[];
    nodes.add(SensorNode(
      id: 0,
      position: const Vec3(0, 0, 1.5), // gateway sits up top
      role: NodeRole.gateway,
      battery: 95,
    ));
    for (var i = 1; i <= count; i++) {
      nodes.add(SensorNode(
        id: i,
        position: Vec3(_rand(-4, 4), _rand(-4, 4), _rand(-2, 1)),
        role: NodeRole.listener,
        battery: 70 + _rng.nextInt(30),
      ));
    }
    return nodes;
  }

  TapCycle _synthesizeTapCycle(SensorNode tapper) {
    final arrivals = <int, double>{};
    for (final listener in _nodes) {
      if (listener.id == tapper.id) continue;
      final distM = tapper.position.distanceTo(listener.position);
      var travelMs = (distM / _wavespeedMps) * 1000;

      // If the ray passes near the hidden survivor, add a slowdown --
      // this is what the tomography back-projection should pick up.
      final perpDist =
          _survivor.distanceToSegment(tapper.position, listener.position);
      if (perpDist < 1.0) {
        travelMs *= 1.25 + _rng.nextDouble() * 0.15;
      }
      // Measurement noise
      travelMs += _rand(-0.4, 0.4);

      if (_rng.nextDouble() < 0.85) {
        // not every listener reliably hears every tap through rubble
        arrivals[listener.id] = travelMs.clamp(0.1, double.infinity).toDouble();
      }
    }
    return TapCycle(
      tapperId: tapper.id,
      arrivalMs: arrivals,
      firedAt: DateTime.now(),
    );
  }

  void _emitPassiveCluster() {
    final isReal = _rng.nextDouble() < 0.7; // vs. background noise
    final isKnock = _rng.nextBool();
    final sourcePos = isReal
        ? _survivor
        : Vec3(_rand(-4, 4), _rand(-4, 4), _rand(-2, 1));

    // Only nodes within plausible range hear it; each hears it at a
    // different time based on distance -- this delay spread is exactly
    // what the TDOA solver needs.
    const baseT = 0.0;
    for (final node in _nodes) {
      if (node.role == NodeRole.gateway) continue;
      final distM = node.position.distanceTo(sourcePos);
      if (distM > 10.0) continue;
      if (_rng.nextDouble() > 0.8) continue; // dropped packet / not heard
      final delayMs = baseT + (distM / _wavespeedMps) * 1000 + _rand(-3, 3);

      // Synthesize features a real person-presence model would plausibly
      // see: a genuine knock/scream near the survivor gets clean,
      // characteristic band energy; background noise gets messier,
      // broadband, noisier features -- this is what actually exercises
      // ModelManager.personModel end-to-end in Sim mode, rather than
      // just hardcoding a confidence number.
      final features = isReal
          ? (isKnock
              ? SignalFeatures(
                  durationMs: _rand(40, 130),
                  lowBandEnergy: _rand(0.6, 0.9),
                  midBandEnergy: _rand(0.05, 0.15),
                  vocalBandEnergy: _rand(0.0, 0.1),
                  spectralCentroidHz: _rand(60, 140),
                  zeroCrossingRate: _rand(20, 80),
                  peakAmplitude: _rand(0.5, 1.0),
                )
              : SignalFeatures(
                  durationMs: _rand(220, 500),
                  lowBandEnergy: _rand(0.05, 0.15),
                  midBandEnergy: _rand(0.1, 0.2),
                  vocalBandEnergy: _rand(0.4, 0.7),
                  spectralCentroidHz: _rand(500, 1800),
                  zeroCrossingRate: _rand(150, 350),
                  peakAmplitude: _rand(0.5, 1.0),
                ))
          : SignalFeatures(
              durationMs: _rand(30, 400),
              lowBandEnergy: _rand(0.2, 0.4),
              midBandEnergy: _rand(0.2, 0.4),
              vocalBandEnergy: _rand(0.1, 0.3),
              spectralCentroidHz: _rand(200, 900),
              zeroCrossingRate: _rand(350, 600), // messier, less periodic
              peakAmplitude: _rand(0.2, 0.5),
            );

      _controller.add(RawDetectionSample(
        nodeId: node.id,
        timestampMs: delayMs,
        features: features,
      ));
    }
  }

  double _rand(double lo, double hi) => lo + _rng.nextDouble() * (hi - lo);

  @override
  void stop() {
    _tapTimer?.cancel();
    _passiveTimer?.cancel();
    _telemetryTimer?.cancel();
    _rescuerTimer?.cancel();
    _controller.close();
  }
}