import 'dart:math' as math;

/// Small self-contained 3D math helper. Deliberately not pulling in the
/// `vector_math` package -- this app only needs points, distance, and one
/// yaw/pitch rotation for the orbit camera, so a 20-line class keeps the
/// dependency surface (and offline-build risk) minimal.
class Vec3 {
  final double x, y, z;
  const Vec3(this.x, this.y, this.z);

  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);

  double distanceTo(Vec3 o) {
    final dx = x - o.x, dy = y - o.y, dz = z - o.z;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  /// Perpendicular distance from this point to the segment a->b.
  /// Used by the tomography back-projection to weight voxels near a ray.
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

  /// Rotate around Y (yaw) then X (pitch), used by the orbit camera.
  Vec3 rotated(double yaw, double pitch) {
    // Yaw around Y axis
    final cosY = math.cos(yaw), sinY = math.sin(yaw);
    final x1 = x * cosY + z * sinY;
    final z1 = -x * sinY + z * cosY;
    // Pitch around X axis
    final cosP = math.cos(pitch), sinP = math.sin(pitch);
    final y2 = y * cosP - z1 * sinP;
    final z2 = y * sinP + z1 * cosP;
    return Vec3(x1, y2, z2);
  }
}

/// Simple perspective projection of a rotated point onto screen space.
/// Returns null if the point is behind the camera.
class Projected {
  final double screenX, screenY, depth, scale;
  Projected(this.screenX, this.screenY, this.depth, this.scale);
}

Projected? project(Vec3 world, {
  required double yaw,
  required double pitch,
  required double zoom,
  required double cx,
  required double cy,
  double cameraDistance = 14.0,
  double focalLength = 900.0,
}) {
  final r = world.rotated(yaw, pitch);
  final camZ = r.z + cameraDistance;
  if (camZ <= 0.5) return null;
  final scale = (focalLength * zoom) / camZ;
  return Projected(cx + r.x * scale, cy - r.y * scale, camZ, scale);
}