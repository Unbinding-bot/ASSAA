import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../dsp/iir_filter.dart';
import '../services/data_source.dart';
import '../theme.dart';

class ConnectionBar extends StatefulWidget {
  const ConnectionBar({super.key, required this.controller});
  final AppController controller;

  @override
  State<ConnectionBar> createState() => _ConnectionBarState();
}

class _ConnectionBarState extends State<ConnectionBar> {
  final _hostController = TextEditingController(text: '192.168.4.1');
  bool _expanded = false;

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: widget.controller.onChange,
      builder: (context, _) {
        final _c = AppColors.of(context);
        final mode = widget.controller.mode;
        final connStatus = widget.controller.connectionStatus;
        final statusColor = switch (mode) {
          ConnectionMode.none => _c.textDim,
          ConnectionMode.sim => _c.amber,
          ConnectionMode.live => switch (connStatus) {
              ConnectionStatus.connected => _c.green,
              ConnectionStatus.connecting || ConnectionStatus.reconnecting => _c.amber,
              ConnectionStatus.error || ConnectionStatus.disconnected => _c.red,
            },
        };
        final statusLabel = switch (mode) {
          ConnectionMode.none => 'Disconnected',
          ConnectionMode.sim => 'Simulation running',
          ConnectionMode.live => switch (connStatus) {
              ConnectionStatus.connected => 'Live: connected',
              ConnectionStatus.connecting => 'Live: connecting...',
              ConnectionStatus.reconnecting => 'Live: reconnecting...',
              ConnectionStatus.error => 'Live: connection lost, retrying',
              ConnectionStatus.disconnected => 'Live: disconnected',
            },
        };
        return Material(
          color: _c.panel,
          child: Column(
            children: [
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        mode == ConnectionMode.none ? Icons.circle_outlined : Icons.circle,
                        size: 10,
                        color: statusColor,
                      ),
                      SizedBox(width: 8),
                      Text(
                        statusLabel,
                        style: TextStyle(color: _c.text, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const Spacer(),
                      Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: _c.textDim),
                    ],
                  ),
                ),
              ),
              if (_expanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => widget.controller.connectSim(),
                              child: Text('Sim'),
                            ),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _hostController,
                              style: TextStyle(color: _c.text, fontSize: 13),
                              decoration: InputDecoration(
                                isDense: true,
                                labelText: 'Gateway IP',
                                labelStyle: TextStyle(color: _c.textDim, fontSize: 11),
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () {
                              final uri = Uri.parse('ws://${_hostController.text}/ws');
                              widget.controller.connectLive(uri);
                            },
                            child: Text('Live'),
                          ),
                        ],
                      ),
                      SizedBox(height: 8),
                      if (mode != ConnectionMode.none)
                        TextButton(
                          onPressed: widget.controller.disconnect,
                          child: Text('Disconnect'),
                        ),
                      Row(
                        children: [
                          Text('Wavespeed', style: TextStyle(color: _c.textDim, fontSize: 11)),
                          Expanded(
                            child: Slider(
                              min: 100,
                              max: 3500,
                              value: widget.controller.wavespeedMps.clamp(100, 3500).toDouble(),
                              label: '${widget.controller.wavespeedMps.round()} m/s',
                              onChanged: (v) => widget.controller.setWavespeed(v),
                            ),
                          ),
                          Text('${widget.controller.wavespeedMps.round()} m/s',
                              style: TextStyle(color: _c.textDim, fontSize: 11)),
                        ],
                      ),
                      Text(
                        'Propagation speed through rubble is uncertain -- calibrate '
                        'against a known tap distance on your own rig.',
                        style: TextStyle(color: _c.textDim, fontSize: 10),
                      ),
                      SizedBox(height: 10),
                      Row(
                        children: [
                          Text('Tx@1m', style: TextStyle(color: _c.textDim, fontSize: 11)),
                          Expanded(
                            child: Slider(
                              min: -70,
                              max: -20,
                              value: widget.controller.rssiTxPowerAt1m.clamp(-70, -20).toDouble(),
                              label: '${widget.controller.rssiTxPowerAt1m.round()} dBm',
                              onChanged: (v) => widget.controller.setRssiCalibration(txPowerAt1m: v),
                            ),
                          ),
                          Text('${widget.controller.rssiTxPowerAt1m.round()}dBm',
                              style: TextStyle(color: _c.textDim, fontSize: 11)),
                        ],
                      ),
                      Row(
                        children: [
                          Text('Path loss', style: TextStyle(color: _c.textDim, fontSize: 11)),
                          Expanded(
                            child: Slider(
                              min: 2.0,
                              max: 5.0,
                              value: widget.controller.rssiPathLossExponent.clamp(2.0, 5.0).toDouble(),
                              label: widget.controller.rssiPathLossExponent.toStringAsFixed(1),
                              onChanged: (v) => widget.controller.setRssiCalibration(pathLossExponent: v),
                            ),
                          ),
                          Text(widget.controller.rssiPathLossExponent.toStringAsFixed(1),
                              style: TextStyle(color: _c.textDim, fontSize: 11)),
                        ],
                      ),
                      Text(
                        'RSSI calibration for the "you are here" rescuer fix -- '
                        'Tx@1m is the node\'s signal strength at 1m, path loss is '
                        'how fast it fades through debris. Walk a known distance '
                        'and adjust until the dot lines up.',
                        style: TextStyle(color: _c.textDim, fontSize: 10),
                      ),
                      SizedBox(height: 12),
                      // ── Custom operator frequency profile ─────────────────
                      _CustomFilterSection(controller: widget.controller),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// =============================================================================
