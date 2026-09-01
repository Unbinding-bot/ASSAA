import 'dart:async';
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
// ShowcaseTab — live signal diagnostics
// =============================================================================
//
// Modes:
//   0  All Nodes   — card-per-node waveform + dB + expandable inspector
//   1  Average     — single averaged waveform across all nodes
//   2  Summary     — system-level stats: SNR, fix rate, NDT results
//
// Audio frames are fed directly from AppController.audioFrames so the ring
// buffer is always populated while the simulation (or live hardware) is running.

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
  int    _summaryMode     = 0;
  int?   _inspectedNodeId;

  // Per-node ring buffer: up to 300 frames (~3 s @ 10 kHz / 100-sample frames)
  final Map<int, List<List<double>>> _rings = {};
  static const int _ringCap = 300;

  double _scrubPos    = 1.0;
  double _filterLow   = 100;
  double _filterHigh  = 5000;

  final _sessionStart = DateTime.now();
  StreamSubscription<AudioFrame>? _frameSub;

  // For Summary mode: track fix count and NDT label history
  int _fixCount  = 0;
  int _solidCount = 0, _voidCount = 0, _unknownCount = 0;
  StreamSubscription<void>? _changeSub;

  @override
  void initState() {
    super.initState();
    _subscribeToController();
  }

  void _subscribeToController() {
    _frameSub?.cancel();
    _changeSub?.cancel();

    // Wire audio frames straight into the ring buffer.
    _frameSub = widget.controller.audioFrames.listen((frame) {
      if (!mounted) { return; }
      final ring = _rings.putIfAbsent(frame.nodeId, () => []);
      ring.add(List<double>.from(frame.samples));
      while (ring.length > _ringCap) { ring.removeAt(0); }
      // Only rebuild if the user is on a tab that cares about live waveforms.
      if (_summaryMode != 2) { setState(() {}); }
    });

    // Track fix / NDT counts for Summary mode.
    _changeSub = widget.controller.onChange.listen((_) {
      if (!mounted) { return; }
      final ndt = widget.controller.lastNdtResult;
      if (ndt != null) {
        setState(() {
          _fixCount++;
          switch (ndt.label) {
            case NdtLabel.solid:      _solidCount++;   break;
            case NdtLabel.voidRegion: _voidCount++;    break;
            case NdtLabel.unknown:    _unknownCount++; break;
          }
        });
      }
    });
  }

  @override
  void didUpdateWidget(ShowcaseTab old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      _subscribeToController();
    }
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    _changeSub?.cancel();
    super.dispose();
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  double _rms(List<double> s) {
    if (s.isEmpty) { return 0; }
    return math.sqrt(s.fold<double>(0, (a, v) => a + v * v) / s.length);
  }

  double _rmsToDb(double rms) =>
      rms < 1e-9 ? -96.0 : 20 * math.log(rms) / math.ln10;

  double _avgDb() {
    if (_rings.isEmpty) { return -96.0; }
    final dbs = _rings.values
        .map((r) => _rmsToDb(_rms(r.lastOrNull ?? [])));
    return dbs.reduce((a, b) => a + b) / _rings.length;
  }

  /// Averaged waveform across all nodes at the same frame index.
  List<double> _averagedFrame() {
    final active = _rings.values
        .where((r) => r.isNotEmpty)
        .toList();
    if (active.isEmpty) { return []; }
    final len = active.first.last.length;
    if (len == 0) { return []; }
    final out = List<double>.filled(len, 0.0);
    for (final ring in active) {
      final frame = ring.last;
      for (var i = 0; i < math.min(len, frame.length); i++) {
        out[i] += frame[i];
      }
    }
    for (var i = 0; i < len; i++) { out[i] /= active.length; }
    return out;
  }

  List<SensorNode> get _sensorNodes => widget.controller.nodes.values
      .where((n) => n.role != NodeRole.gateway)
      .toList()
      ..sort((a, b) => a.id.compareTo(b.id));

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (_, __) {
        final c = widget.settings.colors;
        return Column(
          children: [
            _SummaryBar(
              mode:   _summaryMode,
              avgDb:  _avgDb(),
              onMode: (m) => setState(() => _summaryMode = m),
              c:      c,
            ),
            const Divider(height: 1),
            Expanded(child: _buildBody(c)),
          ],
        );
      },
    );
  }

  Widget _buildBody(AppColors c) {
    switch (_summaryMode) {
      case 1: return _buildAverageView(c);
      case 2: return _buildSummaryView(c);
      default: return _buildAllNodesView(c);
    }
  }

  // ── Mode 0: All Nodes ──────────────────────────────────────────────────────

  Widget _buildAllNodesView(AppColors c) {
    final nodes = _sensorNodes;
    if (nodes.isEmpty) {
      return Center(
        child: Text(
          'No sensor nodes.\nStart the simulation or connect hardware.',
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textDim, fontSize: 13),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Node cards in a wrap so they reflow on narrow screens.
          _NodeCardGrid(
            nodes:          nodes,
            rings:          _rings,
            inspectedId:    _inspectedNodeId,
            rms:            _rms,
            rmsToDb:        _rmsToDb,
            onInspect: (id) => setState(
                () => _inspectedNodeId = _inspectedNodeId == id ? null : id),
            c: c,
          ),

          // Expanded inspector for the tapped node.
          if (_inspectedNodeId != null) ...[
            const SizedBox(height: 16),
            _ExpandedInspector(
              nodeId:      _inspectedNodeId!,
              frames:      _rings[_inspectedNodeId] ?? [],
              scrubPos:    _scrubPos,
              filterLow:   _filterLow,
              filterHigh:  _filterHigh,
              sessionStart: _sessionStart,
              controller:  widget.controller,
              settings:    widget.settings,
              c:           c,
              onScrub:     (v) => setState(() => _scrubPos    = v),
              onFilterLow: (v) => setState(() => _filterLow  = v),
              onFilterHigh:(v) => setState(() => _filterHigh = v),
            ),
          ],
        ],
      ),
    );
  }

  // ── Mode 1: Average ────────────────────────────────────────────────────────

  Widget _buildAverageView(AppColors c) {
    final avgFrame = _averagedFrame();
    final db       = _rmsToDb(_rms(avgFrame));
    final fraction = ((db + 96) / 96).clamp(0.0, 1.0);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Averaged Signal — ${_rings.length} node(s)',
              style: TextStyle(
                  color: c.text, fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 12),

          // dB bar
          _LabelledRow(
            label: 'Level',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 6,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: fraction,
                      backgroundColor: c.panelBorder,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        fraction > 0.8 ? c.red
                            : fraction > 0.5 ? c.amber
                            : c.green,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text('${db.toStringAsFixed(1)} dBFS',
                    style: TextStyle(color: c.textDim, fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Averaged waveform
          _LabelledRow(
            label: 'Waveform',
            child: SizedBox(
              height: 80,
              child: CustomPaint(
                painter: _WaveformMiniPainter(
                    samples: avgFrame, color: c.accent),
                size: Size.infinite,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // STFT of averaged frame
          _LabelledRow(
            label: 'Spectrogram',
            child: SizedBox(
              height: 100,
              child: CustomPaint(
                painter: _StftPainter(
                  frames:     avgFrame.isEmpty ? [] : [avgFrame],
                  filterLow:  _filterLow,
                  filterHigh: _filterHigh,
                  sampleRate: 10000.0,
                  accent:     c.accent,
                  panelColor: c.panelBorder,
                ),
                size: Size.infinite,
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Per-node dB overview
          const SizedBox(height: 8),
          Text('Per-node levels',
              style: TextStyle(
                  color: c.textDim, fontSize: 10, letterSpacing: 0.8)),
          const SizedBox(height: 6),
          ..._sensorNodes.map((n) {
            final r   = _rings[n.id] ?? [];
            final nDb = _rmsToDb(_rms(r.lastOrNull ?? []));
            final f   = ((nDb + 96) / 96).clamp(0.0, 1.0);
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 52,
                    child: Text('Node ${n.id}',
                        style:
                            TextStyle(color: c.textDim, fontSize: 10)),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: f,
                        minHeight: 6,
                        backgroundColor: c.panelBorder,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          f > 0.8 ? c.red
                              : f > 0.5 ? c.amber
                              : c.green,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 44,
                    child: Text('${nDb.toStringAsFixed(0)} dB',
                        style:
                            TextStyle(color: c.textDim, fontSize: 10)),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── Mode 2: Summary ────────────────────────────────────────────────────────

  Widget _buildSummaryView(AppColors c) {
    final fix       = widget.controller.lastFix;
    final ndt       = widget.controller.lastNdtResult;
    final nodes     = widget.controller.nodes;
    final sensorCnt = nodes.values
        .where((n) => n.role != NodeRole.gateway).length;
    final staleCnt  = nodes.values
        .where((n) => n.role != NodeRole.gateway && n.isStale).length;
    final elapsed   = DateTime.now().difference(_sessionStart);
    final elapsedStr =
        '${elapsed.inMinutes.toString().padLeft(2, '0')}:'
        '${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Session header ──────────────────────────────────────────────
          _SummaryCard(
            title: 'Session',
            c: c,
            children: [
              _SummaryRow('Duration',  elapsedStr, c),
              _SummaryRow('Nodes',
                  '$sensorCnt active / $staleCnt stale', c),
              _SummaryRow('Fix count', '$_fixCount', c),
            ],
          ),
          const SizedBox(height: 12),

          // ── Current fix ────────────────────────────────────────────────
          _SummaryCard(
            title: 'Last TDOA Fix',
            c: c,
            children: fix == null
                ? [_SummaryRow('Status', 'No fix yet', c)]
                : [
                    _SummaryRow('Position',
                        '(${fix.position.x.toStringAsFixed(2)}, '
                        '${fix.position.y.toStringAsFixed(2)}) m', c),
                    _SummaryRow('Confidence',
                        '${(fix.confidence * 100).toStringAsFixed(0)}%', c),
                    _SummaryRow('Residual',
                        '${fix.residualMs.toStringAsFixed(2)} ms', c),
                  ],
          ),
          const SizedBox(height: 12),

          // ── NDT results ─────────────────────────────────────────────────
          _SummaryCard(
            title: 'NDT Results (this session)',
            c: c,
            children: [
              _SummaryRow('Solid',   '$_solidCount', c,
                  valueColor: c.green),
              _SummaryRow('Void',    '$_voidCount',  c,
                  valueColor: c.red),
              _SummaryRow('Unknown', '$_unknownCount', c),
              if (ndt != null)
                _SummaryRow('Last label',
                    '${ndt.displayLabel} '
                    '(${(ndt.confidence * 100).toStringAsFixed(0)}%)',
                    c),
            ],
          ),
          const SizedBox(height: 12),

          // ── Per-node health ─────────────────────────────────────────────
          _SummaryCard(
            title: 'Node Health',
            c: c,
            children: _sensorNodes.map((n) {
              final icon = n.isStale
                  ? Icon(Icons.circle, color: c.textDim, size: 8)
                  : Icon(Icons.circle, color: c.green,   size: 8);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    icon,
                    const SizedBox(width: 8),
                    Text('Node ${n.id}',
                        style: TextStyle(color: c.text, fontSize: 11)),
                    const Spacer(),
                    Text('${n.battery}%  ${n.rssi} dBm',
                        style:
                            TextStyle(color: c.textDim, fontSize: 11)),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Summary bar
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
          Row(
            children: [
              _StatChip(label: 'Avg',
                  value: '${avgDb.toStringAsFixed(0)} dB', c: c),
              const SizedBox(width: 10),
              _StatChip(label: 'SNR', value: '~24 dB', c: c),
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
          color:        active
              ? c.accent.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(color: active ? c.accent : c.panelBorder),
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
        Text(value,
            style: TextStyle(
                color:      c.text,
                fontSize:   10,
                fontWeight: FontWeight.bold)),
      ],
    );
  }
}

// =============================================================================
// Node card grid  (all sensor nodes, wrapping layout)
// =============================================================================

class _NodeCardGrid extends StatelessWidget {
  const _NodeCardGrid({
    required this.nodes,
    required this.rings,
    required this.inspectedId,
    required this.rms,
    required this.rmsToDb,
    required this.onInspect,
    required this.c,
  });
  final List<SensorNode>              nodes;
  final Map<int, List<List<double>>>  rings;
  final int?                          inspectedId;
  final double Function(List<double>) rms;
  final double Function(double)       rmsToDb;
  final void Function(int)            onInspect;
  final AppColors                     c;

  @override
  Widget build(BuildContext context) {
    // Two cards per row, wrapping. Each card gets equal width.
    return LayoutBuilder(
      builder: (_, constraints) {
        const spacing = 8.0;
        final cardW = (constraints.maxWidth - spacing) / 2;
        return Wrap(
          spacing:     spacing,
          runSpacing:  spacing,
          children: nodes.map((node) {
            final ring   = rings[node.id] ?? [];
            final latest = ring.lastOrNull ?? [];
            final db     = rmsToDb(rms(latest));
            final isOpen = inspectedId == node.id;

            return SizedBox(
              width: cardW,
              child: GestureDetector(
                onTap: () => onInspect(node.id),
                child: Container(
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
                      Row(children: [
                        Text('Node ${node.id}',
                            style: TextStyle(
                                color:      isOpen ? c.accent : c.text,
                                fontWeight: FontWeight.bold,
                                fontSize:   12)),
                        const Spacer(),
                        Text('GPIO ${node.id}',
                            style: TextStyle(
                                color: c.textDim, fontSize: 9)),
                      ]),
                      const SizedBox(height: 4),
                      _DbMeter(db: db, c: c),
                      const SizedBox(height: 2),
                      Text('${db.toStringAsFixed(0)} dB',
                          style: TextStyle(
                              color: c.textDim, fontSize: 10)),
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 34,
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
      },
    );
  }
}

// =============================================================================
// Expanded inspector
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
  final ValueChanged<double> onScrub, onFilterLow, onFilterHigh;

  @override
  Widget build(BuildContext context) {
    final elapsed    = DateTime.now().difference(sessionStart);
    final elapsedStr =
        '${elapsed.inMinutes.toString().padLeft(2, '0')}:'
        '${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';

    final scrubIdx   = frames.isEmpty ? 0
        : ((frames.length - 1) * scrubPos).round()
            .clamp(0, frames.length - 1);
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
            child: Row(children: [
              Icon(Icons.timeline, color: c.accent, size: 16),
              const SizedBox(width: 6),
              Text('Node $nodeId Inspector',
                  style: TextStyle(
                      color:      c.text,
                      fontWeight: FontWeight.bold,
                      fontSize:   13)),
              const Spacer(),
              Text('$elapsedStr',
                  style: TextStyle(color: c.textDim, fontSize: 10)),
            ]),
          ),
          Divider(height: 1, color: c.panelBorder),

          // Scrubber
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text('00:00',
                      style: TextStyle(color: c.textDim, fontSize: 9)),
                  Expanded(
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackHeight:         2,
                        thumbShape:          const RoundSliderThumbShape(
                            enabledThumbRadius: 6),
                        activeTrackColor:   c.accent,
                        thumbColor:         c.accent,
                        inactiveTrackColor: c.panelBorder,
                      ),
                      child: Slider(
                        value:     scrubPos,
                        min:       0,
                        max:       1,
                        onChanged: onScrub,
                      ),
                    ),
                  ),
                  Text(elapsedStr,
                      style: TextStyle(color: c.textDim, fontSize: 9)),
                ]),
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

          // STFT spectrogram
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('STFT Spectrogram',
                    style: TextStyle(
                        color:         c.textDim,
                        fontSize:      10,
                        letterSpacing: 0.8)),
                const SizedBox(height: 6),
                SizedBox(
                  height: 80,
                  child: CustomPaint(
                    painter: _StftPainter(
                      frames:     frames,
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
                Row(children: [
                  Text('0 Hz',
                      style: TextStyle(color: c.textDim, fontSize: 9)),
                  Expanded(
                    child: RangeSlider(
                      values:    RangeValues(filterLow, filterHigh),
                      min:       20,
                      max:       10000,
                      divisions: 200,
                      labels: RangeLabels(
                        '${filterLow.round()} Hz',
                        '${filterHigh.round()} Hz',
                      ),
                      onChanged: (r) {
                        onFilterLow(r.start);
                        onFilterHigh(r.end);
                      },
                    ),
                  ),
                  Text('10 kHz',
                      style: TextStyle(color: c.textDim, fontSize: 9)),
                ]),
                Center(
                  child: Text(
                    'BANDPASS: ${filterLow.round()} Hz – '
                    '${filterHigh.round()} Hz',
                    style: TextStyle(
                        color:      c.accent,
                        fontSize:   10,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.panelBorder),

          // Action buttons
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                _InspectorButton(
                  icon:  Icons.autorenew,
                  label: 'Reset Filter',
                  c:     c,
                  onTap: () { onFilterLow(100); onFilterHigh(5000); },
                ),
                _InspectorButton(
                  icon:  Icons.auto_awesome,
                  label: 'Auto-Latch',
                  c:     c,
                  onTap: () => _autoLatch(),
                ),
                _InspectorButton(
                  icon:   Icons.gps_fixed,
                  label:  'Triangulate',
                  c:      c,
                  accent: true,
                  onTap:  () => _triangulate(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _autoLatch() {
    if (frames.isEmpty) { return; }
    var best = 0;
    var bestRms = 0.0;
    for (var i = 0; i < frames.length; i++) {
      final r = frames[i].fold<double>(0, (s, v) => s + v * v) /
          frames[i].length;
      if (r > bestRms) { bestRms = r; best = i; }
    }
    onScrub(frames.length <= 1 ? 1.0 : best / (frames.length - 1));
  }

  void _triangulate(BuildContext context) {
    if (frames.isEmpty || controller.nodes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('No data or nodes to triangulate.',
            style: TextStyle(color: settings.colors.text)),
        backgroundColor: settings.colors.panel,
      ));
      return;
    }

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
// Summary helpers
// =============================================================================

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.title,
    required this.children,
    required this.c,
  });
  final String        title;
  final List<Widget>  children;
  final AppColors     c;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        c.panel,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: c.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(),
              style: TextStyle(
                  color:         c.accent,
                  fontSize:      10,
                  letterSpacing: 1.2,
                  fontWeight:    FontWeight.bold)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow(this.label, this.value, this.c, {this.valueColor});
  final String     label, value;
  final AppColors  c;
  final Color?     valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: TextStyle(color: c.textDim, fontSize: 11)),
        ),
        Text(value,
            style: TextStyle(
                color:      valueColor ?? c.text,
                fontSize:   11,
                fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

class _LabelledRow extends StatelessWidget {
  const _LabelledRow({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(),
            style: TextStyle(
                color:         AppColors.of(context).textDim,
                fontSize:      9,
                letterSpacing: 1.0)),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

// =============================================================================
// Painters
// =============================================================================

class _WaveformMiniPainter extends CustomPainter {
  const _WaveformMiniPainter({required this.samples, required this.color});
  final List<double> samples;
  final Color        color;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) { return; }
    final paint = Paint()
      ..color       = color.withValues(alpha: 0.85)
      ..strokeWidth = 1.2
      ..style       = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = i / (samples.length - 1) * size.width;
      final y = (0.5 - samples[i].clamp(-1.0, 1.0) * 0.45) * size.height;
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
    final f = ((db + 96) / 96).clamp(0.0, 1.0);
    return SizedBox(
      height: 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value:           f,
          backgroundColor: c.panelBorder,
          valueColor: AlwaysStoppedAnimation<Color>(
              f > 0.8 ? c.red : f > 0.5 ? c.amber : c.green),
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
    if (frames.isEmpty) {
      // Draw a "no data yet" placeholder so the box isn't just blank.
      final tp = TextPainter(
        text: TextSpan(
          text:  'Waiting for audio frames…',
          style: TextStyle(
              color: panelColor.withValues(alpha: 0.8), fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      tp.paint(canvas, Offset(
          (size.width - tp.width) / 2,
          (size.height - tp.height) / 2));
      return;
    }

    final sliceCount = math.min(64, frames.length);
    final step       = math.max(1, frames.length ~/ sliceCount);
    final sliceW     = size.width / sliceCount;

    for (var si = 0; si < sliceCount; si++) {
      final frame = frames[(si * step).clamp(0, frames.length - 1)];
      if (frame.isEmpty) { continue; }
      final n  = nextPow2(frame.length);
      final re = List<double>.filled(n, 0.0);
      for (var i = 0; i < math.min(frame.length, n); i++) { re[i] = frame[i]; }
      final im = List<double>.filled(n, 0.0);
      fftInPlace(re, im);

      final half  = n ~/ 2;
      final binHz = sampleRate / n;
      final x0    = si * sliceW;

      for (var k = 1; k < half; k++) {
        final freq    = k * binHz;
        final mag     = math.sqrt(re[k] * re[k] + im[k] * im[k]);
        final norm    = (mag / 30.0).clamp(0.0, 1.0);
        final freqFrac = k / half;
        final y        = size.height * (1.0 - freqFrac);
        final inBand   = freq >= filterLow && freq <= filterHigh;
        final alpha    = (norm * (inBand ? 0.9 : 0.22)).clamp(0.0, 1.0);

        canvas.drawRect(
          Rect.fromLTWH(x0, y, sliceW + 0.5, size.height / half + 1),
          Paint()..color = inBand
              ? accent.withValues(alpha: alpha)
              : panelColor.withValues(alpha: alpha + 0.08),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StftPainter old) =>
      old.frames != frames ||
      old.filterLow != filterLow ||
      old.filterHigh != filterHigh;
}

// =============================================================================
// Inspector button
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
                    fontWeight: accent
                        ? FontWeight.bold
                        : FontWeight.normal)),
          ],
        ),
      ),
    );
  }
}
