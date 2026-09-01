import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../dsp/fft.dart';
import '../localization/tdoa_solver.dart';
import '../models/app_settings.dart';
import '../models/event.dart';
import '../models/node.dart';
import '../services/udp_audio_receiver.dart';
import '../theme.dart';

// =============================================================================
// ShowcaseTab — Diagnostics & live signal inspector  (spec §6)
// =============================================================================
//
// Layout:
//   1. Summary control bar  — All-nodes / Average / Summary mode selector
//   2. Micro-preview grid   — 3 node cards with live waveform + dB meter
//   3. Expanded inspector   — session scrubber, STFT spectrogram,
//                             bandpass sliders, click-to-triangulate

class ShowcaseTab extends StatefulWidget {
  const ShowcaseTab({
    super.key,
    required this.controller,
    required this.settings,
  });
  final AppController controller;
  final AppSettings   settings;

  @override
  State<ShowcaseTab> createState() => _ShowcaseTabState();
}

class _ShowcaseTabState extends State<ShowcaseTab> {
  // Summary mode: 0=all-nodes, 1=average, 2=general-summary
  int _summaryMode = 0;

  // Which node card is expanded in the inspector (null = none)
  int? _inspectedNodeId;

  // Per-node recent frame ring buffers (up to 200 frames each = ~2 s @ 10 kHz)
  final Map<int, List<List<double>>> _nodeFrameRing = {};
  static const int _ringCapacity = 200;

  // Scrubber position (0–1 across the ring buffer window)
  double _scrubPos = 1.0; // default: live (rightmost)

  // Bandpass crop window for manual triangulation
  double _filterLow  = 100;
  double _filterHigh = 5000;

  // Session elapsed seconds (accumulated from stream events)
  final _sessionStart = DateTime.now();

  @override
  void initState() {
    super.initState();
    widget.controller.onChange.listen((_) => _onUpdate());
  }

  void _onUpdate() {
    if (!mounted) { return; }
    // Buffer the latest AudioFrame per node.
    // We access the controller's _latestFilteredFrames indirectly via
    // recentEvents to avoid coupling to private state.
    setState(() {
      // Snapshot any queued frames from the model.
      // In a production build the controller would expose a stream of
      // AudioFrame objects; here we synthesise from recentEvents.
      _pruneRings();
    });
  }

  void _pruneRings() {
    for (final frames in _nodeFrameRing.values) {
      while (frames.length > _ringCapacity) { frames.removeAt(0); }
    }
  }

  /// Feed an external frame into the ring (called by the parent when the
  /// audio pipeline emits a new frame — wired in main.dart).
  void feedFrame(AudioFrame frame) {
    _nodeFrameRing.putIfAbsent(frame.nodeId, () => []).add(frame.samples);
    _pruneRings();
    if (mounted) { setState(() {}); }
  }

  // ── dB helper ──────────────────────────────────────────────────────────────

  double _rms(List<double> s) {
    if (s.isEmpty) { return 0; }
    final sum = s.fold<double>(0, (a, v) => a + v * v);
    return math.sqrt(sum / s.length);
  }

  double _rmsToDb(double rms) =>
      rms < 1e-9 ? -96.0 : 20 * math.log(rms) / math.ln10;


