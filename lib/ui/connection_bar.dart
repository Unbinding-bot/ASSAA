import 'package:flutter/material.dart';

import '../app_controller.dart';
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
        final mode = widget.controller.mode;
        return Material(
          color: AppColors.panel,
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
                        color: mode == ConnectionMode.none
                            ? AppColors.textDim
                            : (mode == ConnectionMode.sim ? AppColors.amber : AppColors.green),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        switch (mode) {
                          ConnectionMode.none => 'Disconnected',
                          ConnectionMode.sim => 'Simulation running',
                          ConnectionMode.live => 'Live: gateway',
                        },
                        style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const Spacer(),
                      Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: AppColors.textDim),
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
                              child: const Text('Sim'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _hostController,
                              style: const TextStyle(color: AppColors.text, fontSize: 13),
                              decoration: const InputDecoration(
                                isDense: true,
                                labelText: 'Gateway IP',
                                labelStyle: TextStyle(color: AppColors.textDim, fontSize: 11),
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () {
                              final uri = Uri.parse('ws://${_hostController.text}/ws');
                              widget.controller.connectLive(uri);
                            },
                            child: const Text('Live'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (mode != ConnectionMode.none)
                        TextButton(
                          onPressed: widget.controller.disconnect,
                          child: const Text('Disconnect'),
                        ),
                      Row(
                        children: [
                          const Text('Wavespeed', style: TextStyle(color: AppColors.textDim, fontSize: 11)),
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
                              style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
                        ],
                      ),
                      const Text(
                        'Propagation speed through rubble is uncertain -- calibrate '
                        'against a known tap distance on your own rig.',
                        style: TextStyle(color: AppColors.textDim, fontSize: 10),
                      ),
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