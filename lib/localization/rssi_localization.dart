import 'dart:math' as math;

import '../math3d.dart';
import '../models/node.dart';
import '../models/rescuer.dart';

/// Log-distance path loss model: RSSI(d) = txPowerAt1m - 10*n*log10(d)
/// Solved for distance: d = 10 ^ ((txPowerAt1m - RSSI) / (10*n))
///
/// Both `txPowerAt1mDbm` and `pathLossExponent` are live-tunable in the UI
/// (same philosophy as the wavespeed slider) because indoor/rubble RF
/// path loss varies a lot by environment and antenna orientation --
/// there's no substitute for calibrating against your own hardware.
/// Typical starting points: txPowerAt1m around -40dBm for ESP32 WiFi,
/// pathLossExponent 2.0 (open air) to 4.0 (through concrete/debris).
double rssiToDistanceM(
  double rssiDbm, {
  double txPowerAt1mDbm = -40,
  double pathLossExponent = 3.0,
}) {
  final exponent = (txPowerAt1mDbm - rssiDbm) / (10 * pathLossExponent);
  return math.pow(10, exponent).toDouble();
}

/// Solves the rescuer's position from however many nodes currently have a
/// fresh RSSI reading on the phone.
///
/// With >=3 anchors this is a proper grid-search trilateration (same
/// approach as the TDOA solver -- robust with few, noisy stations).
/// With 1-2 anchors there isn't enough geometry for a real fix, so this
/// falls back to an inverse-distance-weighted centroid, which is still
/// directionally useful ("you're closer to this side of the pile") but
/// reported with a much larger accuracy radius so the UI doesn't overstate
/// confidence it doesn't have.
RescuerFix? solveRescuerPosition({
  required Map<int, RescuerRssiSample> latestByNode,
  required Map<int, SensorNode> nodes,
  required Vec3 searchOrigin,
  required Vec3 searchExtent, // size of search box around origin
  double txPowerAt1mDbm = -40,
  double pathLossExponent = 3.0,
  double gridStepM = 0.5,
}) {
  final anchors = <MapEntry<SensorNode, double>>[];
  for (final sample in latestByNode.values) {
    final node = nodes[sample.nodeId];
    if (node == null) continue;
    final distM = rssiToDistanceM(
      sample.dbm,
      txPowerAt1mDbm: txPowerAt1mDbm,
      pathLossExponent: pathLossExponent,
    );
    anchors.add(MapEntry(node, distM));
  }
  if (anchors.isEmpty) return null;

  if (anchors.length < 3) {
    // Fallback: inverse-distance-weighted centroid. Not a real fix, but
    // better than showing nothing when only 1-2 nodes hear the phone
    // (e.g. right after the rescuer walks into range).
    var wx = 0.0, wy = 0.0, wz = 0.0, wsum = 0.0;
    for (final a in anchors) {
      final w = 1.0 / (a.value * a.value + 0.01);
      wx += a.key.position.x * w;
      wy += a.key.position.y * w;
      wz += a.key.position.z * w;
      wsum += w;
    }
    final centroid = Vec3(wx / wsum, wy / wsum, wz / wsum);
    return RescuerFix(
      position: centroid,
      accuracyM: 8.0, // deliberately generous -- this is a rough guess
      anchorCount: anchors.length,
    );
  }

  // Grid search over a box around searchOrigin, sized by searchExtent.
  final nx = math.max(1, (searchExtent.x / gridStepM).round());
  final ny = math.max(1, (searchExtent.y / gridStepM).round());
  final nz = math.max(1, (searchExtent.z / gridStepM).round());

  Vec3? best;
  var bestResidual = double.infinity;

  for (var iz = 0; iz <= nz; iz++) {
    final z = searchOrigin.z - searchExtent.z / 2 + iz * gridStepM;
    for (var iy = 0; iy <= ny; iy++) {
      final y = searchOrigin.y - searchExtent.y / 2 + iy * gridStepM;
      for (var ix = 0; ix <= nx; ix++) {
        final x = searchOrigin.x - searchExtent.x / 2 + ix * gridStepM;
        final candidate = Vec3(x, y, z);

        var sumSq = 0.0;
        for (final a in anchors) {
          final predicted = candidate.distanceTo(a.key.position);
          final residual = predicted - a.value;
          sumSq += residual * residual;
        }
        final rms = sumSq / anchors.length;
        if (rms < bestResidual) {
          bestResidual = rms;
          best = candidate;
        }
      }
    }
  }

  if (best == null) return null;
  final residualM = math.sqrt(bestResidual);
  // Accuracy estimate: base residual fit, tightened slightly by anchor
  // count, but floored so we never claim better than ~2m (matches the
  // ~3-7m field accuracy the hardware doc targets).
  final accuracy = (residualM + math.max(0, 4 - anchors.length) * 0.8)
      .clamp(2.0, 15.0)
      .toDouble();

  return RescuerFix(
    position: best,
    accuracyM: accuracy,
    anchorCount: anchors.length,
  );
}