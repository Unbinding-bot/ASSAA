import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../math3d.dart';
import '../ml/feature_vector.dart';
import '../models/event.dart';
import '../models/node.dart';
import '../models/rescuer.dart';
import 'data_source.dart';

/// Connects to the gateway node's WebSocket and translates its JSON
/// protocol into the shared message stream.
///
/// -----------------------------------------------------------------------
/// INBOUND PROTOCOL  (gateway → phone)
/// -----------------------------------------------------------------------
///
///  TELEMETRY
///   {"type":"telemetry","node":2,"battery":87,"rssi":-52,
///    "x":1.2,"y":0.4,"z":-0.3,"role":"listener",
///    "mode":"triangulation","ftm":true}
///
///  MODE 2 — passive acoustic (pre-classified, legacy fallback)
///   {"type":"detection","node":4,"kind":"knock","ms":812.0,
///    "amplitude":0.71,"confidence":0.9}
///
///  MODE 2 — passive acoustic (preferred: raw features, phone classifies)
///   {"type":"detection_raw","node":4,"ms":812.0,"durationMs":95,
///    "lowBand":0.6,"midBand":0.1,"vocalBand":0.05,"centroidHz":80,
///    "zcr":12.5,"peakAmp":0.71}
///
///  MODE 1 — active impactor tap-data  (NEW, doc §3.2)
///   {"type":"tap_data","node":3,"tapper":3,
///    "piezo_t0":123456,"samples":[...150 int16s...]}
///   Note: "tapper" is the node that actuated the servo.  When another
///   node sends tap_data it is a LISTENER reporting its own accel frame
///   for the same tap cycle; "tapper" tells the app which tap cycle this
///   belongs to.
///
///  LEGACY active-mode helpers (still accepted for older firmware)
///   {"type":"tap","tapper":3,"t0":123456}
///   {"type":"arrival","node":5,"tapper":3,"ms":6.8}
///
///  FTM calibration result  (NEW, doc §5.1)
///   {"type":"ftm","initiator":1,"responder":2,
///    "t1":100000,"t2":100150,"t3":100200,"t4":100380}
///
///  Rescuer RSSI
///   {"type":"rescuer_rssi","node":6,"dbm":-58}
///
///  Heartbeat reply
///   {"type":"pong","t":123456}
///
/// -----------------------------------------------------------------------
/// OUTBOUND PROTOCOL  (phone → gateway)
/// -----------------------------------------------------------------------
///
///  {"type":"ping","t":123456}            — heartbeat
///  {"type":"set_mode","mode":1}          — switch all nodes to Mode 1
///  {"type":"set_mode","mode":2}          — switch all nodes to Mode 2
///  {"type":"trigger_tap","node":3}       — fire servo on node 3
///  {"type":"start_ftm","nodeA":1,"nodeB":2} — request FTM burst
/// -----------------------------------------------------------------------
class GatewayService implements DataSource {
  GatewayService(this.uri);
  final Uri uri;

  final _controller = StreamController<Object>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  // --- Legacy tap-cycle assembly (for old firmware sending "tap"/"arrival") ---
  int? _openTapperId;
  DateTime? _openTapFiredAt;
  final Map<int, double> _openArrivals = {};
  Timer? _flushTimer;

  // --- New tap_data assembly: collect accel frames per tap cycle ---
  // Key: tapper node ID.  Value: map of listener nodeId → TapData.
  final Map<int, Map<int, TapData>> _openTapData = {};
  Timer? _tapDataFlushTimer;

  @override
  Stream<Object> get messages => _controller.stream;

  @override
  Stream<ConnectionStatus> get status => Stream.value(ConnectionStatus.connected);

  @override
  Future<void> start() async {
    _channel = WebSocketChannel.connect(uri);
    _sub = _channel!.stream.listen(
      _handleFrame,
      onError: (e) => _controller.addError(e),
      onDone: () => _controller.close(),
    );
  }

  void _handleFrame(dynamic raw) {
    try {
      _parseAndDispatch(raw);
    } catch (_) {
      // Drop malformed frame, keep listening.
    }
  }

