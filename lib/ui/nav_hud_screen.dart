import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../localization/navigation.dart';
import '../theme.dart';

class NavHudScreen extends StatefulWidget {
  const NavHudScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<NavHudScreen> createState() => _NavHudScreenState();
}

class _NavHudScreenState extends State<NavHudScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return StreamBuilder<void>(
      stream: widget.controller.onChange,
      builder: (context, _) {
        final nav     = widget.controller.navigationVector;
        final fix     = widget.controller.lastFix;
        final rescuer = widget.controller.rescuerFix;
        return Column(
          children: [
            _StatusBar(fix: fix, rescuer: rescuer, nav: nav, c: c),
            Expanded(
              child: nav == null
                  ? _NoFixPlaceholder(
                      hasNodes: widget.controller.nodes.isNotEmpty, c: c)
                  : _BearingDisplay(nav: nav, pulseAnim: _pulseAnim, c: c),
            ),
            _HeadingInput(
              headingRad: widget.controller.userHeadingRad,
              onChanged:  widget.controller.setUserHeading,
              c:          c,
            ),
          ],
        );
      },
    );
  }
}

// =============================================================================
// Status bar
// =============================================================================

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.fix,
    required this.rescuer,
    required this.nav,
    required this.c,
  });
  final dynamic         fix;
  final dynamic         rescuer;
  final NavigationVector? nav;
  final AppColors       c;

  @override
  Widget build(BuildContext context) {
    return Container(
      color:   c.panel,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _Chip(
            label: 'FIX',
            value: fix == null
                ? '—'
                : '${(fix.confidence * 100).toStringAsFixed(0)}%',
            color: fix == null
                ? c.textDim
                : fix.confidence >= 0.6
                    ? c.green
                    : fix.confidence >= 0.3
                        ? c.amber
                        : c.red,
            labelColor: c.textDim,
          ),
          _Chip(
            label: 'RESCUER',
            value: rescuer == null
                ? '—'
                : '±${rescuer.accuracyM.toStringAsFixed(1)}m',
            color:      rescuer == null ? c.textDim : c.accent,
            labelColor: c.textDim,
          ),
          _Chip(
            label: 'DIST',
            value: nav == null
                ? '—'
                : '${nav!.distanceM.toStringAsFixed(1)}m',
            color:      nav == null ? c.textDim : c.text,
            labelColor: c.textDim,
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.value,
    required this.color,
    required this.labelColor,
  });
  final String label, value;
  final Color  color, labelColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: TextStyle(
                color:         labelColor,
                fontSize:      10,
                letterSpacing: 1.1)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                color:      color,
                fontSize:   14,
                fontWeight: FontWeight.bold)),
      ],
    );
  }
}

// =============================================================================
// No-fix placeholder
// =============================================================================

class _NoFixPlaceholder extends StatelessWidget {
  const _NoFixPlaceholder({required this.hasNodes, required this.c});
  final bool      hasNodes;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    final message = hasNodes
        ? 'Waiting for acoustic fix…\n\nStart the simulation or trigger a tap\nto generate events.'
        : 'No nodes connected.\n\nConnect to a gateway or start simulation.';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.explore_off_outlined,
                size: 56, color: c.textDim.withValues(alpha: 0.5)),
            const SizedBox(height: 20),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textDim, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Bearing display
// =============================================================================

class _BearingDisplay extends StatelessWidget {
  const _BearingDisplay({
    required this.nav,
    required this.pulseAnim,
    required this.c,
  });
  final NavigationVector nav;
  final Animation<double> pulseAnim;
  final AppColors         c;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('${nav.distanceM.toStringAsFixed(1)} m',
            style: TextStyle(
                color:       c.text,
                fontSize:    48,
                fontWeight:  FontWeight.w300,
                letterSpacing: 1)),
        Text(nav.cardinalLabel,
            style: TextStyle(color: c.accent, fontSize: 22, letterSpacing: 2)),
        const SizedBox(height: 32),
        AnimatedBuilder(
          animation: pulseAnim,
          builder: (context, _) => SizedBox(
            width: 220, height: 220,
            child: CustomPaint(
              painter: _CompassPainter(
                bearingRad:   nav.relativeBearingRad,
                pulseOpacity: pulseAnim.value,
                accent:       c.accent,
                textDim:      c.textDim,
                panelBorder:  c.panelBorder,
                textColor:    c.text,
              ),
            ),
          ),
        ),
        const SizedBox(height: 28),
        Text('${nav.relativeBearingDeg.toStringAsFixed(1)}°  relative',
            style: TextStyle(color: c.textDim, fontSize: 13)),
        Text('${nav.absoluteBearingDeg.toStringAsFixed(1)}°  from North',
            style: TextStyle(color: c.textDim, fontSize: 13)),
      ],
    );
  }
}

