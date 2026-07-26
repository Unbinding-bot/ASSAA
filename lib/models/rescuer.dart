import '../math3d.dart';

/// A solved "you are here" position for the person carrying the phone,
/// derived from RSSI trilateration (see localization/rssi_localization.dart).
class RescuerFix {
  final Vec3 position;
  final double accuracyM; // rough 1-sigma radius, for drawing a confidence ring
  final int anchorCount; // how many nodes contributed
  final DateTime updatedAt;

  RescuerFix({
    required this.position,
    required this.accuracyM,
    required this.anchorCount,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();
}

/// One node's RSSI reading of the rescuer's phone. Nodes get this by
/// passively sniffing 802.11 frames from the phone's MAC in promiscuous
/// mode (the phone doesn't need to associate with anything for this to
/// work) and relay it back through the mesh to the gateway.
class RescuerRssiSample {
  final int nodeId;
  final double dbm;
  final DateTime receivedAt;

  RescuerRssiSample({
    required this.nodeId,
    required this.dbm,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();
}