import 'dart:math' as math;

import '../models/voxel.dart';
import 'tdoa_solver.dart';

/// Tier the app uses to color the map. Thresholds are conservative on
/// purpose: a false "check first" costs a rescuer a few minutes, a missed
/// survivor costs a life, so the fusion is biased toward over-flagging.
enum ConfidenceTier { red, yellow, green }

ConfidenceTier tierFor(double confidence) {
  if (confidence >= 0.6) return ConfidenceTier.red;
  if (confidence >= 0.3) return ConfidenceTier.yellow;
  return ConfidenceTier.green;
}

/// Combines the two independent evidence sources into one 0-1 confidence
/// per voxel:
///   - voidScore: accumulated tomography anomaly (structural, from taps)
///   - tdoaScore: a Gaussian bump placed at each solved knock/scream
///     location, which is much stronger evidence of a live survivor than
///     a structural anomaly alone
///
/// This is a hand-tuned weighted sum, not a trained model -- it's the
/// integration point the NIP-trained classifier is meant to replace later.
/// Keep the function signature (grid in, grid mutated) stable so that
/// swap is a one-file change.
void fuseVoxelGrid(VoxelGrid grid, {double voidWeight = 0.35, double tdoaWeight = 0.85}) {
  // Normalize voidScore across the grid so its scale doesn't depend on
  // how many tap cycles have run yet.
  final maxVoid = grid.cells.fold<double>(
    0.0,
    (m, v) => math.max(m, v.voidScore),
  );
  final voidNorm = maxVoid > 1e-6 ? maxVoid : 1.0;

  for (final voxel in grid.cells) {
    final voidPart = (voxel.voidScore / voidNorm) * voidWeight;
    final tdoaPart = voxel.tdoaScore * tdoaWeight; // already 0-1 scaled
    voxel.confidence = (voidPart + tdoaPart).clamp(0.0, 1.0).toDouble();
  }
}

/// Applies a solved TDOA fix to the grid as a Gaussian confidence bump
/// centered on the result, so a single loud scream/knock cluster can push
/// nearby voxels straight into "red" even with little tomography evidence.
void applyTdoaResult(VoxelGrid grid, TdoaResult result, {double sigmaM = 1.0}) {
  for (final voxel in grid.cells) {
    final d = voxel.center.distanceTo(result.position);
    final v = d / sigmaM;
    final bump = math.exp(-0.5 * v * v) * result.confidence;
    voxel.tdoaScore = math.max(voxel.tdoaScore, bump);
  }
}