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
  }) : super(repaint: camera);

  final AppController controller;
  final CameraState camera;

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
      drawables.add(_Drawable(
        depth: p.depth - 1000, // nodes render in front of voxels at similar depth
        paint: (canvas) => _paintNode(canvas, node, p),
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
                ..color = AppColors.accent.withValues(alpha: 0.9)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2,
            );
          },
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
      ..color = AppColors.panelBorder.withValues(alpha: 0.9)
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
          style: const TextStyle(color: AppColors.textDim, fontSize: 9),
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
      ..color = AppColors.panelBorder.withValues(alpha: 0.7)
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
        ..color = AppColors.accent.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(p.screenX, p.screenY),
      ringRadius,
      Paint()
        ..color = AppColors.accent.withValues(alpha: 0.5)
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
    canvas.drawPath(path, Paint()..color = AppColors.accent);
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.bg
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final tp = TextPainter(
      text: TextSpan(
        text: 'YOU (\u00b1${rescuer.accuracyM.toStringAsFixed(1)}m)',
        style: const TextStyle(color: AppColors.accent, fontSize: 10, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(p.screenX + 10, p.screenY - 6));
  }

  void _paintNode(Canvas canvas, SensorNode node, Projected p) {
    Color color;
    switch (node.role) {
      case NodeRole.gateway:
        color = AppColors.accent;
        break;
      case NodeRole.tapper:
        color = AppColors.amber;
        break;
      case NodeRole.listener:
        color = node.isStale ? AppColors.textDim : AppColors.text;
        break;
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
        style: const TextStyle(color: AppColors.textDim, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(p.screenX + 8, p.screenY - 6));
  }

  void _paintEmptyState(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: const TextSpan(
        text: 'No nodes yet.\nConnect or start simulation.',
        style: TextStyle(color: AppColors.textDim, fontSize: 13),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width * 0.7);
    tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
  }

  Color _tierColor(ConfidenceTier t) {
    switch (t) {
      case ConfidenceTier.red:
        return AppColors.red;
      case ConfidenceTier.yellow:
        return AppColors.amber;
      case ConfidenceTier.green:
        return AppColors.green;
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