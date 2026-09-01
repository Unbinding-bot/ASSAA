import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../localization/fusion.dart';
import '../math3d.dart';
import '../models/node.dart';
import '../models/rescuer.dart';
import '../theme.dart';

// =============================================================================
// CameraState  — 2-D pan + zoom only (no yaw / pitch / orbit)
// =============================================================================

/// Holds the 2-D viewport state for the flat top-down map.
/// Pan offsets are in screen pixels; zoom is a dimensionless scale factor.
class CameraState extends ChangeNotifier {
  double zoom   = 1.0;
  double panX   = 0.0;
  double panY   = 0.0;

  /// Clamp zoom between 0.3× and 5×.
  void scale(double factor) {
    zoom = (zoom * factor).clamp(0.3, 5.0).toDouble();
    notifyListeners();
  }

  void pan(double dx, double dy) {
    panX += dx;
    panY += dy;
    notifyListeners();
  }

  void resetView() {
    zoom = 1.0;
    panX = 0.0;
    panY = 0.0;
    notifyListeners();
  }

  /// Optional z-layer filter for the heatmap.
  /// null = show all voxels regardless of depth.
  double? sliceMinZ;
  double? sliceMaxZ;
}

// =============================================================================
// VoxelMapPainter  — flat 2-D top-down renderer
// =============================================================================

class VoxelMapPainter extends CustomPainter {
  VoxelMapPainter({
    required this.controller,
    required this.camera,
    required this.colors,
  }) : super(repaint: camera);

  final AppController controller;
  final CameraState   camera;
  final AppColors     colors;

  AppColors get _c => colors;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width  / 2;
    final cy = size.height / 2;

    // Convenience: project a world point through the current view.
    Offset proj(Vec3 v) => projectFlat(
      v, zoom: camera.zoom, cx: cx, cy: cy,
      panX: camera.panX, panY: camera.panY,
    );

    // ── 1. Ground grid (background reference) ────────────────────────────
    _paintGroundGrid(canvas, proj, cx, cy);

    // ── 2. Voxel heatmap ─────────────────────────────────────────────────
    for (final voxel in controller.grid.cells) {
      // Z-slice filter (used when heatmap layer is on).
      if (camera.sliceMinZ != null && voxel.center.z < camera.sliceMinZ!) continue;
      if (camera.sliceMaxZ != null && voxel.center.z > camera.sliceMaxZ!) continue;
      final tier = tierFor(voxel.confidence);
      if (tier == ConfidenceTier.green && voxel.confidence < 0.12) continue;

      final centre = proj(voxel.center);
      // Radius in pixels — scales with zoom so the heatmap stays the right
      // physical size regardless of how far the user has zoomed in/out.
      final r = (controller.grid.cellSize * camera.zoom * kPixelsPerMetre * 0.45)
          .clamp(2.0, 40.0);
      canvas.drawCircle(
        centre,
        r,
        Paint()..color = _tierColor(tier)
            .withValues(alpha: 0.15 + voxel.confidence * 0.55),
      );
    }

    // ── 3. Active-quadrant triangle wireframe ────────────────────────────
    final quadrant = controller.activeQuadrant;
    if (quadrant != null && quadrant.nodes.length == 3) {
      final pts = quadrant.nodes.map((n) => proj(n.position)).toList();
      final paint = Paint()
        ..color       = _c.amber.withValues(alpha: 0.45)
        ..strokeWidth = 1.2
        ..style       = PaintingStyle.stroke;
      for (var i = 0; i < 3; i++) {
        _drawDashedLine(canvas, pts[i], pts[(i + 1) % 3], paint);
      }
    }

    // ── 4. Nodes ─────────────────────────────────────────────────────────
    for (final node in controller.nodes.values) {
      final isActive = controller.activeQuadrant?.nodes
          .any((n) => n.id == node.id) ?? false;
      _paintNode(canvas, node, proj(node.position), isActive: isActive);
    }