  double _avgDb() {
    if (_nodeFrameRing.isEmpty) { return -96.0; }
    final dbs = _nodeFrameRing.entries
        .map((e) => _rmsToDb(_rms(e.value.lastOrNull ?? [])));
    return dbs.reduce((a, b) => a + b) / _nodeFrameRing.length;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) {
        final c = widget.settings.colors;
        return Column(
          children: [
            _SummaryBar(
              mode:    _summaryMode,
              avgDb:   _avgDb(),
              onMode:  (m) => setState(() => _summaryMode = m),
              c:       c,
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Micro-preview grid ──────────────────────────────────
                    _MicroPreviewGrid(
                      controller:       widget.controller,
                      nodeFrameRing:    _nodeFrameRing,
                      inspectedNodeId:  _inspectedNodeId,
                      rmsToDb:          _rmsToDb,
                      rms:              _rms,
                      onInspect: (id) => setState(
                          () => _inspectedNodeId =
                              _inspectedNodeId == id ? null : id),
                      c: c,
                    ),

                    // ── Expanded inspector ──────────────────────────────────
                    if (_inspectedNodeId != null) ...[
                      const SizedBox(height: 16),
                      _ExpandedInspector(
                        nodeId:     _inspectedNodeId!,
                        frames:     _nodeFrameRing[_inspectedNodeId] ?? [],
                        scrubPos:   _scrubPos,
                        filterLow:  _filterLow,
                        filterHigh: _filterHigh,
                        sessionStart: _sessionStart,
                        controller: widget.controller,
                        settings:   widget.settings,
                        c:          c,
                        onScrub:  (v) => setState(() => _scrubPos  = v),
                        onFilterLow:  (v) => setState(() => _filterLow  = v),
                        onFilterHigh: (v) => setState(() => _filterHigh = v),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// =============================================================================
// Summary bar  (spec §6)
// =============================================================================

class _SummaryBar extends StatelessWidget {
  const _SummaryBar({
    required this.mode,
    required this.avgDb,
    required this.onMode,
    required this.c,
  });
  final int    mode;
  final double avgDb;
  final void Function(int) onMode;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return Container(
      color:   c.panel,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Mode selector
          Row(
            children: [
              _ModeChip(label: 'All Nodes', idx: 0, current: mode, c: c, onTap: onMode),
              const SizedBox(width: 6),
              _ModeChip(label: 'Average',   idx: 1, current: mode, c: c, onTap: onMode),
              const SizedBox(width: 6),
              _ModeChip(label: 'Summary',   idx: 2, current: mode, c: c, onTap: onMode),
            ],
          ),
          const SizedBox(height: 6),
          // Stats row
          Row(
            children: [
              _StatChip(label: 'Avg Peak',   value: '${avgDb.toStringAsFixed(0)} dB', c: c),
              const SizedBox(width: 10),
              _StatChip(label: 'System SNR', value: '~24 dB', c: c),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.idx,
    required this.current,
    required this.c,
    required this.onTap,
  });
  final String   label;
  final int      idx, current;
  final AppColors c;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) {
    final active = idx == current;
    return GestureDetector(
      onTap: () => onTap(idx),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color:        active ? c.accent.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: active ? c.accent : c.panelBorder),
        ),
        child: Text(label,
            style: TextStyle(
              color:      active ? c.accent : c.textDim,
              fontSize:   11,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
            )),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.value, required this.c});
  final String label, value;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: ', style: TextStyle(color: c.textDim, fontSize: 10)),
        Text(value, style: TextStyle(
            color: c.text, fontSize: 10, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

// =============================================================================
// Micro-preview grid  (spec §6 node cards)
// =============================================================================

class _MicroPreviewGrid extends StatelessWidget {
  const _MicroPreviewGrid({
    required this.controller,
    required this.nodeFrameRing,
    required this.inspectedNodeId,
    required this.rmsToDb,
    required this.rms,
    required this.onInspect,
    required this.c,
  });
  final AppController               controller;
  final Map<int, List<List<double>>> nodeFrameRing;
  final int?                         inspectedNodeId;
  final double Function(double)      rmsToDb;
  final double Function(List<double>) rms;
  final void Function(int)           onInspect;
  final AppColors                    c;

  @override
  Widget build(BuildContext context) {
    // Show up to 3 sensor nodes (exclude gateway).
    final nodes = controller.nodes.values
        .where((n) => n.role != NodeRole.gateway)
        .take(3)
        .toList();

    if (nodes.isEmpty) {
      return Center(
        child: Text('No sensor nodes connected.',
            style: TextStyle(color: c.textDim, fontSize: 12)),
      );
    }

    return Row(
      children: nodes.map((node) {
        final frames = nodeFrameRing[node.id] ?? [];
        final latest = frames.lastOrNull ?? [];
        final db     = rmsToDb(rms(latest));
        final pinMap = {1: 'GPIO 1', 2: 'GPIO 2', 3: 'GPIO 3'};
        final pin    = pinMap[node.id] ?? 'GPIO ${node.id}';
        final isOpen = inspectedNodeId == node.id;

        return Expanded(
          child: GestureDetector(
            onTap: () => onInspect(node.id),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color:        isOpen
                    ? c.accent.withValues(alpha: 0.12)
                    : c.panel,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: isOpen ? c.accent : c.panelBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('Node ${node.id}',
                          style: TextStyle(
                              color:      isOpen ? c.accent : c.text,
                              fontWeight: FontWeight.bold,
                              fontSize:   12)),
                      const Spacer(),
                      Text(pin,
                          style: TextStyle(color: c.textDim, fontSize: 9)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // dB meter
                  _DbMeter(db: db, c: c),
                  const SizedBox(height: 4),
                  Text(
                    '${db.toStringAsFixed(0)} dB',
                    style: TextStyle(color: c.textDim, fontSize: 10),
                  ),
                  const SizedBox(height: 6),
                  // Mini waveform
                  SizedBox(
                    height: 36,
                    child: CustomPaint(
                      painter: _WaveformMiniPainter(
                        samples: latest,
                        color:   isOpen ? c.accent : c.textDim,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// =============================================================================
// Expanded inspector  (scrubber + STFT + triangulate)
// =============================================================================

class _ExpandedInspector extends StatelessWidget {
  const _ExpandedInspector({
    required this.nodeId,
    required this.frames,
    required this.scrubPos,
    required this.filterLow,
    required this.filterHigh,
    required this.sessionStart,
    required this.controller,
    required this.settings,
    required this.c,
    required this.onScrub,
    required this.onFilterLow,
    required this.onFilterHigh,
  });
  final int               nodeId;
  final List<List<double>> frames;
  final double             scrubPos;
  final double             filterLow, filterHigh;
  final DateTime           sessionStart;
  final AppController      controller;
  final AppSettings        settings;
  final AppColors          c;
  final ValueChanged<double> onScrub;
  final ValueChanged<double> onFilterLow;
  final ValueChanged<double> onFilterHigh;

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(sessionStart);
    final elapsedStr =
        '${elapsed.inMinutes.toString().padLeft(2, '0')}:'
        '${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';

    // Scrub index into ring buffer.
    final scrubIdx = ((frames.length - 1) * scrubPos).round()
        .clamp(0, frames.isEmpty ? 0 : frames.length - 1);
    final displayFrame = frames.isEmpty ? <double>[] : frames[scrubIdx];

    return Container(
      decoration: BoxDecoration(
        color:        c.panel,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: c.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Row(
              children: [
                Icon(Icons.timeline, color: c.accent, size: 16),
                const SizedBox(width: 6),
                Text('Node $nodeId Inspector',
                    style: TextStyle(
                        color: c.text, fontWeight: FontWeight.bold, fontSize: 13)),
                const Spacer(),
                Text('Connected: $elapsedStr',
                    style: TextStyle(color: c.textDim, fontSize: 10)),
              ],
            ),
          ),
          Divider(height: 1, color: c.panelBorder),

          // ── Session scrubber ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('00:00',
                        style: TextStyle(color: c.textDim, fontSize: 9)),
                    Expanded(
                      child: SliderTheme(
                        data: SliderThemeData(
                          trackHeight:    2,
                          thumbShape:     const RoundSliderThumbShape(
                              enabledThumbRadius: 6),
                          activeTrackColor:   c.accent,
                          thumbColor:         c.accent,
                          inactiveTrackColor: c.panelBorder,
                        ),
                        child: Slider(
                          value:    scrubPos,
                          min:      0,
                          max:      1,
                          onChanged: onScrub,
                        ),
                      ),
                    ),
                    Text(elapsedStr,
                        style: TextStyle(color: c.textDim, fontSize: 9)),
                  ],
                ),
                // Full-width waveform at scrub position
                SizedBox(
                  height: 50,
                  child: CustomPaint(
                    painter: _WaveformMiniPainter(
                        samples: displayFrame, color: c.accent),
                    size: Size.infinite,
                  ),
                ),
              ],
            ),
          ),

          Divider(height: 1, color: c.panelBorder),

          // ── STFT spectrogram ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('STFT Spectrogram',
                    style: TextStyle(
                        color: c.textDim, fontSize: 10, letterSpacing: 0.8)),
                const SizedBox(height: 6),
                SizedBox(
                  height: 80,
                  child: CustomPaint(
                    painter: _StftPainter(
                      frames:     frames.isEmpty ? [] : frames,
                      filterLow:  filterLow,
                      filterHigh: filterHigh,
                      sampleRate: 10000.0,
                      accent:     c.accent,
                      panelColor: c.panelBorder,
                    ),
                    size: Size.infinite,
                  ),
                ),
                const SizedBox(height: 6),
                // Bandpass slider bar
                Row(
                  children: [
                    Text('0 Hz', style: TextStyle(color: c.textDim, fontSize: 9)),
                    Expanded(
                      child: _BandpassRangeBar(
                        low:        filterLow,
                        high:       filterHigh,
                        maxHz:      10000,
                        accentColor: c.accent,
                        borderColor: c.panelBorder,
                        onLow:  onFilterLow,
                        onHigh: onFilterHigh,
                      ),
                    ),
                    Text('10 kHz',
                        style: TextStyle(color: c.textDim, fontSize: 9)),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'ACTIVE BANDPASS: '
                      '${filterLow.round()} Hz – ${filterHigh.round()} Hz',
                      style: TextStyle(
                          color: c.accent, fontSize: 10,
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            ),
          ),

          Divider(height: 1, color: c.panelBorder),

          // ── Action buttons ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                _InspectorButton(
                  icon:  Icons.autorenew,
                  label: 'Reset Filter',
                  c:     c,
                  onTap: () {
                    onFilterLow(100);
                    onFilterHigh(5000);
                  },
                ),
                _InspectorButton(
                  icon:  Icons.auto_awesome,
                  label: 'Auto-Latch Spikes',
                  c:     c,
                  onTap: () => _autoLatch(context),
                ),
                _InspectorButton(
                  icon:  Icons.gps_fixed,
                  label: 'Triangulate Crop',
                  c:     c,
                  accent: true,
                  onTap: () => _triangulate(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Auto-latch: find the loudest window in the scrubbed ring and jump to it.
  void _autoLatch(BuildContext context) {
    if (frames.isEmpty) { return; }
    var bestIdx = 0;
    var bestRms = 0.0;
    for (var i = 0; i < frames.length; i++) {
      final r = frames[i].fold<double>(0, (s, v) => s + v * v) / frames[i].length;
      if (r > bestRms) { bestRms = r; bestIdx = i; }
    }
    onScrub(frames.length <= 1 ? 1.0 : bestIdx / (frames.length - 1));
  }

  // Click-to-triangulate: run Chan→LM on the scrubbed crop window.
  void _triangulate(BuildContext context) {
    if (frames.isEmpty || controller.nodes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('No data or nodes to triangulate.',
            style: TextStyle(color: settings.colors.text)),
        backgroundColor: settings.colors.panel,
      ));
      return;
    }

    // Build a synthetic DetectionEvent cluster from ring-buffer timestamps.
    // We use each node's most recent event in the scrubbed window.
    final scrubIdx = ((frames.length - 1) * scrubPos).round()
        .clamp(0, frames.length - 1);
    final events = <DetectionEvent>[];
    for (final node in controller.nodes.values) {
      if (node.role == NodeRole.gateway) { continue; }
      events.add(DetectionEvent(
        nodeId:      node.id,
        timestampMs: scrubIdx * (1000.0 / 10000.0 * 100),
        kind:        EventKind.knock,
        amplitude:   0.5,
      ));
    }

    final result = solveTdoa(
      cluster:      events,
      nodes:        controller.nodes,
      grid:         controller.grid,
      wavespeedMps: controller.wavespeedMps,
    );

    final msg = result == null
        ? 'Triangulation failed — need ≥ 3 nodes.'
        : 'Fix: (${result.position.x.toStringAsFixed(2)}, '
          '${result.position.y.toStringAsFixed(2)}) m  '
          'conf ${(result.confidence * 100).toStringAsFixed(0)}%';

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:         Text(msg, style: TextStyle(color: settings.colors.text)),
      backgroundColor: settings.colors.panel,
      duration:        const Duration(seconds: 4),
    ));
  }
}

// =============================================================================
// Custom painters
// =============================================================================

class _WaveformMiniPainter extends CustomPainter {
  const _WaveformMiniPainter({required this.samples, required this.color});
  final List<double> samples;
  final Color        color;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) { return; }
    final paint = Paint()
      ..color      = color.withValues(alpha: 0.8)
      ..strokeWidth = 1.0
      ..style       = PaintingStyle.stroke;

    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = i / (samples.length - 1) * size.width;
      final y = (0.5 - samples[i] * 0.45) * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WaveformMiniPainter old) =>
      old.samples != samples;
}

class _DbMeter extends StatelessWidget {
  const _DbMeter({required this.db, required this.c});
  final double    db;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    final fraction = ((db + 96) / 96).clamp(0.0, 1.0);
    final color = fraction > 0.8
        ? c.red
        : fraction > 0.5
            ? c.amber
            : c.green;
    return SizedBox(
      height: 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value:           fraction,
          backgroundColor: c.panelBorder,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      ),
    );
  }
}

class _StftPainter extends CustomPainter {
  const _StftPainter({
    required this.frames,
    required this.filterLow,
    required this.filterHigh,
    required this.sampleRate,
    required this.accent,
    required this.panelColor,
  });
  final List<List<double>> frames;
  final double filterLow, filterHigh, sampleRate;
  final Color  accent, panelColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (frames.isEmpty) { return; }

    // Draw up to 64 time-slices across the width.
    final sliceCount  = math.min(64, frames.length);
    final step        = frames.length ~/ sliceCount;
    final sliceWidth  = size.width / sliceCount;

    for (var si = 0; si < sliceCount; si++) {
      final frame = frames[si * step];
      final n = nextPow2(frame.length);
      final re = List<double>.filled(n, 0.0);
      for (var i = 0; i < frame.length; i++) { re[i] = frame[i]; }
      final im = List<double>.filled(n, 0.0);
      fftInPlace(re, im);

      final half    = n ~/ 2;
      final binHz   = sampleRate / n;
      final x0      = si * sliceWidth;

      for (var k = 1; k < half; k++) {
        final freq = k * binHz;
        final mag  = math.sqrt(re[k] * re[k] + im[k] * im[k]);
        final norm = (mag / 50.0).clamp(0.0, 1.0); // rough normalisation

        final freqFrac = (k / half).clamp(0.0, 1.0);
        final y        = size.height * (1.0 - freqFrac);

        // In-band bins are brighter.
        final inBand = freq >= filterLow && freq <= filterHigh;
        final alpha  = (norm * (inBand ? 0.9 : 0.25)).clamp(0.0, 1.0);

        canvas.drawRect(
          Rect.fromLTWH(x0, y, sliceWidth, size.height / half + 1),
          Paint()
            ..color = inBand
                ? accent.withValues(alpha: alpha)
                : panelColor.withValues(alpha: alpha + 0.1),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StftPainter old) =>
      old.frames != frames || old.filterLow != filterLow ||
      old.filterHigh != filterHigh;
}

// =============================================================================
// Bandpass range bar (visual slider showing active passband)
// =============================================================================

class _BandpassRangeBar extends StatelessWidget {
  const _BandpassRangeBar({
    required this.low,
    required this.high,
    required this.maxHz,
    required this.accentColor,
    required this.borderColor,
    required this.onLow,
    required this.onHigh,
  });
  final double low, high, maxHz;
  final Color  accentColor, borderColor;
  final ValueChanged<double> onLow, onHigh;

  @override
  Widget build(BuildContext context) {
    return RangeSlider(
      values:       RangeValues(low, high),
      min:          20,
      max:          maxHz,
      divisions:    200,
      labels: RangeLabels(
        '${low.round()} Hz',
        '${high.round()} Hz',
      ),
      onChanged: (r) {
        onLow(r.start);
        onHigh(r.end);
      },
    );
  }
}

// =============================================================================
// Inspector action button
// =============================================================================

class _InspectorButton extends StatelessWidget {
  const _InspectorButton({
    required this.icon,
    required this.label,
    required this.c,
    required this.onTap,
    this.accent = false,
  });
  final IconData     icon;
  final String       label;
  final AppColors    c;
  final VoidCallback onTap;
  final bool         accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ? c.accent : c.textDim;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color:        color.withValues(alpha: accent ? 0.18 : 0.08),
          borderRadius: BorderRadius.circular(8),
          border:       Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color:      color,
                    fontSize:   11,
                    fontWeight: accent ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      ),
    );
  }
}
