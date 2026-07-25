import 'dart:math' as math;

import '../models/event.dart';
import '../models/node.dart';
import '../models/voxel.dart';

/// Straight-ray back-projection tomography from active-mode tap cycles.
///
/// For each tapper->listener path, compare the measured travel time to
/// the expected travel time at the baseline wavespeed. A positive residual
/// (slower than expected) suggests the ray crossed an air void or a body;
/// a residual near zero suggests solid, continuous concrete. That residual
/// gets smeared onto every voxel near the ray's straight-line path,
/// weighted by how close the voxel is to the ray (a Gaussian falloff).
///
/// This is a coarse first-pass method (true seismic tomography would
/// iteratively refine a velocity field), but with ~5-8 nodes it gives a
/// usable anomaly map without needing an iterative solver on a phone.
void backProjectTapCycle({
  required TapCycle cycle,
  required Map<int, SensorNode> nodes,
  required VoxelGrid grid,
  required double baselineWavespeedMps,
  double rayInfluenceRadiusM = 1.2,
}) {
  final tapper = nodes[cycle.tapperId];
  if (tapper == null) return;

  cycle.arrivalMs.forEach((listenerId, measuredMs) {
    final listener = nodes[listenerId];
    if (listener == null) return;

    final distM = tapper.position.distanceTo(listener.position);
    if (distM < 0.05) return;
    final expectedMs = (distM / baselineWavespeedMps) * 1000;
    final residualMs = measuredMs - expectedMs;

    // Only positive residuals (slower-than-baseline) are evidence of a
    // void/body; negative residuals (faster) are more likely measurement
    // noise or a stiffer-than-average debris path and are ignored so they
    // don't cancel out real anomalies elsewhere on the grid.
    if (residualMs <= 0) return;

    for (final voxel in grid.cells) {
      final perpDist = voxel.center.distanceToSegment(
        tapper.position,
        listener.position,
      );
      if (perpDist > rayInfluenceRadiusM) continue;
      final weight =
          _gaussian(perpDist, rayInfluenceRadiusM / 2.2); // falloff
      voxel.voidScore += residualMs * weight;
    }
  });
}

double _gaussian(double x, double sigma) {
  final v = x / sigma;
  return math.exp(-0.5 * v * v);
}