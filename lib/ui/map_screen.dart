import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../math3d.dart';
import '../models/app_settings.dart';
import '../models/waypoint.dart';
import '../theme.dart';
import 'ripple_painter.dart';
import 'voxel_painter.dart';

export 'voxel_painter.dart' show CameraState;

// =============================================================================
// MapScreen
// =============================================================================

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.controller, required this.settings});
  final AppController controller;
  final AppSettings   settings;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin {
  final camera = CameraState();
  double _gestureStartScale = 1.0;
  RangeValues _depthRange = const RangeValues(-2.5, 2.5);

  // Ripple animation controller — drives repaints for all active ripples.
  late final AnimationController _rippleCtrl;
  late final Animation<double>   _rippleAnim;

  // Live ripple event list — populated whenever a new TDOA fix arrives.
  final List<RippleEvent> _rippleEvents = [];
  double? _lastFixConfidence;

  // Pending waypoint placement (set when user taps in placement mode).
  bool _waypointPlacementMode = false;

  @override
  void initState() {
    super.initState();
    _rippleCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(seconds: 60), // long-running, looping
    )..repeat();
    _rippleAnim = _rippleCtrl;

    // Watch for new TDOA fixes and spawn ripples.
    widget.controller.onChange.listen((_) => _onControllerUpdate());
  }

  void _onControllerUpdate() {
    final fix = widget.controller.lastFix;
    final ndt = widget.controller.lastNdtResult;
    if (fix == null) { return; }

    // Only spawn a new ripple when a genuinely new fix lands.
    if (fix.confidence == _lastFixConfidence) { return; }
    _lastFixConfidence = fix.confidence;

    // Frequency: derive a proxy from the NDT result label if available,
    // otherwise use confidence to map to the knock/scream/impact range.
    final double fPeak;
    if (ndt != null) {
      fPeak = switch (ndt.label) {
        NdtLabel.solid        => 3500.0,
        NdtLabel.delamination => 1500.0,
        NdtLabel.voidRegion   =>  400.0,
      };
    } else {
      fPeak = 300.0 + fix.confidence * 4000.0;
    }

    // Remove expired events before adding a new one.
    _rippleEvents.removeWhere((e) => e.isExpired(DateTime.now()));

    setState(() {
      _rippleEvents.add(RippleEvent(
        position: fix.position,
        fPeakHz:  fPeak.clamp(100.0, 10000.0),
      ));
    });
  }


  @override
  void dispose() {
    _rippleCtrl.dispose();
    camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) => _buildInner(context),
    );
  }

  Widget _buildInner(BuildContext context) {
    final settings = widget.settings;
    final c        = settings.colors;

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              // ── Base: voxel 3D map canvas ─────────────────────────────────
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
                  onTapUp: _waypointPlacementMode ? _onMapTap : null,
                  child: StreamBuilder<void>(
                    stream: widget.controller.onChange,
                    builder: (ctx, _) => AnimatedBuilder(
                      animation: camera,
                      builder: (ctx, _) => LayoutBuilder(
                        builder: (ctx, constraints) {
                          final cx = constraints.maxWidth / 2;
                          final cy = constraints.maxHeight / 2;
                          final yaw   = camera.topDown ? 0.0   : camera.yaw;
                          final pitch = camera.topDown ? 1.5533 : camera.pitch;

                          return Stack(children: [
                            // Layer: voxel heatmap
                            if (settings.layers.heatmap || settings.layers.nodes)
                              CustomPaint(
                                painter: VoxelMapPainter(
                                  controller: widget.controller,
                                  camera:     camera,
                                  colors:     c,
                                ),
                                size: Size.infinite,
                              ),

                            // Layer: ripples
                            if (settings.layers.ripples)
                              CustomPaint(
                                painter: RipplePainter(
                                  events:    _rippleEvents,
                                  palette:   settings.frequencyPalette,
                                  animation: _rippleAnim,
                                  yaw: yaw, pitch: pitch,
                                  zoom: camera.zoom,
                                  cx: cx, cy: cy,
                                ),
                                size: Size.infinite,
                              ),

                            // Layer: flags / waypoints
                            if (settings.layers.flags)
                              CustomPaint(
                                painter: WaypointPainter(
                                  waypoints: settings.waypoints
                                      .map((w) => (
                                            pos:      w.position,
                                            color:    w.color,
                                            label:    w.label,
                                            isTarget: w.isNavTarget,
                                            visible:  w.visible,
                                          ))
                                      .toList(),
                                  yaw: yaw, pitch: pitch,
                                  zoom: camera.zoom,
                                  cx: cx, cy: cy,
                                  panelColor:   c.panel,
                                  textDimColor: c.textDim,
                                ),
                                size: Size.infinite,
                              ),
                          ]);
                        },
                      ),
                    ),
                  ),
                ),
              ),

              // ── Top-right camera controls ─────────────────────────────────
              Positioned(
                top: 12, right: 12,
                child: Column(
                  children: [
                    _RoundButton(
                      c:       c,
                      icon:    camera.topDown ? Icons.view_in_ar : Icons.map_outlined,
                      tooltip: camera.topDown ? '3D view' : '2D top-down',
                      onTap:   () => setState(camera.toggleTopDown),
                    ),
                    const SizedBox(height: 8),
                    _RoundButton(
                      c:       c,
                      icon:    Icons.refresh,
                      tooltip: 'Reset camera',
                      onTap:   () => setState(() {
                        camera.yaw   = 0.6;
                        camera.pitch = 0.35;
                        camera.zoom  = 1.0;
                      }),
                    ),
                    const SizedBox(height: 8),
                    _RoundButton(
                      c:       c,
                      icon:    _waypointPlacementMode
                          ? Icons.location_on
                          : Icons.add_location_alt_outlined,
                      tooltip: _waypointPlacementMode
                          ? 'Cancel flag placement'
                          : 'Place flag',
                      onTap: () => setState(
                          () => _waypointPlacementMode = !_waypointPlacementMode),
                      active: _waypointPlacementMode,
                    ),
                  ],
                ),
              ),

              // ── Top-left NDT panel ────────────────────────────────────────
              Positioned(
                top: 12, left: 12,
                child: StreamBuilder<void>(
                  stream: widget.controller.onChange,
                  builder: (ctx, _) {
                    final ndt = widget.controller.lastNdtResult;
                    final q   = widget.controller.activeQuadrant;
                    if (ndt == null) { return const SizedBox.shrink(); }
                    return _NdtPanel(result: ndt, quadrant: q, c: c);
                  },
                ),
              ),

              // ── Placement mode banner ─────────────────────────────────────
              if (_waypointPlacementMode)
                Positioned(
                  top: 0, left: 0, right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    color: c.accent.withValues(alpha: 0.85),
                    child: Text(
                      'TAP MAP TO PLACE FLAG',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color:       c.bg,
                        fontSize:    12,
                        fontWeight:  FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ),

              // ── Bottom: floating layer chip bar ───────────────────────────
              Positioned(
                left: 8, right: 8, bottom: 8,
                child: _LayerChipBar(settings: settings, c: c),
              ),
            ],
          ),
        ),

        // ── Depth slicer ───────────────────────────────────────────────────
        _DepthSlicer(
          range:    _depthRange,
          c:        c,
          onChanged: (r) {
            setState(() {
              _depthRange      = r;
              camera.sliceMinZ = r.start;
              camera.sliceMaxZ = r.end;
            });
          },
        ),
      ],
    );
  }

  // ── Waypoint placement ────────────────────────────────────────────────────

  void _onMapTap(TapUpDetails details) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) { return; }

    final localPos = renderBox.globalToLocal(details.globalPosition);
    final cx = renderBox.size.width  / 2;
    final cy = renderBox.size.height / 2;

    const focalLength    = 900.0;
    const cameraDistance = 14.0;
    final scale = (focalLength * camera.zoom) / (0.0 + cameraDistance);
    final wx    = (localPos.dx - cx) / scale;
    final wy    = -(localPos.dy - cy) / scale;

    final settings = widget.settings;
    final idx      = settings.waypoints.length + 1;
    final wp = Waypoint(
      id:       'flag_$idx',
      label:    'Flag $idx',
      position: Vec3(wx, wy, 0.0),
      color:    const Color(0xFFFF5722),
    );
    settings.addWaypoint(wp);
    setState(() => _waypointPlacementMode = false);
  }
}

