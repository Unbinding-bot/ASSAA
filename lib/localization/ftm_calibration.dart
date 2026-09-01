import 'dart:math' as math;

import '../math3d.dart';

// =============================================================================
// Wi-Fi FTM / RTT auto-calibration  (doc §5.1)
// =============================================================================
//
// IEEE 802.11mc Fine Timing Measurement (FTM) gives each node pair a
// round-trip-time distance:
//
//   d_ij = c · (t4 - t1 - (t3 - t2)) / 2
//
// where t1=departure, t2=responder-arrival, t3=ACK-departure, t4=initiator-
// arrival (all in nanoseconds from the ESP32 hardware timer).
//
// When FTM is unavailable the firmware falls back to RSSI log-distance
// (doc §1.1 key shift 3) — both paths produce the same pairwise distance
// matrix that MDS then converts to relative 3-D coordinates.
//
// Classical MDS algorithm (doc §5.1):
//   1. Build squared-distance matrix D² from pairwise distances d_ij.
//   2. Double-centre: B = -½ J D² J    where J = I - (1/N) 11^T
//   3. Eigen-decompose B, keep top-k eigenvalues/vectors (k=2 or 3).
//   4. Coordinates: X = V_k · diag(sqrt(λ_k))
//   5. Align result so the centroid is at the origin and the first node
//      sits on the positive X axis (removes the arbitrary rotation/
//      translation MDS introduces).
//
// Limitations accepted for a phone-side implementation:
//   - Eigen-decompose via power iteration (Jacobi would be exact but is
//     overkill for N ≤ 12 nodes).
//   - No iterative refinement of the distance matrix — first FTM burst
//     per pair is used as-is.  Averaging multiple bursts (NAV-01 calls
//     for 100 bursts) should be done before passing [distances] in.

/// One FTM or RSSI-derived distance measurement between two nodes.
class NodeDistanceMeasurement {
  final int nodeA;
  final int nodeB;
  final double distanceM;
  const NodeDistanceMeasurement(this.nodeA, this.nodeB, this.distanceM);
}

/// FTM four-timestamp tuple for a single burst.  Pass several bursts
/// to [ftmBurstDistance] and average externally before handing off to MDS.
class FtmBurst {
  final int t1Ns; // frame departure  (initiator clock, ns)
  final int t2Ns; // frame arrival    (responder clock, ns)
  final int t3Ns; // ACK departure    (responder clock, ns)
  final int t4Ns; // ACK arrival      (initiator clock, ns)
  const FtmBurst(this.t1Ns, this.t2Ns, this.t3Ns, this.t4Ns);
}

/// Computes the one-way distance from a single FTM burst (doc §5.1).
/// Speed of light c = 299,792,458 m/s.
double ftmBurstDistance(FtmBurst b) {
  const c = 299792458.0; // m/s
  final rttNs = (b.t4Ns - b.t1Ns) - (b.t3Ns - b.t2Ns);
  return c * rttNs / 2e9; // ns → s → m
}

/// Averages a list of FTM bursts into a single distance (NAV-01 calls
/// for 100 bursts; pass all of them here for the cleanest estimate).
double ftmAverageDistance(List<FtmBurst> bursts) {
  if (bursts.isEmpty) return 0;
  final sum = bursts.map(ftmBurstDistance).reduce((a, b) => a + b);
  return sum / bursts.length;
}

// =============================================================================
// Classical MDS
// =============================================================================

