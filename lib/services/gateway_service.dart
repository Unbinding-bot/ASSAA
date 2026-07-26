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
/// protocol (documented in data_source.dart) into the shared message
/// stream. Tap cycles are assembled incrementally: a "tap" message opens
/// a cycle, subsequent "arrival" messages for that tapper fill it in, and
/// it's flushed to the stream after a short window so tomography can run
/// on whatever arrived in time.
class GatewayService implements DataSource {
  GatewayService(this.uri);
  final Uri uri;

  final _controller = StreamController<Object>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  int? _openTapperId;
  DateTime? _openTapFiredAt;
  final Map<int, double> _openArrivals = {};
  Timer? _flushTimer;

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
    // Wrapped end-to-end: a stream listener callback throwing synchronously
    // is NOT caught by the source stream's onError, so one malformed frame
    // (missing field, wrong type) would otherwise kill the whole listener.
    try {
      _parseAndDispatch(raw);
    } catch (_) {
      // Drop the bad frame and keep listening -- a single corrupt packet
      // over a lossy rubble mesh shouldn't take down the connection.
    }
  }

  void _parseAndDispatch(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;

    switch (msg['type']) {
      case 'telemetry':
        _controller.add(SensorNode(
          id: msg['node'] as int,
          position: Vec3(
            (msg['x'] as num).toDouble(),
            (msg['y'] as num).toDouble(),
            (msg['z'] as num).toDouble(),
          ),
          role: _roleFromString(msg['role'] as String?),
          battery: (msg['battery'] as num?)?.toInt() ?? 100,
          rssi: (msg['rssi'] as num?)?.toInt() ?? -50,
        ));
        break;

      case 'tap':
        _flushOpenCycle(); // close out any prior cycle first
        _openTapperId = msg['tapper'] as int;
        _openTapFiredAt = DateTime.now();
        _openArrivals.clear();
        _flushTimer?.cancel();
        // Give listeners ~1.5s (matches the T=0.2-1.2s record window in
        // the design doc) to report arrivals before closing the cycle.
        _flushTimer = Timer(const Duration(milliseconds: 1500), _flushOpenCycle);
        break;

      case 'arrival':
        final tapper = msg['tapper'] as int;
        if (tapper == _openTapperId) {
          _openArrivals[msg['node'] as int] = (msg['ms'] as num).toDouble();
        }
        break;

      case 'detection':
        _controller.add(DetectionEvent(
          nodeId: msg['node'] as int,
          timestampMs: (msg['ms'] as num).toDouble(),
          kind: _kindFromString(msg['kind'] as String?),
          amplitude: (msg['amplitude'] as num?)?.toDouble() ?? 0.5,
          confidence: (msg['confidence'] as num?)?.toDouble() ?? 1.0,
        ));
        break;

      case 'detection_raw':
        _controller.add(RawDetectionSample(
          nodeId: msg['node'] as int,
          timestampMs: (msg['ms'] as num).toDouble(),
          features: SignalFeatures.fromJson(msg),
        ));
        break;

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

  /// Sends a JSON message to the gateway (used for the heartbeat ping in
  /// esp32_connection.dart, and available for future outgoing needs like
  /// pushing calibration values to the firmware).
  void send(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

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

  NodeRole _roleFromString(String? s) {
    switch (s) {
      case 'gateway':
        return NodeRole.gateway;
      case 'tapper':
        return NodeRole.tapper;
      default:
        return NodeRole.listener;
    }
  }

  EventKind _kindFromString(String? s) {
    switch (s) {
      case 'knock':
        return EventKind.knock;
      case 'scream':
        return EventKind.scream;
      case 'tapPulse':
        return EventKind.tapPulse;
      default:
        return EventKind.unknown;
    }
  }

  @override
  void stop() {
    _flushTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _controller.close();
  }
}