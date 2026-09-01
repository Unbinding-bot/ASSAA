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
// MapScreen  — flat 2-D top-down acoustic map
// =============================================================================

class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.controller,
    required this.settings,
  });
  final AppController controller;
  final AppSettings   settings;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin {
  final camera = CameraState();

  // Gesture state.
  double _gestureStartScale = 1.0;
  Offset _gestureStartFocal = Offset.zero;

  // Ripple animation.
  late final AnimationController _rippleCtrl;
  late final Animation<double>   _rippleAnim;
  final List<RippleEvent> _rippleEvents  = [];
  Vec3?    _lastRipplePos;
  DateTime _lastRippleAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _kRippleDebounce = Duration(seconds: 2);

  // Waypoint placement mode.
  bool _waypointPlacementMode = false;

  @override
  void initState() {
    super.initState();
    _rippleCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(seconds: 60),
    )..repeat();
    _rippleAnim = _rippleCtrl;

    widget.controller.onChange.listen((_) => _onControllerUpdate());
  }

  void _onControllerUpdate() {
    final fix = widget.controller.lastFix;
    if (fix == null) { return; }

    final now = DateTime.now();

    // Only spawn a ripple when:
    //  • 2 s have elapsed since the last one, AND
    //  • the fix position has moved by at least 0.1 m (genuine new solve)
    final movedEnough = _lastRipplePos == null ||
        fix.position.distanceTo2d(_lastRipplePos!) > 0.1;
    if (!movedEnough) { return; }
    if (now.difference(_lastRippleAt) < _kRippleDebounce) { return; }

    _lastRipplePos = fix.position;
    _lastRippleAt  = now;

    final ndt = widget.controller.lastNdtResult;
    final double fPeak;
    if (ndt != null) {
      fPeak = switch (ndt.label) {
        NdtLabel.solid      => 5000.0,
        NdtLabel.voidRegion =>  300.0,
        NdtLabel.unknown    => 1500.0,
      };
    } else {
      fPeak = 300.0 + fix.confidence * 4000.0;
    }

    _rippleEvents.removeWhere((e) => e.isExpired(now));
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
      builder: (_, __) => _buildInner(context),
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
              // ── Canvas ───────────────────────────────────────────────────
              Positioned.fill(
                child: GestureDetector(
                  onScaleStart: (details) {
                    _gestureStartScale = 1.0;
                    _gestureStartFocal = details.localFocalPoint;
                  },
                  onScaleUpdate: (details) {
                    // Two-finger: zoom around focal point.
                    if (details.pointerCount >= 2) {
                      final factor = details.scale / _gestureStartScale;
                      if (factor != 1.0) {
                        camera.scale(factor);
                        _gestureStartScale = details.scale;
                      }
                    }
                    // One or two finger: pan by focal-point delta.
                    camera.pan(
                      details.localFocalPoint.dx - _gestureStartFocal.dx,
                      details.localFocalPoint.dy - _gestureStartFocal.dy,
                    );
                    _gestureStartFocal = details.localFocalPoint;
                  },
                  onTapUp: _waypointPlacementMode ? _onMapTap : null,
                  child: StreamBuilder<void>(
                    stream: widget.controller.onChange,
                    builder: (ctx, _) => AnimatedBuilder(
                      animation: camera,
                      builder: (ctx, _) => LayoutBuilder(
                        builder: (ctx, constraints) {
                          final cx = constraints.maxWidth  / 2;
                          final cy = constraints.maxHeight / 2;

                          return Stack(children: [
                            // Layer: voxel heatmap + nodes.
                            if (settings.layers.heatmap ||
                                settings.layers.nodes)
                              CustomPaint(
                                painter: VoxelMapPainter(
                                  controller:  widget.controller,
                                  camera:      camera,
                                  colors:      c,
                                  showHeatmap: settings.layers.heatmap,
                                  showNodes:   settings.layers.nodes,
                                ),
                                size: Size.infinite,
                              ),

                            // Layer: ripples.
                            if (settings.layers.ripples)
                              CustomPaint(
                                painter: RipplePainter(
                                  events:    _rippleEvents,
                                  palette:   settings.frequencyPalette,
                                  animation: _rippleAnim,
                                  zoom:      camera.zoom,
                                  cx:        cx,
                                  cy:        cy,
                                  panX:      camera.panX,
                                  panY:      camera.panY,
                                ),
                                size: Size.infinite,
                              ),

                            // Layer: waypoint flags.
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
                                  zoom:  camera.zoom,
                                  cx:    cx,
                                  cy:    cy,
                                  panX:  camera.panX,
                                  panY:  camera.panY,
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

              // ── Camera controls (top-right) ───────────────────────────────
              Positioned(
                top: 12, right: 12,
                child: Column(
                  children: [
                    _RoundButton(
                      c:       c,
                      icon:    Icons.refresh,
                      tooltip: 'Reset view',
                      onTap:   () => setState(camera.resetView),
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
                      onTap:   () => setState(
                          () => _waypointPlacementMode =
                              !_waypointPlacementMode),
                      active: _waypointPlacementMode,
                    ),
                  ],
                ),
              ),

              // ── NDT panel (top-left) ──────────────────────────────────────
              Positioned(
                top: 12, left: 12,
                // Constrain width so it never overflows on narrow phones.
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: StreamBuilder<void>(
                    stream: widget.controller.onChange,
                    builder: (ctx, _) {
                      final ndt = widget.controller.lastNdtResult;
                      final q   = widget.controller.activeQuadrant;
                      if (ndt == null) {
                        return const SizedBox.shrink();
                      }
                      return _NdtPanel(result: ndt, quadrant: q, c: c);
                    },
                  ),
                ),
              ),

              // ── Depth-estimate strip (top-centre, below NDT) ─────────────
              Positioned(
                top: 12,
                left: 220,   // clear of the NDT panel
                right: 60,   // clear of the camera buttons
                child: StreamBuilder<void>(
                  stream: widget.controller.onChange,
                  builder: (ctx, _) {
                    final fix = widget.controller.lastFix;
                    if (fix == null) { return const SizedBox.shrink(); }
                    return _DepthEstimateChip(
                      depthM: fix.position.z,
                      c:      c,
                    );
                  },
                ),
              ),

              // ── Placement-mode banner (top, full width) ───────────────────
              if (_waypointPlacementMode)
                Positioned(
                  top: 0, left: 0, right: 0,
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      color:   c.accent.withValues(alpha: 0.85),
                      child: Text(
                        'TAP MAP TO PLACE FLAG',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color:         c.bg,
                          fontSize:      12,
                          fontWeight:    FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
                ),

              // ── Layer chip bar (bottom, scrollable) ───────────────────────
              Positioned(
                left: 0, right: 0, bottom: 8,
                child: Center(
                  child: _LayerChipBar(settings: settings, c: c),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Waypoint placement ──────────────────────────────────────────────────

  void _onMapTap(TapUpDetails details) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) { return; }
    final localPos = renderBox.globalToLocal(details.globalPosition);
    final cx = renderBox.size.width  / 2;
    final cy = renderBox.size.height / 2;

    final worldPos = unprojectFlat(
      localPos,
      zoom: camera.zoom,
      cx:   cx,
      cy:   cy,
      panX: camera.panX,
      panY: camera.panY,
    );

    final idx = widget.settings.waypoints.length + 1;
    widget.settings.addWaypoint(Waypoint(
      id:       'flag_$idx',
      label:    'Flag $idx',
      position: worldPos,
      color:    const Color(0xFFFF5722),
    ));
    setState(() => _waypointPlacementMode = false);
  }
}

// =============================================================================
// Depth-estimate chip
// =============================================================================

/// Shows the solver's z-estimate (depth below sensor plane) from the last fix.
/// This is the only depth information displayed — the map itself is flat 2-D.
class _DepthEstimateChip extends StatelessWidget {
  const _DepthEstimateChip({required this.depthM, required this.c});
  final double    depthM;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    // z convention: positive = deeper underground.
    final label = depthM.abs() < 0.05
        ? 'Depth: surface'
        : depthM > 0
            ? 'Depth: ~${depthM.toStringAsFixed(1)} m below'
            : 'Depth: ~${depthM.abs().toStringAsFixed(1)} m above';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color:        c.panel.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: c.panelBorder),
      ),
      child: Text(
        label,
        maxLines:  1,
        overflow:  TextOverflow.ellipsis,
        style:     TextStyle(color: c.textDim, fontSize: 11),
      ),
    );
  }
}

// =============================================================================
// Layer chip bar  — scrollable single row
// =============================================================================

class _LayerChipBar extends StatelessWidget {
  const _LayerChipBar({required this.settings, required this.c});
  final AppSettings settings;
  final AppColors   c;

  @override
  Widget build(BuildContext context) {
    final layers = [
      ('nodes',    Icons.sensors,               'Nodes'),
      ('ripples',  Icons.radio_button_unchecked, 'Ripples'),
      ('heatmap',  Icons.grid_4x4,              'Heatmap'),
      ('flags',    Icons.flag,                  'Flags'),
      ('guidance', Icons.explore,               'Vectors'),
    ];

    final active = {
      'nodes':    settings.layers.nodes,
      'ripples':  settings.layers.ripples,
      'heatmap':  settings.layers.heatmap,
      'flags':    settings.layers.flags,
      'guidance': settings.layers.guidance,
    };

    return Container(
      // Let the chip bar scroll horizontally on very narrow screens instead
      // of overflowing off the edge.
      constraints: const BoxConstraints(maxWidth: double.infinity),
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
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
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
  final IconData     icon;
  final String       label;
  final bool         enabled;
  final AppColors    c;
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
            color: enabled
                ? c.accent.withValues(alpha: 0.5)
                : Colors.transparent,
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
// Shared button widget
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
            child:   Icon(icon,
                color: active ? c.bg : c.text, size: 20),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// NDT result panel  — constrained for mobile
// =============================================================================

class _NdtPanel extends StatelessWidget {
  const _NdtPanel({
    required this.result,
    required this.quadrant,
    required this.c,
  });
  final NdtResult       result;
  final QuadrantResult? quadrant;
  final AppColors       c;

  @override
  Widget build(BuildContext context) {
    final color = switch (result.label) {
      NdtLabel.solid      => c.green,
      NdtLabel.voidRegion => c.red,
      NdtLabel.unknown    => const Color(0xFF9E9E9E),
    };
    final icon = switch (result.label) {
      NdtLabel.solid      => Icons.check_circle_outline,
      NdtLabel.voidRegion => Icons.cancel_outlined,
      NdtLabel.unknown    => Icons.help_outline,
    };
    final nodeIds =
        quadrant?.nodes.map((n) => n.id.toString()).join(', ') ?? '—';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color:        c.panel.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Title row — icon + label + confidence, all in one line.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 14),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  result.displayLabel,
                  maxLines:  1,
                  overflow:  TextOverflow.ellipsis,
                  style:     TextStyle(
                    color:       color,
                    fontWeight:  FontWeight.bold,
                    fontSize:    12,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${(result.confidence * 100).toStringAsFixed(0)}%',
                style: TextStyle(color: c.textDim, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            'Nodes: $nodeIds',
            maxLines:  1,
            overflow:  TextOverflow.ellipsis,
            style:     TextStyle(color: c.textDim, fontSize: 9),
          ),
          const SizedBox(height: 2),
          _ProbBar('S', result.probabilities[NdtLabel.solid]      ?? 0, c.green,                  c),
          _ProbBar('V', result.probabilities[NdtLabel.voidRegion] ?? 0, c.red,                    c),
          _ProbBar('?', result.probabilities[NdtLabel.unknown]    ?? 0, const Color(0xFF9E9E9E), c),
          if (result.label == NdtLabel.unknown) ...[
            const SizedBox(height: 3),
            Text(
              'Re-test recommended',
              style: TextStyle(
                color:     c.amber,
                fontSize:  9,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
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
            width: 12,
            child: Text(label,
                style: TextStyle(color: c.textDim, fontSize: 9)),
          ),
          const SizedBox(width: 2),
          SizedBox(
            width: 55, height: 5,
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