// =============================================================================
// Compass painter — receives colours as constructor params (no context)
// =============================================================================

class _CompassPainter extends CustomPainter {
  const _CompassPainter({
    required this.bearingRad,
    required this.pulseOpacity,
    required this.accent,
    required this.textDim,
    required this.panelBorder,
    required this.textColor,
  });
  final double bearingRad, pulseOpacity;
  final Color  accent, textDim, panelBorder, textColor;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width  / 2;
    final cy = size.height / 2;
    final r  = math.min(cx, cy) - 8;

    canvas.drawCircle(Offset(cx, cy), r,
        Paint()
          ..color       = panelBorder
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    final tickPaint = Paint()
      ..color       = textDim.withValues(alpha: 0.6)
      ..strokeWidth = 1.5;
    for (var i = 0; i < 8; i++) {
      final angle   = i * math.pi / 4 - math.pi / 2;
      final tickLen = i % 2 == 0 ? 10.0 : 6.0;
      canvas.drawLine(
        Offset(cx + (r - tickLen) * math.cos(angle),
               cy + (r - tickLen) * math.sin(angle)),
        Offset(cx + r * math.cos(angle), cy + r * math.sin(angle)),
        tickPaint,
      );
    }

    final tp = TextPainter(
      text: TextSpan(
        text: 'N',
        style: TextStyle(
            color:      textDim.withValues(alpha: 0.7),
            fontSize:   11,
            fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - r + 14));

    canvas.drawCircle(Offset(cx, cy), r * 0.28 * pulseOpacity,
        Paint()
          ..color = accent.withValues(alpha: 0.12 * pulseOpacity)
          ..style = PaintingStyle.fill);

    final arrowAngle = bearingRad - math.pi / 2;
    final arrowLen   = r * 0.68;
    final shaftEnd   = Offset(
      cx + arrowLen * math.cos(arrowAngle),
      cy + arrowLen * math.sin(arrowAngle),
    );

    canvas.drawLine(Offset(cx, cy), shaftEnd,
        Paint()
          ..color       = accent
          ..strokeWidth = 3.5
          ..strokeCap   = StrokeCap.round);

    const headLen  = 18.0;
    const headHalf = 9.0;
    final sideL = Offset(
      shaftEnd.dx + headLen * math.cos(arrowAngle + math.pi) +
          headHalf * math.cos(arrowAngle - math.pi / 2),
      shaftEnd.dy + headLen * math.sin(arrowAngle + math.pi) +
          headHalf * math.sin(arrowAngle - math.pi / 2),
    );
    final sideR = Offset(
      shaftEnd.dx + headLen * math.cos(arrowAngle + math.pi) +
          headHalf * math.cos(arrowAngle + math.pi / 2),
      shaftEnd.dy + headLen * math.sin(arrowAngle + math.pi) +
          headHalf * math.sin(arrowAngle + math.pi / 2),
    );
    canvas.drawPath(
      Path()
        ..moveTo(shaftEnd.dx, shaftEnd.dy)
        ..lineTo(sideL.dx, sideL.dy)
        ..lineTo(sideR.dx, sideR.dy)
        ..close(),
      Paint()..color = accent,
    );

    canvas.drawCircle(Offset(cx, cy), 5, Paint()..color = textColor);
    canvas.drawCircle(Offset(cx, cy), 5,
        Paint()
          ..color       = panelBorder
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant _CompassPainter old) =>
      old.bearingRad != bearingRad || old.pulseOpacity != pulseOpacity;
}

// =============================================================================
// Heading input
// =============================================================================

class _HeadingInput extends StatelessWidget {
  const _HeadingInput({
    required this.headingRad,
    required this.onChanged,
    required this.c,
  });
  final double               headingRad;
  final ValueChanged<double> onChanged;
  final AppColors            c;

  @override
  Widget build(BuildContext context) {
    final deg = headingRad * 180 / math.pi;
    return Container(
      color:   c.panel,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.explore, size: 14, color: c.textDim),
              const SizedBox(width: 6),
              Text('Your heading (from North)',
                  style: TextStyle(color: c.textDim, fontSize: 11)),
              const Spacer(),
              Text('${deg.toStringAsFixed(0)}°',
                  style: TextStyle(
                      color:      c.text,
                      fontSize:   12,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          Slider(
            min:       0,
            max:       360,
            divisions: 360,
            value:     deg.clamp(0, 360).toDouble(),
            label:     '${deg.toStringAsFixed(0)}°',
            onChanged: (v) => onChanged(v * math.pi / 180),
          ),
          Text(
            'Set to your compass bearing until a magnetometer plugin is wired up.',
            style: TextStyle(color: c.textDim, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