    // ── 5. TDOA fix ring ─────────────────────────────────────────────────
    final fix = controller.lastFix;
    if (fix != null) {
      final centre = proj(fix.position);
      canvas.drawCircle(
        centre, 14,
        Paint()
          ..color       = _c.accent.withValues(alpha: 0.9)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      // NDT badge just above the fix ring.
      final ndt = controller.lastNdtResult;
      if (ndt != null) { _paintNdtBadge(canvas, ndt, centre); }
    }

    // ── 6. Rescuer position ──────────────────────────────────────────────
    final rescuer = controller.rescuerFix;
    if (rescuer != null) {
      _paintRescuer(canvas, rescuer, proj(rescuer.position));
    }

    // ── Empty state ───────────────────────────────────────────────────────
    if (controller.nodes.isEmpty && fix == null) {
      _paintEmptyState(canvas, size);
    }
  }

  // ── Ground grid ──────────────────────────────────────────────────────────

  void _paintGroundGrid(Canvas canvas, Offset Function(Vec3) proj,
      double cx, double cy) {
    final grid     = controller.grid;
    final xMin     = grid.origin.x;
    final xMax     = xMin + grid.nx * grid.cellSize;
    final yMin     = grid.origin.y;
    final yMax     = yMin + grid.ny * grid.cellSize;
    final z        = grid.origin.z; // all grid lines at ground z

    final linePaint = Paint()
      ..color       = _c.panelBorder.withValues(alpha: 0.9)
      ..strokeWidth = 1;
    final borderPaint = Paint()
      ..color       = _c.panelBorder.withValues(alpha: 0.7)
      ..strokeWidth = 1.5;

    // Grid lines.
    for (var x = xMin; x <= xMax + 0.01; x += grid.cellSize) {
      canvas.drawLine(proj(Vec3(x, yMin, z)), proj(Vec3(x, yMax, z)), linePaint);
    }
    for (var y = yMin; y <= yMax + 0.01; y += grid.cellSize) {
      canvas.drawLine(proj(Vec3(xMin, y, z)), proj(Vec3(xMax, y, z)), linePaint);
    }

    // Bounding rectangle (2-D only — no vertical edges).
    final tl = proj(Vec3(xMin, yMax, z));
    final tr = proj(Vec3(xMax, yMax, z));
    final br = proj(Vec3(xMax, yMin, z));
    final bl = proj(Vec3(xMin, yMin, z));
    final path = Path()
      ..moveTo(tl.dx, tl.dy)
      ..lineTo(tr.dx, tr.dy)
      ..lineTo(br.dx, br.dy)
      ..lineTo(bl.dx, bl.dy)
      ..close();
    canvas.drawPath(path, borderPaint);

    // Scale tick labels along the bottom edge, every 2 m.
    for (var x = xMin; x <= xMax + 0.01; x += grid.cellSize * 2) {
      final p = proj(Vec3(x, yMin, z));
      final tp = TextPainter(
        text: TextSpan(
          text: '${x.toStringAsFixed(0)}m',
          style: TextStyle(color: _c.textDim, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(p.dx - tp.width / 2, p.dy + 4));
    }
  }

  // ── Nodes ────────────────────────────────────────────────────────────────

  void _paintNode(Canvas canvas, SensorNode node, Offset p,
      {bool isActive = false}) {
    final color = switch (node.role) {
      NodeRole.gateway  => _c.accent,
      NodeRole.tapper   => _c.amber,
      NodeRole.listener => node.isStale ? _c.textDim : _c.text,
    };

    if (isActive) {
      canvas.drawCircle(p, 11,
          Paint()
            ..color       = _c.amber.withValues(alpha: 0.75)
            ..style       = PaintingStyle.stroke
            ..strokeWidth = 2.5);
    }

    canvas.drawCircle(p, 5, Paint()..color = color);
    canvas.drawCircle(p, 7,
        Paint()
          ..color       = color.withValues(alpha: 0.5)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    final tp = TextPainter(
      text: TextSpan(
        text: '${node.id}',
        style: TextStyle(
          color:      isActive ? _c.amber : _c.textDim,
          fontSize:   10,
          fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(p.dx + 8, p.dy - 6));
  }

  // ── NDT badge ────────────────────────────────────────────────────────────

  void _paintNdtBadge(Canvas canvas, NdtResult ndt, Offset fixCentre) {
    final color = switch (ndt.label) {
      NdtLabel.solid      => _c.green,
      NdtLabel.voidRegion => _c.red,
      NdtLabel.unknown    => const Color(0xFF9E9E9E),
    };
    final label = '${ndt.displayLabel} '
        '${(ndt.confidence * 100).toStringAsFixed(0)}%';
    final tp = TextPainter(
      text: TextSpan(
        text:  label,
        style: TextStyle(
          color:       color,
          fontSize:    11,
          fontWeight:  FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const pad = 5.0;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        fixCentre.dx - tp.width / 2 - pad,
        fixCentre.dy - 32 - tp.height - pad,
        tp.width  + pad * 2,
        tp.height + pad * 2,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(rect, Paint()..color = _c.panel.withValues(alpha: 0.88));
    canvas.drawRRect(rect,
        Paint()
          ..color       = color.withValues(alpha: 0.7)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 1);
    tp.paint(canvas,
        Offset(fixCentre.dx - tp.width / 2, fixCentre.dy - 32 - tp.height));
  }

  // ── Rescuer marker ───────────────────────────────────────────────────────

  void _paintRescuer(Canvas canvas, RescuerFix rescuer, Offset p) {
    // Accuracy ring.
    final ringRadius = (rescuer.accuracyM * camera.zoom * kPixelsPerMetre)
        .clamp(6.0, 200.0);
    canvas.drawCircle(p, ringRadius,
        Paint()..color = _c.accent.withValues(alpha: 0.15));
    canvas.drawCircle(p, ringRadius,
        Paint()
          ..color       = _c.accent.withValues(alpha: 0.5)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 1.2);

    // Diamond "you are here" marker.
    final path = Path()
      ..moveTo(p.dx,     p.dy - 9)
      ..lineTo(p.dx + 7, p.dy)
      ..lineTo(p.dx,     p.dy + 9)
      ..lineTo(p.dx - 7, p.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = _c.accent);
    canvas.drawPath(path,
        Paint()
          ..color       = _c.bg
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    final tp = TextPainter(
      text: TextSpan(
        text:  'YOU (±${rescuer.accuracyM.toStringAsFixed(1)}m)',
        style: TextStyle(
          color:      _c.accent,
          fontSize:   10,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(p.dx + 10, p.dy - 6));
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dashLen = 6.0, gapLen = 4.0;
    final dx    = b.dx - a.dx, dy = b.dy - a.dy;
    final total = math.sqrt(dx * dx + dy * dy);
    if (total < 1) { return; }
    final ux = dx / total, uy = dy / total;
    var dist    = 0.0;
    var drawing = true;
    while (dist < total) {
      final segLen = drawing ? dashLen : gapLen;
      final end    = math.min(dist + segLen, total);
      if (drawing) {
        canvas.drawLine(
          Offset(a.dx + ux * dist, a.dy + uy * dist),
          Offset(a.dx + ux * end,  a.dy + uy * end),
          paint,
        );
      }
      dist    += segLen;
      drawing  = !drawing;
    }
  }

  void _paintEmptyState(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text:  'No nodes yet.\nConnect or start simulation.',
        style: TextStyle(color: _c.textDim, fontSize: 13),
      ),
      textAlign:       TextAlign.center,
      textDirection:   TextDirection.ltr,
    )..layout(maxWidth: size.width * 0.7);
    tp.paint(canvas,
        Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
  }

  Color _tierColor(ConfidenceTier t) => switch (t) {
    ConfidenceTier.red    => _c.red,
    ConfidenceTier.yellow => _c.amber,
    ConfidenceTier.green  => _c.green,
  };

  @override
  bool shouldRepaint(covariant VoxelMapPainter old) => true;
}
