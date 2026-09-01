import '../math3d.dart';

enum NodeRole { gateway, tapper, listener }

/// Which firmware operating mode the node is currently in (doc §3.1).
enum NodeMode {
  /// Mode 1: active impactor NDT — servo actuates, MPU-6050 streams.
  impactor,
  /// Mode 2: passive acoustic triangulation — I2S audio streams over UDP.
  triangulation,
}

class SensorNode {
  final int id;
  Vec3 position;
  NodeRole role;
  NodeMode operatingMode;
  bool ftmCapable; // supports IEEE 802.11mc FTM (ESP32-C3 native)
  int battery; // 0-100
  int rssi; // dBm
  bool connected;
  DateTime lastSeen;

  SensorNode({
    required this.id,
    required this.position,
    this.role = NodeRole.listener,
    this.operatingMode = NodeMode.triangulation,
    this.ftmCapable = true, // ESP32-C3 supports FTM natively
    this.battery = 100,
    this.rssi = -50,
    this.connected = true,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  bool get isStale =>
      DateTime.now().difference(lastSeen) > const Duration(seconds: 15);
}
