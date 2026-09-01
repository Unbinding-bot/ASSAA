import 'dart:math' as math;

import '../math3d.dart';
import '../models/event.dart';
import '../models/node.dart';
import '../models/voxel.dart';
import 'chan_solver.dart';

// =============================================================================
// Public result type
// =============================================================================

class TdoaResult {
  final Vec3 position;
  final double residualMs; // lower = better fit
  final double confidence; // 0–1
  const TdoaResult(this.position, this.residualMs, this.confidence);
}

// =============================================================================
// Hybrid Chan → LM solver  (spec §3.3)
// =============================================================================
//
// Stage 1 — Chan's WLS closed-form method (chan_solver.dart):
//   Provides a non-iterative initial estimate (x₀, y₀) in constant time.
//   Robust when nodes are well-spread; degrades near collinear geometry.
//
// Stage 2 — Levenberg-Marquardt with Marquardt scaling (this file):
//   Uses (x₀, y₀) from Chan as the starting point, so it never needs a
//   blind centroid guess and avoids local-minimum traps near the array.
//
//   Damping uses the Marquardt variant (spec §3.3):
//     x_{k+1} = x_k − (JᵀJ + λ·diag(JᵀJ))⁻¹ Jᵀf
//
//   λ·diag(JᵀJ) scales the damping proportionally to the curvature in each
//   parameter direction, which is better conditioned than plain λ·I near
//   ill-posed geometry (e.g. source on the array baseline).

/// Primary entry point — runs the full hybrid pipeline.
///
/// [rangeDiffsM]  nodeId → v·Δt range differences in metres relative to
///                [refNodeId].
/// [nodePositions] positions of ALL nodes including the reference.
/// [refNodeId]    the anchor node (τ = 0, d_iA is measured from this node).
/// [initialGuess] optional override for the LM starting point; if null,
///                Chan's result is used (or centroid if Chan fails).
/// [fixedZ]       constrain solve to a 2-D plane at this Z value.
TdoaResult? solveTdoaLM({
  required Map<int, double> rangeDiffsM,
  required Map<int, Vec3> nodePositions,
  required int refNodeId,
  Vec3? initialGuess,
  double? fixedZ,
  int maxIter = 50,
  double lambdaInit = 1e-3,
  double convergenceThreshM = 1e-5,
}) {
  final ref = nodePositions[refNodeId];
  if (ref == null) { return null; }

  final stations = <(Vec3, double)>[];
  for (final e in rangeDiffsM.entries) {
    final pos = nodePositions[e.key];
    if (pos == null) { continue; }
    stations.add((pos, e.value));
  }
  if (stations.length < 2) { return null; }

  final is2d = fixedZ != null;
  final dims = is2d ? 2 : 3;

  // ── Stage 1: Chan's method for initial guess ──────────────────────────────
  Vec3 guess;
  if (initialGuess != null) {
    guess = initialGuess;
  } else {
    final chanGuess = _chanInitialGuess(
      ref:         ref,
      stations:    stations,
      fixedZ:      fixedZ,
    );
    if (chanGuess != null) {
      guess = chanGuess;
    } else {
      // Fallback: centroid of node positions.
      var sx = 0.0, sy = 0.0, sz = 0.0;
      for (final p in nodePositions.values) {
        sx += p.x; sy += p.y; sz += p.z;
      }
      final n = nodePositions.length;
      guess = Vec3(sx / n, sy / n, fixedZ ?? sz / n);
    }
  }

  // ── Stage 2: Levenberg-Marquardt with Marquardt scaling ───────────────────
  var x = guess.x;
  var y = guess.y;
  var z = fixedZ ?? guess.z;
  var lambda = lambdaInit;

  for (var iter = 0; iter < maxIter; iter++) {
    final src     = Vec3(x, y, z);
    final distRef = src.distanceTo(ref);

    final m = stations.length;
    final f = List<double>.filled(m, 0.0);
    final J = List.generate(m, (_) => List<double>.filled(dims, 0.0));

    for (var i = 0; i < m; i++) {
      final (pos, dMeas) = stations[i];
      final dist = src.distanceTo(pos);
      if (dist < 1e-9 || distRef < 1e-9) { continue; }

      f[i] = dist - distRef - dMeas;
      J[i][0] = (x - pos.x) / dist - (x - ref.x) / distRef; // ∂f/∂x
      J[i][1] = (y - pos.y) / dist - (y - ref.y) / distRef; // ∂f/∂y
      if (!is2d) {
        J[i][2] = (z - pos.z) / dist - (z - ref.z) / distRef; // ∂f/∂z
      }
    }

    // JᵀJ (dims×dims)
    final jtj = _matMul(J, dims);

    // Marquardt scaling: add λ·diag(JᵀJ) instead of λ·I
    for (var d = 0; d < dims; d++) {
      jtj[d][d] *= (1.0 + lambda);
    }

    final jtf = List<double>.filled(dims, 0.0);
    for (var i = 0; i < m; i++) {
      for (var d = 0; d < dims; d++) { jtf[d] += J[i][d] * f[i]; }
    }

    final delta = _solveLinear(jtj, jtf.map((v) => -v).toList());
    if (delta == null) { break; }

    final nx = x + delta[0];
    final ny = y + delta[1];
    final nz = is2d ? z : z + (dims > 2 ? delta[2] : 0.0);

    final newSrc = Vec3(nx, ny, nz);
    if (_rms(stations, newSrc, ref) < _rms(stations, src, ref)) {
      x = nx; y = ny; z = nz;
      lambda *= 0.3; // reduce damping on a good step
    } else {
      lambda *= 5.0; // increase damping on a bad step
    }

    final stepNorm = math.sqrt(
        delta[0] * delta[0] +
        delta[1] * delta[1] +
        (dims > 2 ? delta[2] * delta[2] : 0.0));
    if (stepNorm < convergenceThreshM) { break; }
  }

  final finalSrc  = Vec3(x, y, z);
  final residualM = _rms(stations, finalSrc, ref);
  final residualMs = (residualM / 340.0) * 1000.0;

  final stationBonus = ((stations.length - 2) * 0.07).clamp(0.0, 0.28);
  final fit          = (1.0 - (residualMs / 50.0)).clamp(0.0, 1.0);
  final confidence   = (fit + stationBonus).clamp(0.0, 1.0).toDouble();

  return TdoaResult(finalSrc, residualMs, confidence);
}