// =============================================================================
// Floating layer chip bar  (spec §3)
// =============================================================================

class _LayerChipBar extends StatelessWidget {
  const _LayerChipBar({required this.settings, required this.c});
  final AppSettings settings;
  final AppColors   c;

  @override
  Widget build(BuildContext context) {
    final layers = [
      ('nodes',    Icons.sensors,              'Nodes'),
      ('ripples',  Icons.radio_button_unchecked,'Ripples'),
      ('heatmap',  Icons.grid_4x4,             'Heatmap'),
      ('flags',    Icons.flag,                 'Flags'),
      ('guidance', Icons.explore,              'Vectors'),
    ];

    final active = {
      'nodes':    settings.layers.nodes,
      'ripples':  settings.layers.ripples,
      'heatmap':  settings.layers.heatmap,
      'flags':    settings.layers.flags,
      'guidance': settings.layers.guidance,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color:        c.panel.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(24),
        border:       Border.all(color: c.panelBorder),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withValues(alpha: 0.3),
            blurRadius: 8,
            offset:     const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ...layers.map((layer) {
            final key     = layer.$1;
            final icon    = layer.$2;
            final label   = layer.$3;
            final enabled = active[key] ?? false;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: _LayerChip(
                icon:    icon,
                label:   label,
                enabled: enabled,
                c:       c,
                onTap:   () => settings.toggleLayer(key),
              ),
            );
          }),
          const SizedBox(width: 4),
          Container(width: 1, height: 20, color: c.panelBorder),
          const SizedBox(width: 4),
          _LayerChip(
            icon:    Icons.settings,
            label:   'Config',
            enabled: false,
            c:       c,
            onTap:   () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
    );
  }
}