// Custom Operator Frequency Profile  (spec §3.1 fourth row)
// =============================================================================

class _CustomFilterSection extends StatelessWidget {
  const _CustomFilterSection({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final _c = AppColors.of(context);
    final profile = controller.customFilterProfile;
    final enabled = controller.useCustomFilterBand;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.tune, size: 14, color: _c.accent),
            SizedBox(width: 6),
            Text(
              'Custom Frequency Profile',
              style: TextStyle(
                  color: _c.accent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            Switch(
              value: enabled,
              activeColor: _c.accent,
              onChanged: (v) =>
                  controller.setUseCustomFilterBand(enabled: v),
            ),
          ],
        ),
        Text(
          'When enabled, the custom band competes with knock/vocal/metallic '
          'for best-band selection on every frame.',
          style: TextStyle(color: _c.textDim, fontSize: 10),
        ),
        SizedBox(height: 6),
        // Centre frequency slider
        Row(
          children: [
            SizedBox(
              width: 44,
              child: Text('f₀',
                  style: TextStyle(color: _c.textDim, fontSize: 11)),
            ),
            Expanded(
              child: Slider(
                min: CustomFilterProfile.minF0,
                max: CustomFilterProfile.maxF0,
                divisions: 199,
                value: profile.centerHz
                    .clamp(CustomFilterProfile.minF0, CustomFilterProfile.maxF0),
                label: '${profile.centerHz.round()} Hz',
                onChanged: enabled
                    ? (v) => controller.setCustomFilterProfile(centerHz: v)
                    : null,
              ),
            ),
            SizedBox(
              width: 56,
              child: Text(
                '${profile.centerHz.round()} Hz',
                style: TextStyle(color: _c.textDim, fontSize: 11),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
        // Bandwidth slider
        Row(
          children: [
            SizedBox(
              width: 44,
              child: Text('Δf',
                  style: TextStyle(color: _c.textDim, fontSize: 11)),
            ),
            Expanded(
              child: Slider(
                min: CustomFilterProfile.minBw,
                max: CustomFilterProfile.maxBw,
                divisions: 199,
                value: profile.bandwidthHz
                    .clamp(CustomFilterProfile.minBw, CustomFilterProfile.maxBw),
                label: '${profile.bandwidthHz.round()} Hz',
                onChanged: enabled
                    ? (v) => controller.setCustomFilterProfile(bandwidthHz: v)
                    : null,
              ),
            ),
            SizedBox(
              width: 56,
              child: Text(
                '${profile.bandwidthHz.round()} Hz',
                style: TextStyle(color: _c.textDim, fontSize: 11),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
        // Display effective passband
        Text(
          'Passband: ${(profile.centerHz - profile.bandwidthHz / 2).round()}–'
          '${(profile.centerHz + profile.bandwidthHz / 2).round()} Hz  '
          '(Q = ${(profile.centerHz / profile.bandwidthHz).toStringAsFixed(1)})',
          style: TextStyle(
            color: enabled ? _c.accent : _c.textDim,
            fontSize: 10,
          ),
        ),
        SizedBox(height: 4),
      ],
    );
  }
}
