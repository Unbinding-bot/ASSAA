import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../theme.dart';
import 'voxel_painter.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final camera = CameraState();
  double _gestureStartScale = 1.0;
  RangeValues _depthRange = const RangeValues(-2.5, 2.5);

  @override
  void dispose() {
    camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onScaleStart: (_) => _gestureStartScale = 1.0,
                  onScaleUpdate: (details) {
                    if (!camera.topDown) {
                      camera.orbit(
                        details.focalPointDelta.dx * 0.008,
                        details.focalPointDelta.dy * -0.008,
                      );
                    }
                    final factor = details.scale / _gestureStartScale;
                    if (factor != 1.0) {
                      camera.scale(factor);
                      _gestureStartScale = details.scale;
                    }
                  },
                  child: StreamBuilder<void>(
                    stream: widget.controller.onChange,
                    builder: (context, _) {
                      return AnimatedBuilder(
                        animation: camera,
                        builder: (context, _) {
                          return CustomPaint(
                            painter: VoxelMapPainter(
                              controller: widget.controller,
                              camera: camera,
                            ),
                            size: Size.infinite,
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                top: 12,
                right: 12,
                child: Column(
                  children: [
                    _RoundButton(
                      icon: camera.topDown ? Icons.view_in_ar : Icons.map_outlined,
                      tooltip: camera.topDown ? '3D view' : '2D top-down',
                      onTap: () => setState(camera.toggleTopDown),
                    ),
                    const SizedBox(height: 8),
                    _RoundButton(
                      icon: Icons.refresh,
                      tooltip: 'Reset camera',
                      onTap: () => setState(() {
                        camera.yaw = 0.6;
                        camera.pitch = 0.35;
                        camera.zoom = 1.0;
                      }),
                    ),
                  ],
                ),
              ),
              const Positioned(
                left: 12,
                bottom: 12,
                child: _Legend(),
              ),
            ],
          ),
        ),
        _DepthSlicer(
          range: _depthRange,
          onChanged: (r) {
            setState(() {
              _depthRange = r;
              camera.sliceMinZ = r.start;
              camera.sliceMaxZ = r.end;
            });
          },
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.panel.withValues(alpha: 0.9),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, color: AppColors.text, size: 20),
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    Widget dot(Color c, String label) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.panel.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          dot(AppColors.red, 'Check first'),
          dot(AppColors.amber, 'Void, unclear'),
          dot(AppColors.green, 'Solid, low priority'),
        ],
      ),
    );
  }
}

class _DepthSlicer extends StatelessWidget {
  const _DepthSlicer({required this.range, required this.onChanged});
  final RangeValues range;
  final ValueChanged<RangeValues> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.layers_outlined, size: 16, color: AppColors.textDim),
          const SizedBox(width: 8),
          const Text('Depth slice', style: TextStyle(color: AppColors.textDim, fontSize: 11)),
          Expanded(
            child: RangeSlider(
              min: -2.5,
              max: 2.5,
              divisions: 10,
              values: range,
              labels: RangeLabels(
                '${range.start.toStringAsFixed(1)}m',
                '${range.end.toStringAsFixed(1)}m',
              ),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}