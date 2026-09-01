import '../math3d.dart';
import '../models/event.dart';
import '../models/node.dart';

/// Result of selecting the 3-node active triangle for one impact event.
///
/// The 3 chosen nodes form the "local quadrant" — the subset whose arrival
/// timestamps are earliest (i.e. physically closest to the source).
/// All further processing (TDOA solve, NDT feature extraction) operates only
/// on these nodes; the 2 distant nodes are dropped to avoid attenuation noise
/// and multi-path reflection clutter.
class QuadrantResult {
  /// The 3 selected sensor nodes, sorted by arrival time (fastest first).
  final List<SensorNode> nodes;

  /// nodeId → measured arrival timestamp (ms) for each selected node.
  final Map<int, double> arrivalMs;

  /// The reference node (fastest arrival — lowest index 0).
  SensorNode get reference => nodes.first;

  /// Centre point of the triangle formed by the 3 nodes (used as the TDOA
  /// initial guess and for the NDT grid centre).
  Vec3 get triangleCentroid {
    final x = nodes.fold(0.0, (s, n) => s + n.position.x) / nodes.length;
    final y = nodes.fold(0.0, (s, n) => s + n.position.y) / nodes.length;
    final z = nodes.fold(0.0, (s, n) => s + n.position.z) / nodes.length;
    return Vec3(x, y, z);
  }

  /// Z-plane of the triangle (mean Z of the 3 nodes).
  /// Passed as [fixedZ] to the LM TDOA solver for 2-D constraint.
  double get planeZ =>
      nodes.fold(0.0, (s, n) => s + n.position.z) / nodes.length;

  const QuadrantResult({
    required this.nodes,
    required this.arrivalMs,
  });
}

/// Selects the active 3-node triangle from a set of arrival timestamps.
///
/// ── Selection algorithm ───────────────────────────────────────────────────
///
/// For a passive acoustic event (Mode 2):
///   1. Compare arrival timestamps across all nodes that reported the event.
///   2. Sort by timestamp ascending (earliest = physically closest to source).
///   3. Take the top 3. The 2 slowest nodes are dropped.
///
/// For an active tap cycle (Mode 1):
///   1. The tapper node's own timestamp is T0 (the piezo interrupt).
///   2. Listener arrival times are measured from T0.
///   3. The 2 listener nodes with the shortest travel times are selected
///      alongside the tapper, forming the triangle.
///
/// ── Why 3 nodes ───────────────────────────────────────────────────────────
///
/// A 2-D hyperbolic TDOA solve requires N-1 ≥ 2 range differences, so the
/// minimum viable set is 3 nodes. Using exactly 3 keeps the geometry clean
/// (one unambiguous triangle), avoids over-determination with noisy far-field
/// nodes, and mirrors the physical "triangular subarray" layout described in
/// the architecture spec (4 outer + 1 center → any 3 adjacent nodes form a
/// triangle whose centroid covers one quadrant of the surface).
///
/// ── Degenerate cases ──────────────────────────────────────────────────────
///
/// If fewer than 3 nodes have valid arrivals, returns null. Callers should
/// fall back to the full-grid LM solve in that case.
QuadrantResult? selectActiveTriangle({
  required Map<int, SensorNode> allNodes,
  required Map<int, double> arrivalTimestamps, // nodeId → timestamp (ms)
  int triangleSize = 3,
}) {
  // Filter to nodes that exist in the node table and have a timestamp.
  final valid = arrivalTimestamps.entries
      .where((e) => allNodes.containsKey(e.key))
      .toList()
    ..sort((a, b) => a.value.compareTo(b.value)); // earliest first

  if (valid.length < triangleSize) { return null; }

  final selected = valid.take(triangleSize).toList();
  return QuadrantResult(
    nodes: selected.map((e) => allNodes[e.key]!).toList(),
    arrivalMs: {for (final e in selected) e.key: e.value},
  );
}

/// Convenience overload for a [TapCycle] (Mode 1 active NDT).
///
/// Treats the tapper as the T0 reference with timestamp 0, and the
/// listener arrival times (already in ms from T0) as the ranking signal.
QuadrantResult? selectTriangleFromTapCycle({
  required TapCycle cycle,
  required Map<int, SensorNode> allNodes,
  int triangleSize = 3,
}) {
  // Build a unified timestamp map: tapper = 0, listeners = their travel time.
  final timestamps = <int, double>{cycle.tapperId: 0.0};
  timestamps.addAll(cycle.arrivalMs);
  return selectActiveTriangle(
    allNodes: allNodes,
    arrivalTimestamps: timestamps,
    triangleSize: triangleSize,
  );
}

/// Convenience overload for a cluster of [DetectionEvent]s (Mode 2 passive).
///
/// Uses each event's [timestampMs] as the arrival time. The node with the
/// smallest timestamp is closest to the source and becomes the reference.
QuadrantResult? selectTriangleFromCluster({
  required List<DetectionEvent> cluster,
  required Map<int, SensorNode> allNodes,
  int triangleSize = 3,
}) {
  final timestamps = <int, double>{
    for (final e in cluster) e.nodeId: e.timestampMs,
  };
  return selectActiveTriangle(
    allNodes: allNodes,
    arrivalTimestamps: timestamps,
    triangleSize: triangleSize,
  );
}

/// Convenience overload for the GCC-PHAT audio frame pipeline (Mode 2).
///
/// [frameTimestampsUs] is nodeId → hardware µs timestamp of the frame in
/// which the transient was detected (from [AudioFrame.timestampUs]).
/// Converts µs → ms before ranking.
QuadrantResult? selectTriangleFromFrameTimestamps({
  required Map<int, int> frameTimestampsUs, // nodeId → µs
  required Map<int, SensorNode> allNodes,
  int triangleSize = 3,
}) {
  final timestamps = frameTimestampsUs.map(
    (id, us) => MapEntry(id, us / 1000.0), // µs → ms
  );
  return selectActiveTriangle(
    allNodes: allNodes,
    arrivalTimestamps: timestamps,
    triangleSize: triangleSize,
  );
}