/// Converts a pairwise distance list into relative node coordinates using
/// classical MDS.
///
/// [measurements] — full or partial distance matrix (at minimum a spanning
///   tree, i.e. N-1 distances for N nodes).  Missing pairs are filled with
///   a rough estimate: max(known distances) * 1.5, which keeps MDS from
///   blowing up while clearly marking the pair as unresolved.
///
/// [dims] — 2 for a flat-surface deployment (concrete slab), 3 for a full
///   3-D rubble pile.  Default 3.
///
/// Returns a map of nodeId → Vec3 position relative to the centroid.
/// Returns null if there are fewer than 2 nodes or the eigen-decomposition
/// does not converge.
Map<int, Vec3>? mdsCoordinates(
  List<NodeDistanceMeasurement> measurements, {
  int dims = 3,
  int maxPowerIter = 200,
  double convergenceTol = 1e-8,
}) {
  // Collect node IDs.
  final idSet = <int>{};
  for (final m in measurements) {
    idSet.add(m.nodeA);
    idSet.add(m.nodeB);
  }
  final ids = idSet.toList()..sort();
  final n = ids.length;
  if (n < 2) return null;

  final idx = {for (var i = 0; i < n; i++) ids[i]: i};

  // Fill distance matrix; missing entries → maxDist * 1.5.
  final d = List.generate(n, (_) => List<double>.filled(n, 0.0));
  double maxD = 0;
  for (final m in measurements) {
    final i = idx[m.nodeA]!, j = idx[m.nodeB]!;
    d[i][j] = m.distanceM;
    d[j][i] = m.distanceM;
    if (m.distanceM > maxD) maxD = m.distanceM;
  }
  final fill = maxD * 1.5;
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (i != j && d[i][j] == 0) d[i][j] = fill;
    }
  }

  // Step 1: squared-distance matrix D².
  final d2 = List.generate(n, (i) => List<double>.generate(n, (j) => d[i][j] * d[i][j]));

  // Step 2: double-centring  B = -½ J D² J   where  J = I - (1/N) 11^T
  // B_ij = -½ (D²_ij - mean_row_i - mean_col_j + grand_mean)
  final rowMean = List<double>.filled(n, 0.0);
  final colMean = List<double>.filled(n, 0.0);
  var grandMean = 0.0;
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      rowMean[i] += d2[i][j];
      colMean[j] += d2[i][j];
      grandMean  += d2[i][j];
    }
    rowMean[i] /= n;
  }
  for (var j = 0; j < n; j++) { colMean[j] /= n; }
  grandMean /= n * n;

  final bMatrix = List.generate(
    n,
    (i) => List<double>.generate(
      n,
      (j) => -0.5 * (d2[i][j] - rowMean[i] - colMean[j] + grandMean),
    ),
  );

  // Step 3: top-[dims] eigenpairs of bMatrix via deflated power iteration.
  final k = dims.clamp(1, n - 1);
  final eigenVecs = <List<double>>[];
  final eigenVals = <double>[];

  // Work on a deflated copy of bMatrix.
  final bd = List.generate(n, (i) => List<double>.from(bMatrix[i]));

  for (var comp = 0; comp < k; comp++) {
    // Random unit-vector initialisation (seeded for repeatability).
    final rng = math.Random(42 + comp);
    var v = List<double>.generate(n, (_) => rng.nextDouble() - 0.5);
    _normalise(v);

    double lambda = 0;
    for (var iter = 0; iter < maxPowerIter; iter++) {
      final bv = _matVec(bd, v);
      final newLambda = _dot(v, bv);
      _normalise(bv);
      final diff = _normDiff(v, bv);
      v = bv;
      lambda = newLambda;
      if (diff < convergenceTol) { break; }
    }

    if (lambda <= 0) { break; } // remaining eigenvalues non-positive — stop

    eigenVecs.add(v);
    eigenVals.add(lambda);

    // Deflate: bd ← bd - λ v vᵀ
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        bd[i][j] -= lambda * v[i] * v[j];
      }
    }
  }

  if (eigenVecs.isEmpty) return null;

  // Step 4: X = V_k · diag(sqrt(λ_k))
  // x_i^(d) = eigenVecs[d][i] * sqrt(eigenVals[d])
  final coords = List.generate(n, (i) {
    final cx = eigenVecs.isNotEmpty ? eigenVecs[0][i] * math.sqrt(eigenVals[0]) : 0.0;
    final cy = eigenVecs.length > 1 ? eigenVecs[1][i] * math.sqrt(eigenVals[1]) : 0.0;
    final cz = eigenVecs.length > 2 ? eigenVecs[2][i] * math.sqrt(eigenVals[2]) : 0.0;
    return Vec3(cx, cy, cz);
  });

  // Step 5: canonical alignment
  //   - Translate so centroid is at origin.
  //   - Rotate so node 0 lies on the positive X axis (removes ambiguous
  //     reflection/rotation — the TDOA solver only needs relative geometry,
  //     not an absolute heading).
  var sumX = 0.0, sumY = 0.0, sumZ = 0.0;
  for (final c in coords) { sumX += c.x; sumY += c.y; sumZ += c.z; }
  final centroid = Vec3(sumX / n, sumY / n, sumZ / n);
  final centred = coords.map((c) => c - centroid).toList();

  // Rotate so node 0 is on +X axis (yaw rotation around Z).
  final p0 = centred[0];
  final angle = math.atan2(p0.y, p0.x);
  final cosA = math.cos(-angle), sinA = math.sin(-angle);
  final aligned = centred.map((c) => Vec3(
    c.x * cosA - c.y * sinA,
    c.x * sinA + c.y * cosA,
    c.z,
  )).toList();

  return {for (var i = 0; i < n; i++) ids[i]: aligned[i]};
}

// ---------------------------------------------------------------------------
// Small linear algebra helpers (no external deps)
// ---------------------------------------------------------------------------

List<double> _matVec(List<List<double>> a, List<double> v) {
  final n = v.length;
  return List<double>.generate(n, (i) {
    var s = 0.0;
    for (var j = 0; j < n; j++) { s += a[i][j] * v[j]; }
    return s;
  });
}

double _dot(List<double> a, List<double> b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) { s += a[i] * b[i]; }
  return s;
}

void _normalise(List<double> v) {
  final norm = math.sqrt(_dot(v, v));
  if (norm < 1e-12) { return; }
  for (var i = 0; i < v.length; i++) { v[i] /= norm; }
}

double _normDiff(List<double> a, List<double> b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = a[i] - b[i];
    s += d * d;
  }
  return math.sqrt(s);
}
