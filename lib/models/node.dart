import '../math3d.dart';

enum NodeRole { gateway, tapper, listener }

class SensorNode {
  final int id;
  Vec3 position;
  NodeRole role;
  int battery; // 0-100
  int rssi; // dBm
  bool connected;
  DateTime lastSeen;

  SensorNode({
    required this.id,
    required this.position,
    this.role = NodeRole.listener,
    this.battery = 100,
    this.rssi = -50,
    this.connected = true,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  bool get isStale =>
      DateTime.now().difference(lastSeen) > const Duration(seconds: 15);
}