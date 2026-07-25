import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../localization/fusion.dart';
import '../math3d.dart';
import '../models/node.dart';
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

    // Painter's algorithm: far first, near last.
    drawables.sort((a, b) => b.depth.compareTo(a.depth));
    for (final d in drawables) {
      d.paint(canvas);
    }

    if (drawables.isEmpty) {
      _paintEmptyState(canvas, size);
    }
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