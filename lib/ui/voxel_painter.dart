import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../localization/fusion.dart';
import '../math3d.dart';
import '../models/node.dart';
import '../models/rescuer.dart';
import '../theme.dart';

/// Camera state for the hand-rolled orbit controller. Kept separate from
/// the painter so gesture handlers can mutate it directly and trigger a
/// repaint without touching app data.
class CameraState extends ChangeNotifier {
  double yaw = 0.6; // radians
  double pitch = 0.35;
  double zoom = 1.0;
  bool topDown = false; // 2D fallback view
  double? sliceMinZ; // null = show all depths
  double? sliceMaxZ;

  void orbit(double dYaw, double dPitch) {
    yaw += dYaw;
    pitch = (pitch + dPitch).clamp(-1.4, 1.4).toDouble();
    notifyListeners();
  }

  void scale(double factor) {
    zoom = (zoom * factor).clamp(0.4, 3.0).toDouble();
    notifyListeners();
  }

  void toggleTopDown() {
    topDown = !topDown;
    notifyListeners();
  }
}

class VoxelMapPainter extends CustomPainter {
  VoxelMapPainter({
    required this.controller,
    required this.camera,
    required this.colors,
  }) : super(repaint: camera);

  final AppController controller;
  final CameraState   camera;
  final AppColors     colors;

  // Convenience getter so paint methods stay readable.
  AppColors get _c => colors;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final yaw = camera.topDown ? 0.0 : camera.yaw;
    final pitch = camera.topDown ? 1.5533 : camera.pitch; // ~89deg = looking down

    final drawables = <_Drawable>[];

    // Ground grid + bounding wireframe drawn first, as a background
    // reference layer -- this is what makes 2D and 3D feel like the same
    // map instead of a disconnected point cloud: both use the exact same
    // grid, just viewed from a different pitch.
    _paintGroundGrid(canvas, yaw, pitch, cx, cy);
    _paintBoundingBox(canvas, yaw, pitch, cx, cy);

    // Voxels (skip the lowest tier so a busy grid doesn't drown the map --
    // green is "checked, low priority", worth showing subtly, not boldly).
    for (final voxel in controller.grid.cells) {
      if (camera.sliceMinZ != null && voxel.center.z < camera.sliceMinZ!) continue;
      if (camera.sliceMaxZ != null && voxel.center.z > camera.sliceMaxZ!) continue;
      final tier = tierFor(voxel.confidence);
      if (tier == ConfidenceTier.green && voxel.confidence < 0.12) continue;

      final p = project(voxel.center, yaw: yaw, pitch: pitch, zoom: camera.zoom, cx: cx, cy: cy);
      if (p == null) continue;
      drawables.add(_Drawable(
        depth: p.depth,
        paint: (canvas) {
          final color = _tierColor(tier).withValues(alpha: 0.18 + voxel.confidence * 0.55);
          final r = (5 + voxel.confidence * 9) * p.scale / 40;
          canvas.drawCircle(Offset(p.screenX, p.screenY), r.clamp(1.5, 26).toDouble(), Paint()..color = color);
        },
      ));
    }

    // Nodes on top, always visible regardless of slice.
    for (final node in controller.nodes.values) {
      final p = project(node.position, yaw: yaw, pitch: pitch, zoom: camera.zoom, cx: cx, cy: cy);
      if (p == null) continue;
      // Check if this node is part of the active quadrant triangle.
      final isActive = controller.activeQuadrant?.nodes
          .any((n) => n.id == node.id) ?? false;
      drawables.add(_Drawable(
        depth: p.depth - 1000,
        paint: (canvas) => _paintNode(canvas, node, p, isActive: isActive),
      ));
    }

    // Last solved TDOA fix, as a pulsing marker.
    final fix = controller.lastFix;
    if (fix != null) {
      final p = project(fix.position, yaw: yaw, pitch: pitch, zoom: camera.zoom, cx: cx, cy: cy);
      if (p != null) {
        drawables.add(_Drawable(
          depth: p.depth - 2000,
          paint: (canvas) {
            canvas.drawCircle(
              Offset(p.screenX, p.screenY),
              14,
              Paint()
                ..color = _c.accent.withValues(alpha: 0.9)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2,
            );
          },
        ));
      }
    }

    // NDT classification result badge near the TDOA fix.
    final ndt = controller.lastNdtResult;
    if (ndt != null && fix != null) {
      final p = project(fix.position, yaw: yaw, pitch: pitch, zoom: camera.zoom, cx: cx, cy: cy);
      if (p != null) {
        drawables.add(_Drawable(
          depth: p.depth - 2500,
          paint: (canvas) => _paintNdtBadge(canvas, ndt, p),
        ));
      }
    }

    // Active quadrant triangle wireframe.
    final quadrant = controller.activeQuadrant;
    if (quadrant != null && quadrant.nodes.length == 3) {
      final pts = <Projected?>[];
      for (final n in quadrant.nodes) {
        pts.add(project(n.position, yaw: yaw, pitch: pitch, zoom: camera.zoom, cx: cx, cy: cy));
      }
      if (pts.every((p) => p != null)) {
        drawables.add(_Drawable(
          depth: pts.first!.depth - 500,
          paint: (canvas) => _paintTriangle(canvas, pts.cast<Projected>()),
        ));
      }
    }

