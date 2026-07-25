import 'dart:math' as math;

import '../math3d.dart';
import '../models/event.dart';
import '../models/node.dart';
import '../models/voxel.dart';

/// Solves for the source position of a cluster of knock/scream detections
/// (the same physical event, heard at several nodes with different delays).
///
/// Why grid search instead of closed-form TDOA (e.g. Fang/Chan-Ho):
/// closed-form hyperbolic solutions are fast but numerically touchy with
/// only 3-6 noisy stations and an uncertain propagation velocity through
/// rubble. A grid search over the same voxel grid used for the map is
/// slower but never diverges, degrades gracefully with few stations, and
/// reuses the grid we already have to draw on. Fine tradeoff at this scale
/// (a few hundred voxels, solved a few times a second at most).
///
/// `wavespeedMps` is deliberately a live-tunable calibration parameter --
/// propagation speed through disturbed rubble is not well characterized
/// and should be measured against your own hardware, not assumed.
class TdoaResult {
  final Vec3 position;
  final double residualMs; // lower = better fit
  final double confidence; // 0-1, derived from residual + station count
  const TdoaResult(this.position, this.residualMs, this.confidence);
}

TdoaResult? solveTdoa({
  required List<DetectionEvent> cluster, // same event, multiple nodes
  required Map<int, SensorNode> nodes,
  required VoxelGrid grid,
  required double wavespeedMps,
}) {
  final stations = cluster
      .where((e) => nodes.containsKey(e.nodeId))
      .toList();
  if (stations.length < 3) return null; // need >=3 for a meaningful 3D fix

  Voxel? best;
  double bestResidual = double.infinity;

  for (final voxel in grid.cells) {
    // For a candidate source position, the best-fit origin time t0
    // minimizes sum((observed_i - t0) - dist_i/v)^2, which is just the
    // mean of (observed_i - dist_i/v).
    final predictedDelays = <double>[];
    for (final s in stations) {
      final node = nodes[s.nodeId]!;
      final distM = voxel.center.distanceTo(node.position);
      final travelMs = (distM / wavespeedMps) * 1000;
      predictedDelays.add(s.timestampMs - travelMs);
    }
    final t0 = predictedDelays.reduce((a, b) => a + b) / predictedDelays.length;

    var sumSq = 0.0;
    for (var i = 0; i < stations.length; i++) {
      final node = nodes[stations[i].nodeId]!;
      final distM = voxel.center.distanceTo(node.position);
      final travelMs = (distM / wavespeedMps) * 1000;
      final predicted = t0 + travelMs;
      final residual = stations[i].timestampMs - predicted;
      sumSq += residual * residual;
    }
    final rms = sumSq / stations.length;
    if (rms < bestResidual) {
      bestResidual = rms;
      best = voxel;
    }
  }

  if (best == null) return null;
  final residualMs = math.sqrt(bestResidual);
  // Confidence falls off with residual error and rewards more stations.
  final stationBonus = ((stations.length - 3) * 0.08).clamp(0.0, 0.3);
  final fit = (1.0 - (residualMs / 40.0)).clamp(0.0, 1.0);
  final confidence = (fit + stationBonus).clamp(0.0, 1.0).toDouble();

  return TdoaResult(best.center, residualMs, confidence);
}

/// Groups raw detection events into clusters that likely represent the
/// same physical event heard across nodes, based on a matching time
/// window. Rubble path-length differences between nodes 5-15m apart are
/// small relative to typical knock/scream duration, so a generous window
/// (default 200ms) is used deliberately.
List<List<DetectionEvent>> clusterEvents(
  List<DetectionEvent> events, {
  double windowMs = 200,
}) {
  final sorted = [...events]..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
  final clusters = <List<DetectionEvent>>[];
  var current = <DetectionEvent>[];

  for (final e in sorted) {
    if (current.isEmpty || e.timestampMs - current.last.timestampMs <= windowMs) {
      current.add(e);
    } else {
      if (current.isNotEmpty) clusters.add(current);
      current = [e];
    }
  }
  if (current.isNotEmpty) clusters.add(current);
  return clusters;
}