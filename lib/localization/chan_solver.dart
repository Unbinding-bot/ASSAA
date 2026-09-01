import 'dart:math' as math;

import '../math3d.dart';

// =============================================================================
// Chan's Method — Closed-Form WLS TDOA Initializer  (spec §3.3 Stage 1)
// =============================================================================
//
// Given 3 sensor nodes A (reference), B, C at known 2-D positions and the
// measured range differences d_BA, d_CA (= v · Δt), Chan's method yields a
// direct algebraic estimate of the source position without iteration.
//
// Derivation sketch (Huang et al., 1987 / Chan & Ho, 1994):
//
//   For node i ∈ {B, C}, squaring the range equation and subtracting the
//   anchor equation gives a linear equation in (x_s, y_s, d_A):
//
//     x_i·x_s + y_i·y_s + d_iA·d_A = ½(x_i² + y_i² − d_iA²)   … (*)
//
//   where d_A = ‖S − A‖ (distance from source to reference node A).
//
//   In matrix form:   G·θ = h
//
//     G = [x_B  y_B  d_BA]    θ = [x_s]    h = ½[x_B²+y_B²−d_BA²]
//         [x_C  y_C  d_CA]        [y_s]         [x_C²+y_C²−d_CA²]
//                                 [d_A]
//
//   Solving with Weighted Least Squares (WLS):
//     θ = (G^T W G)^{-1} G^T W h
//
//   The weight matrix W is the inverse of the TDOA measurement covariance.
//   With equal-quality sensors, W = I gives standard LS; the caller may
//   supply a custom W (e.g., from GCC-PHAT peak sharpness scores).
//
// ── Coordinate convention ────────────────────────────────────────────────────
//
//   The method works in the frame of the reference node A.  Internally we
//   translate all coordinates so A is at the origin, solve, then translate
//   the result back.  This is algebraically equivalent to the published form
//   but numerically more stable when nodes are far from (0,0).
//
// ── Degenerate cases ─────────────────────────────────────────────────────────
//
//   - Collinear nodes: G^T W G becomes singular (det ≈ 0). Returns null.
//   - |d_iA| > node separation: physically impossible range difference.
//     Clamped before solving to avoid complex square roots downstream.

/// Result from Chan's WLS solver.
class ChanResult {
  /// Estimated source position in the same coordinate frame as the input nodes.
  final Vec3 position;

  /// Estimated distance from source to the reference node (d_A in the spec).
  final double distToRef;

  /// Condition number proxy — how well-conditioned the G matrix was.
  /// Values > 1000 indicate near-collinear geometry; treat the result with
  /// caution and let LM refinement correct it.
  final double conditionProxy;

  const ChanResult({
    required this.position,
    required this.distToRef,
    required this.conditionProxy,
  });
}

/// Solves for the 2-D source position using Chan's linearised WLS method.
///
/// @param refPos     Position of the reference (anchor) node A.
/// @param otherPos   Positions of the remaining nodes (at least 2 for a
///                   2-D solve; extras are included in the LS system).
/// @param rangeDiffs Map from node index (matching [otherPos] order) to
///                   signed range difference d_iA = v·(t_i − t_A) in metres.
///                   Positive = source farther from node i than from A.
/// @param weights    Optional per-equation weights (same length as otherPos).
///                   Defaults to unity weights if null.
/// @param fixedZ     If non-null, the returned position uses this Z value
///                   (pure 2-D solve on a flat surface).
///
/// Returns null if the geometry is degenerate (collinear / insufficient nodes).
ChanResult? solveChan({
  required Vec3 refPos,
  required List<Vec3> otherPos,
  required List<double> rangeDiffs,
  List<double>? weights,
  double? fixedZ,
}) {
  assert(otherPos.length == rangeDiffs.length,
      'Chan: otherPos and rangeDiffs must have the same length');
  final m = otherPos.length;
  if (m < 2) { return null; } // need ≥ 2 equations for a 2-D solve

  final w = weights ?? List<double>.filled(m, 1.0);

  // Translate to ref-centred frame: A is at origin.
  final relPos = otherPos.map((p) => Vec3(
        p.x - refPos.x,
        p.y - refPos.y,
        p.z - refPos.z,
      )).toList();

  // Clamp range differences to physically plausible values.
  final dClamped = List<double>.generate(m, (i) {
    final maxRange = relPos[i].distanceTo(const Vec3(0, 0, 0));
    return rangeDiffs[i].clamp(-maxRange * 0.999, maxRange * 0.999);
  });

  // Build G (m×3) and h (m×1).
  //   G[i] = [x_i, y_i, d_iA]
  //   h[i] = ½(x_i² + y_i² − d_iA²)
  final G = List.generate(m, (i) => [
        relPos[i].x,
        relPos[i].y,
        dClamped[i],
      ]);
  final h = List.generate(m, (i) =>
      0.5 * (relPos[i].x * relPos[i].x +
             relPos[i].y * relPos[i].y -
             dClamped[i] * dClamped[i]));

  // WLS: θ = (G^T W G)^{-1} G^T W h
  // With dims 3×3 we can solve directly via the same Gaussian elimination
  // used in the LM solver.

  // Form G^T W G (3×3) and G^T W h (3×1).
  final gtWG = List.generate(3, (_) => List<double>.filled(3, 0.0));
  final gtWh = List<double>.filled(3, 0.0);

  for (var i = 0; i < m; i++) {
    final wi = w[i];
    for (var r = 0; r < 3; r++) {
      for (var c = 0; c < 3; c++) {
        gtWG[r][c] += wi * G[i][r] * G[i][c];
      }
      gtWh[r] += wi * G[i][r] * h[i];
    }
  }

  // Compute condition proxy as max diagonal / min diagonal of G^T W G.
  final diag = [gtWG[0][0], gtWG[1][1], gtWG[2][2]];
  final maxD = diag.reduce(math.max);
  final minD = diag.reduce(math.min).abs();
  final cond = minD < 1e-12 ? double.infinity : maxD / minD;

  final theta = _solveLinear3x3(gtWG, gtWh);
  if (theta == null) { return null; } // singular

  final xs = theta[0] + refPos.x; // translate back
  final ys = theta[1] + refPos.y;
  final dA = theta[2].abs();       // d_A must be non-negative
  final z  = fixedZ ?? refPos.z;

  return ChanResult(
    position:       Vec3(xs, ys, z),
    distToRef:      dA,
    conditionProxy: cond,
  );
}

// ---------------------------------------------------------------------------
// 3×3 Gaussian elimination with partial pivoting  (same logic as tdoa_solver)
// ---------------------------------------------------------------------------

List<double>? _solveLinear3x3(List<List<double>> a, List<double> b) {
  const n = 3;
  final aug = List.generate(n, (i) => [...a[i], b[i]]);

  for (var col = 0; col < n; col++) {
    var maxRow = col;
    for (var row = col + 1; row < n; row++) {
      if (aug[row][col].abs() > aug[maxRow][col].abs()) { maxRow = row; }
    }
    final tmp = aug[col]; aug[col] = aug[maxRow]; aug[maxRow] = tmp;
    if (aug[col][col].abs() < 1e-12) { return null; }

    for (var row = col + 1; row < n; row++) {
      final f = aug[row][col] / aug[col][col];
      for (var k = col; k <= n; k++) { aug[row][k] -= f * aug[col][k]; }
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