    // Rescuer's own solved position -- the "you are here" dot.
    final rescuer = controller.rescuerFix;
    if (rescuer != null) {
      final p = project(rescuer.position, yaw: yaw, pitch: pitch, zoom: camera.zoom, cx: cx, cy: cy);
      if (p != null) {
        drawables.add(_Drawable(
          depth: p.depth - 3000, // always drawn on top -- this is "you"
          paint: (canvas) => _paintRescuer(canvas, rescuer, p),
        ));
      }
    }

    // Painter's algorithm: far first, near last.
    drawables.sort((a, b) => b.depth.compareTo(a.depth));
    for (final d in drawables) {
      d.paint(canvas);
    }

    if (drawables.isEmpty) {
      _paintEmptyState(canvas, size);
    }
  }

  void _paintGroundGrid(Canvas canvas, double yaw, double pitch, double cx, double cy) {
    final grid = controller.grid;
    final z = grid.origin.z; // floor of the mapped volume
    final xMin = grid.origin.x, xMax = grid.origin.x + grid.nx * grid.cellSize;
    final yMin = grid.origin.y, yMax = grid.origin.y + grid.ny * grid.cellSize;

    final linePaint = Paint()
      ..color = _c.panelBorder.withValues(alpha: 0.9)
      ..strokeWidth = 1;

    Offset? proj(Vec3 v) {
      final p = project(v, yaw: yaw, pitch: pitch, zoom: camera.zoom, cx: cx, cy: cy);
      return p == null ? null : Offset(p.screenX, p.screenY);
    }

    void line(Vec3 a, Vec3 b, {Paint? paint}) {
      final pa = proj(a), pb = proj(b);
      if (pa == null || pb == null) return;
      canvas.drawLine(pa, pb, paint ?? linePaint);
    }

    // Lines running along Y, spaced every meter along X.
    for (var x = xMin; x <= xMax + 0.01; x += grid.cellSize) {
      line(Vec3(x, yMin, z), Vec3(x, yMax, z));
    }
    // Lines running along X, spaced every meter along Y.
    for (var y = yMin; y <= yMax + 0.01; y += grid.cellSize) {
      line(Vec3(xMin, y, z), Vec3(xMax, y, z));
    }

    // Scale tick labels along the near edge, every 2m, so this reads like
    // an actual map rather than an abstract grid.
    for (var x = xMin; x <= xMax + 0.01; x += grid.cellSize * 2) {
      final p = proj(Vec3(x, yMin, z));
      if (p == null) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: '${(x).toStringAsFixed(0)}m',
          style: TextStyle(color: _c.textDim, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(p.dx - tp.width / 2, p.dy + 4));
    }
  }

  void _paintBoundingBox(Canvas canvas, double yaw, double pitch, double cx, double cy) {
    final grid = controller.grid;
    final x0 = grid.origin.x, x1 = grid.origin.x + grid.nx * grid.cellSize;
    final y0 = grid.origin.y, y1 = grid.origin.y + grid.ny * grid.cellSize;
    final z0 = grid.origin.z, z1 = grid.origin.z + grid.nz * grid.cellSize;

    final paint = Paint()
      ..color = _c.panelBorder.withValues(alpha: 0.7)
      ..strokeWidth = 1;

    Offset? proj(Vec3 v) {
      final p = project(v, yaw: yaw, pitch: pitch, zoom: camera.zoom, cx: cx, cy: cy);
      return p == null ? null : Offset(p.screenX, p.screenY);
    }

    void edge(Vec3 a, Vec3 b) {
      final pa = proj(a), pb = proj(b);
      if (pa == null || pb == null) return;
      canvas.drawLine(pa, pb, paint);
    }

    // Only draw the vertical corner edges and top rectangle -- the bottom
    // rectangle is already implied by the ground grid, and a full 12-edge
    // wireframe gets visually noisy once voxels are drawn on top.
    final corners = [
      Vec3(x0, y0, z0), Vec3(x1, y0, z0), Vec3(x1, y1, z0), Vec3(x0, y1, z0),
    ];
    final topCorners = [
      Vec3(x0, y0, z1), Vec3(x1, y0, z1), Vec3(x1, y1, z1), Vec3(x0, y1, z1),
    ];
    for (var i = 0; i < 4; i++) {
      edge(corners[i], topCorners[i]); // vertical edges
      edge(topCorners[i], topCorners[(i + 1) % 4]); // top rectangle
    }
  }

  void _paintRescuer(Canvas canvas, RescuerFix rescuer, Projected p) {
    // Accuracy ring first (behind the marker), sized relative to the
    // projected scale so it shrinks/grows correctly with zoom/distance.
    final ringRadius = (rescuer.accuracyM * p.scale).clamp(6.0, 400.0).toDouble();
    canvas.drawCircle(
      Offset(p.screenX, p.screenY),
      ringRadius,
      Paint()
        ..color = _c.accent.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(p.screenX, p.screenY),
      ringRadius,
      Paint()
        ..color = _c.accent.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // "You are here" marker: a small filled diamond reads as distinct from
    // the round node markers and the TDOA fix's hollow ring.
    final path = Path()
      ..moveTo(p.screenX, p.screenY - 9)
      ..lineTo(p.screenX + 7, p.screenY)
      ..lineTo(p.screenX, p.screenY + 9)
      ..lineTo(p.screenX - 7, p.screenY)
      ..close();
    canvas.drawPath(path, Paint()..color = _c.accent);
    canvas.drawPath(
      path,
      Paint()
        ..color = _c.bg
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final tp = TextPainter(
      text: TextSpan(
        text: 'YOU (\u00b1${rescuer.accuracyM.toStringAsFixed(1)}m)',
        style: TextStyle(color: _c.accent, fontSize: 10, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(p.screenX + 10, p.screenY - 6));
  }

  void _paintNode(Canvas canvas, SensorNode node, Projected p, {bool isActive = false}) {
    Color color;
    switch (node.role) {
      case NodeRole.gateway:
        color = _c.accent;
        break;
      case NodeRole.tapper:
        color = _c.amber;
        break;
      case NodeRole.listener:
        color = node.isStale ? _c.textDim : _c.text;
        break;
    }

    // Active quadrant nodes get a highlighted outer ring.
    if (isActive) {
      canvas.drawCircle(
        Offset(p.screenX, p.screenY),
        11,
        Paint()
          ..color = _c.amber.withValues(alpha: 0.75)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }

    canvas.drawCircle(Offset(p.screenX, p.screenY), 5, Paint()..color = color);
    canvas.drawCircle(
      Offset(p.screenX, p.screenY),
      7,
      Paint()
        ..color = color.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: '${node.id}',
        style: TextStyle(
          color: isActive ? _c.amber : _c.textDim,
          fontSize: 10,
          fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(p.screenX + 8, p.screenY - 6));
  }

  /// Draws a dashed triangle connecting the 3 active quadrant nodes.
  void _paintTriangle(Canvas canvas, List<Projected> pts) {
    final paint = Paint()
      ..color = _c.amber.withValues(alpha: 0.45)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    for (var i = 0; i < 3; i++) {
      final a = Offset(pts[i].screenX, pts[i].screenY);
      final b = Offset(pts[(i + 1) % 3].screenX, pts[(i + 1) % 3].screenY);
      _drawDashedLine(canvas, a, b, paint);
    }
  }

  void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dashLen = 6.0, gapLen = 4.0;
    final dx = b.dx - a.dx, dy = b.dy - a.dy;
    final total = math.sqrt(dx * dx + dy * dy);
    if (total < 1) { return; }
    final ux = dx / total, uy = dy / total;
    var dist = 0.0;
    var drawing = true;
    while (dist < total) {
      final segLen = drawing ? dashLen : gapLen;
      final end = math.min(dist + segLen, total);
      if (drawing) {
        canvas.drawLine(
          Offset(a.dx + ux * dist, a.dy + uy * dist),
          Offset(a.dx + ux * end,  a.dy + uy * end),
          paint,
        );
      }
      dist += segLen;
      drawing = !drawing;
    }
  }

  /// Draws the NDT classification badge (SOLID / VOID / UNKNOWN)
  /// offset slightly above the TDOA fix ring.
  void _paintNdtBadge(Canvas canvas, NdtResult ndt, Projected p) {
    final color = switch (ndt.label) {
      NdtLabel.solid      => _c.green,
      NdtLabel.voidRegion => _c.red,
      NdtLabel.unknown    => const Color(0xFF9E9E9E),
    };

    final label = '${ndt.displayLabel} '
        '${(ndt.confidence * 100).toStringAsFixed(0)}%';

    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Background pill
    const pad = 5.0;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        p.screenX - tp.width / 2 - pad,
        p.screenY - 32 - tp.height - pad,
        tp.width + pad * 2,
        tp.height + pad * 2,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(
      rect,
      Paint()..color = _c.panel.withValues(alpha: 0.88),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = color.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    tp.paint(canvas, Offset(p.screenX - tp.width / 2, p.screenY - 32 - tp.height));
  }

  void _paintEmptyState(Canvas canvas, Size size) {    final tp = TextPainter(
      text: TextSpan(
        text: 'No nodes yet.\nConnect or start simulation.',
        style: TextStyle(color: _c.textDim, fontSize: 13),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width * 0.7);
    tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
  }

  Color _tierColor(ConfidenceTier t) {
    switch (t) {
      case ConfidenceTier.red:
        return _c.red;
      case ConfidenceTier.yellow:
        return _c.amber;
      case ConfidenceTier.green:
        return _c.green;
    }
  }

  @override
  bool shouldRepaint(covariant VoxelMapPainter oldDelegate) => true;
}

class _Drawable {
  final double depth;
  final void Function(Canvas) paint;
  _Drawable({required this.depth, required this.paint});
}