// ---------------------------------------------------------------------------
// Chan initialiser bridge
// ---------------------------------------------------------------------------

Vec3? _chanInitialGuess({
  required Vec3 ref,
  required List<(Vec3, double)> stations,
  double? fixedZ,
}) {
  if (stations.length < 2) { return null; }

  final otherPos   = stations.map((s) => s.$1).toList();
  final rangeDiffs = stations.map((s) => s.$2).toList();

  final result = solveChan(
    refPos:     ref,
    otherPos:   otherPos,
    rangeDiffs: rangeDiffs,
    fixedZ:     fixedZ,
  );

  if (result == null) { return null; }
  // If geometry is very ill-conditioned, still use the result but LM will
  // correct the error — that is exactly the purpose of the hybrid design.
  return result.position;
}

// ---------------------------------------------------------------------------
// Algebraic helpers
// ---------------------------------------------------------------------------

double _rms(List<(Vec3, double)> stations, Vec3 src, Vec3 ref) {
  final distRef = src.distanceTo(ref);
  var sumSq = 0.0;
  for (final (pos, dMeas) in stations) {
    final r = src.distanceTo(pos) - distRef - dMeas;
    sumSq += r * r;
  }
  return math.sqrt(sumSq / stations.length);
}

List<List<double>> _matMul(List<List<double>> j, int dims) {
  final out = List.generate(dims, (_) => List<double>.filled(dims, 0.0));
  for (var i = 0; i < j.length; i++) {
    for (var r = 0; r < dims; r++) {
      for (var c = 0; c < dims; c++) { out[r][c] += j[i][r] * j[i][c]; }
    }
  }
  return out;
}

List<double>? _solveLinear(List<List<double>> A, List<double> b) {
  final n = b.length;
  final aug = List.generate(n, (i) => [...A[i], b[i]]);

  for (var col = 0; col < n; col++) {
    var maxRow = col;
    for (var row = col + 1; row < n; row++) {
      if (aug[row][col].abs() > aug[maxRow][col].abs()) { maxRow = row; }
    }
    final tmp = aug[col]; aug[col] = aug[maxRow]; aug[maxRow] = tmp;
    if (aug[col][col].abs() < 1e-12) { return null; }

    for (var row = col + 1; row < n; row++) {
      final factor = aug[row][col] / aug[col][col];
      for (var k = col; k <= n; k++) { aug[row][k] -= factor * aug[col][k]; }
    }
  }

  final x = List<double>.filled(n, 0.0);
  for (var i = n - 1; i >= 0; i--) {
    x[i] = aug[i][n];
    for (var j = i + 1; j < n; j++) { x[i] -= aug[i][j] * x[j]; }
    x[i] /= aug[i][i];
  }
  return x;
}

// =============================================================================
// Legacy wrapper  (keeps AppController compiling without changes)
// =============================================================================

TdoaResult? solveTdoa({
  required List<DetectionEvent> cluster,
  required Map<int, SensorNode> nodes,
  required VoxelGrid grid,
  required double wavespeedMps,
}) {
  final stations = cluster
      .where((e) => nodes.containsKey(e.nodeId))
      .toList();
  if (stations.length < 3) { return null; }

  stations.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
  final refId  = stations.first.nodeId;
  final refTs  = stations.first.timestampMs;

  final rangeDiffs = <int, double>{};
  for (final s in stations.skip(1)) {
    final dtMs = s.timestampMs - refTs;
    rangeDiffs[s.nodeId] = (dtMs / 1000.0) * wavespeedMps;
  }

  final nodePositions = {
    for (final s in stations) s.nodeId: nodes[s.nodeId]!.position,
  };

  // Use grid centre as the fallback only; Chan will normally override it.
  final gridCenter = Vec3(
    grid.origin.x + grid.nx * grid.cellSize / 2,
    grid.origin.y + grid.ny * grid.cellSize / 2,
    grid.origin.z + grid.nz * grid.cellSize / 2,
  );

  return solveTdoaLM(
    rangeDiffsM:   rangeDiffs,
    nodePositions: nodePositions,
    refNodeId:     refId,
    fixedZ:        0.0,          // always 2-D — z returned is depth estimate
    initialGuess:  gridCenter,
  );
}

// =============================================================================
// Event clustering  (unchanged)
// =============================================================================

List<List<DetectionEvent>> clusterEvents(
  List<DetectionEvent> events, {
  double windowMs = 200,
}) {
  final sorted = [...events]
    ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
  final clusters = <List<DetectionEvent>>[];
  var current = <DetectionEvent>[];

  for (final e in sorted) {
    if (current.isEmpty ||
        e.timestampMs - current.last.timestampMs <= windowMs) {
      if (!current.any((c) => c.nodeId == e.nodeId)) { current.add(e); }
    } else {
      if (current.isNotEmpty) { clusters.add(current); }
      current = [e];
    }
  }
  if (current.isNotEmpty) { clusters.add(current); }
  return clusters;
}
