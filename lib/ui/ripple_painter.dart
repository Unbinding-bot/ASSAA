import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../math3d.dart';
import '../models/frequency_band.dart';

// =============================================================================
// Ripple data model
// =============================================================================

/// One detected acoustic event that produces a visible ripple on the map.
class RippleEvent {
  final Vec3     position;     // world-space epicentre (only x/y used for drawing)
  final double   fPeakHz;      // dominant frequency → drives colour
  final DateTime detectedAt;
  final double   durationSecs;

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
// RipplePainter  — flat 2-D expanding rings
// =============================================================================

/// Paints phase-staggered expanding rings on the flat top-down map.
///
/// Each [RippleEvent] spawns [ringCount] concentric rings that travel
/// outward from the epicentre. Ring colour is looked up from the
/// frequency→colour palette (user-editable in Settings).
/// Ring size is fixed in screen-pixels (not perspective-scaled) so the
/// animation looks consistent at every zoom level.
class RipplePainter extends CustomPainter {
  RipplePainter({
    required this.events,
    required this.palette,
    required this.animation,
    required this.zoom,
    required this.cx,
    required this.cy,
    required this.panX,
    required this.panY,
  }) : super(repaint: animation);

  final List<RippleEvent>   events;
  final List<FrequencyBand> palette;
  final Animation<double>   animation;
  final double zoom, cx, cy, panX, panY;

  static const int    ringCount   = 4;
  static const double maxRadiusPx = 90.0;
  static const double ringSpacing = 0.25; // phase offset between rings (0–1)

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();

    for (final event in events) {
      if (event.isExpired(now)) { continue; }

      final centre = projectFlat(
        event.position,
        zoom: zoom, cx: cx, cy: cy, panX: panX, panY: panY,
      );

      final t         = event.progressAt(now);
      final baseColor = rippleColorForFrequency(event.fPeakHz, palette);

      for (var ring = 0; ring < ringCount; ring++) {
        final phase  = (t + ring * ringSpacing) % 1.0;
        final radius = phase * maxRadiusPx;

        final ringAlpha  = (1.0 - math.pow(phase, 1.8)).clamp(0.0, 1.0);
        final eventAlpha = t < 0.7
            ? 1.0
            : (1.0 - (t - 0.7) / 0.3).clamp(0.0, 1.0);
        final alpha = (ringAlpha * eventAlpha * 0.75).clamp(0.0, 1.0);

        if (alpha < 0.01 || radius < 0.5) { continue; }

        // Faint glow fill.
        canvas.drawCircle(centre, radius,
            Paint()
              ..color = baseColor.withValues(alpha: alpha * 0.12)
              ..style = PaintingStyle.fill);

        // Ring stroke.
        canvas.drawCircle(centre, radius,
            Paint()
              ..color       = baseColor.withValues(alpha: alpha)
              ..style       = PaintingStyle.stroke
              ..strokeWidth = (1.5 + (1.0 - phase) * 1.5).clamp(0.8, 3.0));
      }

      // Epicentre dot — visible while event is young.
      if (t < 0.6) {
        final dotAlpha = (1.0 - t / 0.6).clamp(0.0, 1.0);
        canvas.drawCircle(centre, 4.0,
            Paint()..color = baseColor.withValues(alpha: dotAlpha));
      }
    }
  }

  @override
  bool shouldRepaint(covariant RipplePainter old) =>
      old.events != events ||
      old.palette != palette ||
      old.zoom != zoom ||
      old.panX != panX ||
      old.panY != panY;
}

// =============================================================================
// WaypointPainter  — flat 2-D flag markers
// =============================================================================

/// Paints waypoint flag markers on the flat top-down map.
/// Flags glow when they are the active navigation target.
class WaypointPainter extends CustomPainter {
  WaypointPainter({
    required this.waypoints,
    required this.zoom,
    required this.cx,
    required this.cy,
    required this.panX,
    required this.panY,
    this.panelColor   = const Color(0xFF12171A),
    this.textDimColor = const Color(0xFF7C8B90),
  });

  final List<({Vec3 pos, Color color, String label, bool isTarget, bool visible})>
      waypoints;
  final double zoom, cx, cy, panX, panY;
  final Color  panelColor, textDimColor;

  @override
  void paint(Canvas canvas, Size size) {
    for (final wp in waypoints) {
      if (!wp.visible) { continue; }

      final c = projectFlat(
        wp.pos,
        zoom: zoom, cx: cx, cy: cy, panX: panX, panY: panY,
      );

      // Glow ring for active nav target.
      if (wp.isTarget) {
        canvas.drawCircle(c, 18,
            Paint()..color = wp.color.withValues(alpha: 0.25));
        canvas.drawCircle(c, 18,
            Paint()
              ..color       = wp.color.withValues(alpha: 0.7)
              ..style       = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }

      // Pole.
      canvas.drawLine(
        c, c.translate(0, -16),
        Paint()
          ..color       = wp.color.withValues(alpha: 0.8)
          ..strokeWidth = 1.5
          ..style       = PaintingStyle.stroke,
      );

      // Flag triangle.
      canvas.drawPath(
        Path()
          ..moveTo(c.dx,      c.dy - 16)
          ..lineTo(c.dx + 9,  c.dy - 12)
          ..lineTo(c.dx,      c.dy - 8)
          ..close(),
        Paint()..color = wp.color,
      );

      // Label.
      final tp = TextPainter(
        text: TextSpan(
          text:  wp.label,
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