class _LayerChip extends StatelessWidget {
  const _LayerChip({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.c,
    required this.onTap,
  });
  final IconData icon;
  final String   label;
  final bool     enabled;
  final AppColors c;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? c.accent : c.textDim;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color:        enabled
              ? c.accent.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: enabled ? c.accent.withValues(alpha: 0.5) : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: fg, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Shared small widgets
// =============================================================================

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.c,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });
  final AppColors    c;
  final IconData     icon;
  final String       tooltip;
  final VoidCallback onTap;
  final bool         active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color:  active
            ? c.accent.withValues(alpha: 0.9)
            : c.panel.withValues(alpha: 0.9),
        shape:  const CircleBorder(),
        child:  InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon,
                color: active ? c.bg : c.text, size: 20),
          ),
        ),
      ),
    );
  }
}

class _DepthSlicer extends StatelessWidget {
  const _DepthSlicer({
    required this.range,
    required this.c,
    required this.onChanged,
  });
  final RangeValues             range;
  final AppColors               c;
  final ValueChanged<RangeValues> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color:   c.panel,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.layers_outlined, size: 16, color: c.textDim),
          const SizedBox(width: 8),
          Text('Depth slice',
              style: TextStyle(color: c.textDim, fontSize: 11)),
          Expanded(
            child: RangeSlider(
              min:        -2.5,
              max:         2.5,
              divisions:  10,
              values:     range,
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

// =============================================================================
// NDT result panel  (carried forward, now theme-aware)
// =============================================================================

class _NdtPanel extends StatelessWidget {
  const _NdtPanel({
    required this.result,
    required this.quadrant,
    required this.c,
  });
  final NdtResult        result;
  final QuadrantResult?  quadrant;
  final AppColors        c;

  @override
  Widget build(BuildContext context) {
    final color = switch (result.label) {
      NdtLabel.solid        => c.green,
      NdtLabel.delamination => c.amber,
      NdtLabel.voidRegion   => c.red,
    };
    final icon = switch (result.label) {
      NdtLabel.solid        => Icons.check_circle_outline,
      NdtLabel.delamination => Icons.warning_amber_outlined,
      NdtLabel.voidRegion   => Icons.cancel_outlined,
    };
    final nodeIds =
        quadrant?.nodes.map((n) => n.id.toString()).join(', ') ?? '—';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color:         c.panel.withValues(alpha: 0.9),
        borderRadius:  BorderRadius.circular(8),
        border:        Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Text(result.displayLabel,
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.bold,
                      fontSize: 13, letterSpacing: 0.8)),
              const SizedBox(width: 8),
              Text('${(result.confidence * 100).toStringAsFixed(0)}%',
                  style: TextStyle(color: c.textDim, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 4),
          Text('Triangle: nodes $nodeIds',
              style: TextStyle(color: c.textDim, fontSize: 10)),
          const SizedBox(height: 2),
          _ProbBar('Solid',
              result.probabilities[NdtLabel.solid] ?? 0,       c.green, c),
          _ProbBar('Delam',
              result.probabilities[NdtLabel.delamination] ?? 0, c.amber, c),
          _ProbBar('Void',
              result.probabilities[NdtLabel.voidRegion] ?? 0,   c.red,   c),
        ],
      ),
    );
  }
}

class _ProbBar extends StatelessWidget {
  const _ProbBar(this.label, this.value, this.color, this.c);
  final String    label;
  final double    value;
  final Color     color;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            child: Text(label,
                style: TextStyle(color: c.textDim, fontSize: 9)),
          ),
          SizedBox(
            width: 60, height: 5,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: value.clamp(0.0, 1.0).toDouble(),
                backgroundColor: c.panelBorder,
                valueColor: AlwaysStoppedAnimation<Color>(
                    color.withValues(alpha: 0.8)),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text('${(value * 100).toStringAsFixed(0)}%',
              style: TextStyle(color: c.textDim, fontSize: 9)),
        ],
      ),
    );
  }
}
