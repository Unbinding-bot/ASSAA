import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../math3d.dart';
import '../models/frequency_band.dart';

// =============================================================================
// Ripple data model
// =============================================================================

/// One detected acoustic event that produces a visible ripple on the map.
class RippleEvent {
  final Vec3    position;      // world-space position of the epicentre
  final double  fPeakHz;       // dominant frequency → drives colour
  final DateTime detectedAt;   // wall-clock time of detection
  final double  durationSecs;  // how long the ripple expands before fading

  RippleEvent({
    required this.position,
    required this.fPeakHz,
    DateTime? detectedAt,
    this.durationSecs = 2.5,
  }) : detectedAt = detectedAt ?? DateTime.now();

  /// 0 = just detected, 1 = fully faded.
  double progressAt(DateTime now) {
    final elapsed = now.difference(detectedAt).inMilliseconds / 1000.0;
    return (elapsed / durationSecs).clamp(0.0, 1.0);
  }

  bool isExpired(DateTime now) => progressAt(now) >= 1.0;
}

// =============================================================================
// Animated ripple painter
// =============================================================================

/// Paints phase-staggered expanding rings (spec §4):
///
///   • Each [RippleEvent] spawns [ringCount] concentric rings.
///   • Rings are staggered in time so they emanate from the epicentre
///     as a travelling wavefront rather than expanding together.
///   • Ring colour is looked up from the frequency→colour palette
///     (spec §4.1: yellow/green/red default; user-editable).
///   • Ring opacity falls off toward 0 as the event ages, giving a
///     smooth fade-out without abrupt disappearance.
///
/// This painter is a [CustomPainter] driven by an [AnimationController]
/// and does not own state — the parent widget owns [events] and [animation].
class RipplePainter extends CustomPainter {
  RipplePainter({
    required this.events,
    required this.palette,
    required this.animation,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.cx,
    required this.cy,
  }) : super(repaint: animation);

  final List<RippleEvent>    events;
  final List<FrequencyBand>  palette;
  final Animation<double>    animation; // drives repaints, value unused directly
  final double yaw, pitch, zoom, cx, cy;

  static const int    ringCount    = 4;     // rings per event
  static const double maxRadiusPx  = 90.0;  // max ring radius on screen
  static const double ringSpacing  = 0.25;  // phase offset between rings (0–1)

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();

    for (final event in events) {
      if (event.isExpired(now)) { continue; }

      // Project epicentre to screen.
      final proj = project(
        event.position,
        yaw:   yaw,
        pitch: pitch,
        zoom:  zoom,
        cx:    cx,
        cy:    cy,
      );
      if (proj == null) { continue; }

      final centre = Offset(proj.screenX, proj.screenY);
      final t      = event.progressAt(now);          // 0→1 overall event age
      final baseColor = rippleColorForFrequency(event.fPeakHz, palette);

      for (var ring = 0; ring < ringCount; ring++) {
        // Each ring is phase-offset so they travel outward sequentially.
        final phase   = (t + ring * ringSpacing) % 1.0;
        final radius  = phase * maxRadiusPx * proj.scale / 30.0;

        // Opacity: full at phase=0.2, zero at phase=1.0. Also fade the
        // entire event out during the last 30% of its lifetime.
        final ringAlpha  = (1.0 - math.pow(phase, 1.8)).clamp(0.0, 1.0);
        final eventAlpha = t < 0.7 ? 1.0 : (1.0 - (t - 0.7) / 0.3).clamp(0.0, 1.0);
        final alpha      = (ringAlpha * eventAlpha * 0.75).clamp(0.0, 1.0);

        if (alpha < 0.01 || radius < 0.5) { continue; }

        // Outer glow fill (very faint).
        canvas.drawCircle(
          centre,
          radius,
          Paint()
            ..color = baseColor.withValues(alpha: alpha * 0.12)
            ..style = PaintingStyle.fill,
        );

        // Ring stroke (main visible element).
        canvas.drawCircle(
          centre,
          radius,
          Paint()
            ..color = baseColor.withValues(alpha: alpha)
            ..style = PaintingStyle.stroke
            ..strokeWidth = (1.5 + (1.0 - phase) * 1.5).clamp(0.8, 3.0),
        );
      }

      // Epicentre dot — solid, always at full opacity while event is young.
      if (t < 0.6) {
        final dotAlpha = (1.0 - t / 0.6).clamp(0.0, 1.0);
        canvas.drawCircle(
          centre,
          4.0,
          Paint()..color = baseColor.withValues(alpha: dotAlpha),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant RipplePainter old) =>
      old.events != events ||
      old.palette != palette ||
      old.yaw != yaw || old.pitch != pitch ||
      old.zoom != zoom;
}

// =============================================================================
// Waypoint painter
// =============================================================================

/// Paints flag markers on the map canvas at world-space positions.
/// Flags glow when they are the active nav target.
class WaypointPainter extends CustomPainter {
  WaypointPainter({
    required this.waypoints,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.cx,
    required this.cy,
    this.panelColor   = const Color(0xFF12171A),
    this.textDimColor = const Color(0xFF7C8B90),
  });

  final List<({Vec3 pos, Color color, String label, bool isTarget, bool visible})> waypoints;
  final double yaw, pitch, zoom, cx, cy;
  final Color panelColor;
  final Color textDimColor;

  @override
  void paint(Canvas canvas, Size size) {
    for (final wp in waypoints) {
      if (!wp.visible) { continue; }
      final proj = project(
        wp.pos,
        yaw: yaw, pitch: pitch, zoom: zoom, cx: cx, cy: cy,
      );
      if (proj == null) { continue; }

      final c = Offset(proj.screenX, proj.screenY);

      // Glow ring for active nav target.
      if (wp.isTarget) {
        canvas.drawCircle(c, 18,
            Paint()..color = wp.color.withValues(alpha: 0.25));
        canvas.drawCircle(c, 18,
            Paint()
              ..color = wp.color.withValues(alpha: 0.7)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }

      // Flag icon: a pole + rectangular flag.
      final flagPaint = Paint()..color = wp.color;
      final polePaint = Paint()
        ..color = wp.color.withValues(alpha: 0.8)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      // Pole
      canvas.drawLine(c, c.translate(0, -16), polePaint);
      // Flag rectangle
      final flagPath = Path()
        ..moveTo(c.dx, c.dy - 16)
        ..lineTo(c.dx + 9, c.dy - 12)
        ..lineTo(c.dx, c.dy - 8)
        ..close();
      canvas.drawPath(flagPath, flagPaint);

      // Label
      final tp = TextPainter(
        text: TextSpan(
          text: wp.label,
          style: TextStyle(color: textDimColor, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(c.dx + 11, c.dy - 21));
    }
  }

  @override
  bool shouldRepaint(covariant WaypointPainter old) => true;
}
