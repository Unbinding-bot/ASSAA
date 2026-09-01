import 'dart:math' as math;

import '../math3d.dart';

// =============================================================================
// Spatial navigation guidance vector  (doc §5.2)
// =============================================================================
//
// Given:
//   U = user position (x_u, y_u)  — from GNSS / IMU or RSSI trilateration
//   S = acoustic source position  — from LM TDOA solver
//   θ_u = user orientation angle  — relative to North, from magnetometer
//
// The guidance vector V_{U→S} = (d_US, θ_rel) is computed as:
//
//   1. Euclidean range:
//        d_US = ||S - U|| = sqrt((x_s-x_u)² + (y_s-y_u)²)
//
//   2. Absolute bearing:
//        φ = atan2(y_s - y_u, x_s - x_u)
//
//   3. Relative heading:
//        θ_rel = (φ - θ_u) mod 2π
//
// The HUD draws θ_rel as a directional arrow and shows d_US in metres.

/// Output of the navigation solver — everything the HUD needs to render
/// the "go here" arrow and distance callout.
class NavigationVector {
  /// Straight-line distance to the target in metres.
  final double distanceM;

  /// Absolute bearing from North to the target, radians [0, 2π).
  final double absoluteBearingRad;

  /// Bearing relative to the user's current heading, radians [0, 2π).
  /// 0 = straight ahead, π/2 = right, π = behind, 3π/2 = left.
  final double relativeBearingRad;

  /// Source position used for this vector.
  final Vec3 source;

  /// User position used for this vector.
  final Vec3 user;

  const NavigationVector({
    required this.distanceM,
    required this.absoluteBearingRad,
    required this.relativeBearingRad,
    required this.source,
    required this.user,
  });

  /// Relative bearing in degrees [0, 360) — convenience for the HUD label.
  double get relativeBearingDeg => relativeBearingRad * 180 / math.pi;

  /// Absolute bearing in degrees [0, 360) — for compass display.
  double get absoluteBearingDeg => absoluteBearingRad * 180 / math.pi;

  /// Cardinal + intercardinal label for the relative direction, e.g.
  /// "NE", "SW" — useful as a text fallback when the arrow isn't visible.
  String get cardinalLabel {
    // Rotate so 0 = North, clockwise, map to 8 sectors.
    final deg = relativeBearingDeg;
    const sectors = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final index = ((deg + 22.5) / 45).floor() % 8;
    return sectors[index];
  }
}

/// Computes the guidance vector from the user's position to the acoustic
/// source.
///
/// [userPos]        — user position in the same coordinate frame as [source].
/// [source]         — acoustic source position (from TDOA solver).
/// [userHeadingRad] — user's current heading clockwise from North, in
///                    radians.  Pass 0 if no magnetometer is available;
///                    the absolute bearing will still be correct, the
///                    relative bearing will just be relative to East
///                    (the +X axis of the coordinate frame).
///
/// Returns null when the user and source positions are closer than 0.1 m
/// (essentially the same point — direction is undefined).
NavigationVector? computeNavigationVector({
  required Vec3 userPos,
  required Vec3 source,
  double userHeadingRad = 0.0,
}) {
  final dx = source.x - userPos.x;
  final dy = source.y - userPos.y;
  final distanceM = math.sqrt(dx * dx + dy * dy);

  if (distanceM < 0.1) return null; // too close — bearing undefined

  // atan2 gives bearing from the +X axis (East in a standard frame).
  // The doc uses atan2(Δy, Δx) directly (§5.2), so we preserve that —
  // if the coordinate frame has +Y = North, the absolute bearing comes
  // out as a standard compass angle.  If not, the caller should rotate
  // userPos / source into a North-up frame first.
  final phi = math.atan2(dy, dx);

  // Normalise φ to [0, 2π).
  final absBearing = phi < 0 ? phi + 2 * math.pi : phi;

  // Relative bearing: how far to turn from current heading to face source.
  var relBearing = absBearing - userHeadingRad;
  relBearing = relBearing % (2 * math.pi);
  if (relBearing < 0) relBearing += 2 * math.pi;

  return NavigationVector(
    distanceM: distanceM,
    absoluteBearingRad: absBearing,
    relativeBearingRad: relBearing,
    source: source,
    user: userPos,
  );
}

/// Smooths a series of navigation vectors with a simple exponential
/// moving average on the position components, then recomputes the vector.
/// Reduces jitter from noisy RSSI trilateration without adding latency.
///
/// [alpha] — smoothing factor 0–1.  Higher = faster response, more jitter.
///   Typical: 0.3 for RSSI positioning, 0.7 for GNSS.
class NavigationSmoother {
  NavigationSmoother({this.alpha = 0.3});
  final double alpha;

  Vec3? _smoothUser;
  Vec3? _smoothSource;

  NavigationVector? update({
    required Vec3 userPos,
    required Vec3 source,
    double userHeadingRad = 0.0,
  }) {
    // EMA on positions.
    _smoothUser = _ema(_smoothUser, userPos);
    _smoothSource = _ema(_smoothSource, source);

    return computeNavigationVector(
      userPos: _smoothUser!,
      source: _smoothSource!,
      userHeadingRad: userHeadingRad,
    );
  }

  Vec3 _ema(Vec3? prev, Vec3 next) {
    if (prev == null) return next;
    return Vec3(
      prev.x + alpha * (next.x - prev.x),
      prev.y + alpha * (next.y - prev.y),
      prev.z + alpha * (next.z - prev.z),
    );
  }

  void reset() {
    _smoothUser = null;
    _smoothSource = null;
  }
}