  void _parseAndDispatch(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;

    switch (msg['type']) {
      // ------------------------------------------------------------------
      case 'telemetry':
        _controller.add(SensorNode(
          id: msg['node'] as int,
          position: Vec3(
            (msg['x'] as num).toDouble(),
            (msg['y'] as num).toDouble(),
            (msg['z'] as num).toDouble(),
          ),
          role: _roleFromString(msg['role'] as String?),
          operatingMode: _modeFromString(msg['mode'] as String?),
          ftmCapable: (msg['ftm'] as bool?) ?? true,
          battery: (msg['battery'] as num?)?.toInt() ?? 100,
          rssi: (msg['rssi'] as num?)?.toInt() ?? -50,
        ));
        break;

      // ------------------------------------------------------------------
      // Mode 1: new tap_data message with raw MPU-6050 accel frames.
      case 'tap_data':
        final nodeId = msg['node'] as int;
        final tapperId = msg['tapper'] as int;
        final tapData = TapData.fromJson(nodeId, msg);

        _openTapData.putIfAbsent(tapperId, () => {});
        _openTapData[tapperId]![nodeId] = tapData;

        // Flush the tap cycle after a short window (all listeners should
        // report within ~100 ms of each other across a 15 m array).
        _tapDataFlushTimer?.cancel();
        _tapDataFlushTimer = Timer(
          const Duration(milliseconds: 200),
          () => _flushTapDataCycle(tapperId),
        );
        break;

      // ------------------------------------------------------------------
      // Mode 1: legacy tap/arrival messages (older firmware).
      case 'tap':
        _flushOpenCycle();
        _openTapperId = msg['tapper'] as int;
        _openTapFiredAt = DateTime.now();
        _openArrivals.clear();
        _flushTimer?.cancel();
        _flushTimer = Timer(
          const Duration(milliseconds: 1500),
          _flushOpenCycle,
        );
        break;

      case 'arrival':
        final tapper = msg['tapper'] as int;
        if (tapper == _openTapperId) {
          _openArrivals[msg['node'] as int] = (msg['ms'] as num).toDouble();
        }
        break;

      // ------------------------------------------------------------------
      // Mode 2: passive detection (pre-classified, legacy).
      case 'detection':
        _controller.add(DetectionEvent(
          nodeId: msg['node'] as int,
          timestampMs: (msg['ms'] as num).toDouble(),
          kind: _kindFromString(msg['kind'] as String?),
          amplitude: (msg['amplitude'] as num?)?.toDouble() ?? 0.5,
          confidence: (msg['confidence'] as num?)?.toDouble() ?? 1.0,
        ));
        break;

      // Mode 2: passive detection (preferred — raw features for phone ML).
      case 'detection_raw':
        _controller.add(RawDetectionSample(
          nodeId: msg['node'] as int,
          timestampMs: (msg['ms'] as num).toDouble(),
          features: SignalFeatures.fromJson(msg),
        ));
        break;

      // ------------------------------------------------------------------
      // FTM calibration result (new).
      case 'ftm':
        _controller.add(FtmMeasurement.fromJson(msg));
        break;

      // ------------------------------------------------------------------
      case 'rescuer_rssi':
        _controller.add(RescuerRssiSample(
          nodeId: msg['node'] as int,
          dbm: (msg['dbm'] as num).toDouble(),
        ));
        break;

      case 'pong':
        _controller.add(const GatewayPong());
        break;
    }
  }

  // --- New tap_data flush ------------------------------------------------
  void _flushTapDataCycle(int tapperId) {
    final frames = _openTapData.remove(tapperId);
    if (frames == null || frames.isEmpty) return;

    // Build a TapCycle by extracting first-arrival time from each
    // listener's accel frame.  The tapper's own frame is the T=0 reference
    // (piezoT0Us), so listener arrival times are relative to that.
    final tapperFrame = frames[tapperId];
    final refT0Us = tapperFrame?.piezoT0Us ?? 0;

    final arrivals = <int, double>{};
    for (final entry in frames.entries) {
      if (entry.key == tapperId) continue; // skip self
      final ms = entry.value.firstArrivalMs();
      if (ms != null) {
        // Adjust by the difference in piezo timestamps across nodes so
        // all arrivals are relative to the same T=0 trigger moment.
        final nodeOffsetUs = entry.value.piezoT0Us - refT0Us;
        arrivals[entry.key] = ms + nodeOffsetUs / 1000.0;
      }
    }

    if (arrivals.isNotEmpty) {
      _controller.add(TapCycle(
        tapperId: tapperId,
        arrivalMs: arrivals,
        firedAt: DateTime.now(),
      ));
    }
  }

  // --- Legacy tap/arrival flush ------------------------------------------
  void _flushOpenCycle() {
    if (_openTapperId != null && _openArrivals.isNotEmpty) {
      _controller.add(TapCycle(
        tapperId: _openTapperId!,
        arrivalMs: Map.of(_openArrivals),
        firedAt: _openTapFiredAt ?? DateTime.now(),
      ));
    }
    _openTapperId = null;
    _openArrivals.clear();
    _flushTimer?.cancel();
  }

  // --- Outbound commands ------------------------------------------------

  /// Send any JSON command to the gateway.
  void send(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  /// Switch all nodes to Mode 1 (impactor) or Mode 2 (triangulation).
  void setMode(int mode) => send({'type': 'set_mode', 'mode': mode});

  /// Fire the servo on a specific node (Mode 1).
  void triggerTap(int nodeId) => send({'type': 'trigger_tap', 'node': nodeId});

  /// Request an FTM ranging burst between two nodes.
  void requestFtm(int nodeA, int nodeB) =>
      send({'type': 'start_ftm', 'nodeA': nodeA, 'nodeB': nodeB});

  // --- Helpers ----------------------------------------------------------

  NodeRole _roleFromString(String? s) {
    switch (s) {
      case 'gateway':   return NodeRole.gateway;
      case 'tapper':    return NodeRole.tapper;
      default:          return NodeRole.listener;
    }
  }

  NodeMode _modeFromString(String? s) {
    switch (s) {
      case 'impactor':  return NodeMode.impactor;
      default:          return NodeMode.triangulation;
    }
  }

  EventKind _kindFromString(String? s) {
    switch (s) {
      case 'knock':     return EventKind.knock;
      case 'scream':    return EventKind.scream;
      case 'metallic':  return EventKind.metallic;
      case 'tapPulse':  return EventKind.tapPulse;
      default:          return EventKind.unknown;
    }
  }

  @override
  void stop() {
    _flushTimer?.cancel();
    _tapDataFlushTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _controller.close();
  }
}
