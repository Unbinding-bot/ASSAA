import 'dart:async';
import 'dart:developer' as dev;

import '../models/event.dart';
import 'data_source.dart';
import 'gateway_service.dart';

/// Wraps GatewayService with the connection backbone a field tool
/// actually needs: automatic reconnect with backoff, and an app-level
/// heartbeat so a silently-dead WiFi link (rescuer walked out of range,
/// gateway power-cycled) gets detected and retried instead of just
/// sitting there looking "connected" while showing stale data.
///
/// This is what AppController.connectLive() uses -- GatewayService
/// itself stays a simple single-attempt client; all the retry/heartbeat
/// logic lives here so that lower-level class stays easy to reason about.
class Esp32GatewayConnection implements DataSource {
  Esp32GatewayConnection(
    this.uri, {
    this.heartbeatInterval = const Duration(seconds: 3),
    this.heartbeatTimeout = const Duration(seconds: 7),
    this.maxBackoff = const Duration(seconds: 20),
  });

  final Uri uri;
  final Duration heartbeatInterval;
  final Duration heartbeatTimeout;
  final Duration maxBackoff;

  final _messages = StreamController<Object>.broadcast();
  final _status = StreamController<ConnectionStatus>.broadcast();

  GatewayService? _gateway;
  StreamSubscription? _msgSub;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  DateTime? _lastPong;
  int _attempt = 0;
  bool _stopped = true;

  @override
  Stream<Object> get messages => _messages.stream;

  @override
  Stream<ConnectionStatus> get status => _status.stream;

  @override
  Future<void> start() async {
    _stopped = false;
    _attempt = 0;
    await _connectOnce();
  }

  Future<void> _connectOnce() async {
    if (_stopped) return;
    _setStatus(_attempt == 0 ? ConnectionStatus.connecting : ConnectionStatus.reconnecting);

    final gateway = GatewayService(uri);
    _gateway = gateway;
    _msgSub = gateway.messages.listen(
      _onMessage,
      onError: (e) => _handleDrop('stream error: $e'),
      onDone: () => _handleDrop('connection closed'),
    );

    try {
      await gateway.start();
      _attempt = 0;
      _lastPong = DateTime.now();
      _setStatus(ConnectionStatus.connected);
      _startHeartbeat();
    } catch (e) {
      _handleDrop('connect failed: $e');
    }
  }

  void _onMessage(Object msg) {
    if (msg is GatewayPong) {
      _lastPong = DateTime.now();
      return; // heartbeat plumbing only, never forwarded to the app
    }
    _messages.add(msg);
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      _gateway?.send({'type': 'ping', 't': DateTime.now().millisecondsSinceEpoch});
      final lastPong = _lastPong;
      if (lastPong != null && DateTime.now().difference(lastPong) > heartbeatTimeout) {
        _handleDrop('heartbeat timeout');
      }
    });
  }

  void _handleDrop(String reason) {
    if (_stopped) return;
    dev.log('Gateway connection dropped: $reason', name: 'esp32.connection');
    _heartbeatTimer?.cancel();
    _msgSub?.cancel();
    _gateway?.stop();
    _gateway = null;
    _setStatus(ConnectionStatus.error);

    _attempt++;
    final shiftAmount = _attempt.clamp(0, 5).toInt();
    final backoffMs = (1000 * (1 << shiftAmount)).clamp(1000, maxBackoff.inMilliseconds).toInt();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: backoffMs), _connectOnce);
  }

  void _setStatus(ConnectionStatus s) {
    if (!_status.isClosed) _status.add(s);
  }

  @override
  void stop() {
    _stopped = true;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _msgSub?.cancel();
    _gateway?.stop();
    _setStatus(ConnectionStatus.disconnected);
    _messages.close();
    _status.close();
  }
}