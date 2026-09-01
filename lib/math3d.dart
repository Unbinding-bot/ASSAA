import 'dart:math' as math;

import 'package:flutter/material.dart' show Offset;

/// 3-component point used throughout the codebase for node positions,
/// voxel centres, TDOA fixes, and waypoints. The z-axis represents depth
/// (metres below the sensor plane, positive = deeper) and is only used for
/// the depth-estimate readout and voxel-layer filtering — NOT for rendering.
/// The map is always drawn top-down in the XY plane.
class Vec3 {
  final double x, y, z;
  const Vec3(this.x, this.y, this.z);

  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);

  double distanceTo(Vec3 o) {
    final dx = x - o.x, dy = y - o.y, dz = z - o.z;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  double distanceTo2d(Vec3 o) {
    final dx = x - o.x, dy = y - o.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Perpendicular distance from this point to the segment a→b.
  /// Used by tomography back-projection to weight voxels near a ray path.
  double distanceToSegment(Vec3 a, Vec3 b) {
    final ab = b - a;
    final abLenSq = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z;
    if (abLenSq < 1e-9) return distanceTo(a);
    final ap = this - a;
    var t = (ap.x * ab.x + ap.y * ab.y + ap.z * ab.z) / abLenSq;
    t = t.clamp(0.0, 1.0).toDouble();
    final proj = Vec3(a.x + ab.x * t, a.y + ab.y * t, a.z + ab.z * t);
    return distanceTo(proj);
  }
}

// =============================================================================
// Flat 2-D projection  (replaces the old orbit-camera perspective pipeline)
// =============================================================================

/// How many screen pixels correspond to 1 metre at zoom = 1.0.
const double kPixelsPerMetre = 40.0;

/// Projects a world-space point (x metres, y metres) onto screen coordinates.
/// [panX] / [panY] are the current canvas pan offsets in pixels.
/// Y is flipped so that world +Y points up on screen (north = up).
Offset projectFlat(
  Vec3 world, {
  required double zoom,
  required double cx,
  required double cy,
  double panX = 0.0,
  double panY = 0.0,
}) {
  final scale = zoom * kPixelsPerMetre;
  return Offset(
    cx + panX + world.x * scale,
    cy + panY - world.y * scale, // flip Y: world-up → screen-up
  );
}

/// Inverse of [projectFlat]: converts a screen tap position back to world
/// coordinates (z is always 0 — placement is always on the ground plane).
Vec3 unprojectFlat(
  Offset screen, {
  required double zoom,
  required double cx,
  required double cy,
  double panX = 0.0,
  double panY = 0.0,
}) {
  final scale = zoom * kPixelsPerMetre;
  final wx = (screen.dx - cx - panX) / scale;
  final wy = -(screen.dy - cy - panY) / scale; // flip back
  return Vec3(wx, wy, 0.0);
}
