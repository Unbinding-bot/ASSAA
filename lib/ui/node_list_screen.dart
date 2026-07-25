import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/node.dart';
import '../theme.dart';

class NodeListScreen extends StatelessWidget {
  const NodeListScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: controller.onChange,
      builder: (context, _) {
        final nodes = controller.nodes.values.toList()
          ..sort((a, b) => a.id.compareTo(b.id));
        if (nodes.isEmpty) {
          return const Center(
            child: Text('No nodes connected.', style: TextStyle(color: AppColors.textDim)),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: nodes.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) => _NodeTile(node: nodes[i]),
        );
      },
    );
  }
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({required this.node});
  final SensorNode node;

  @override
  Widget build(BuildContext context) {
    final roleLabel = switch (node.role) {
      NodeRole.gateway => 'GATEWAY',
      NodeRole.tapper => 'TAPPER',
      NodeRole.listener => 'LISTENER',
    };
    final roleColor = switch (node.role) {
      NodeRole.gateway => AppColors.accent,
      NodeRole.tapper => AppColors.amber,
      NodeRole.listener => AppColors.text,
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.panelBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: node.isStale ? AppColors.textDim : AppColors.green,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Node ${node.id}',
                        style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8),
                    Text(roleLabel, style: TextStyle(color: roleColor, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'x:${node.position.x.toStringAsFixed(1)} '
                  'y:${node.position.y.toStringAsFixed(1)} '
                  'z:${node.position.z.toStringAsFixed(1)}m',
                  style: const TextStyle(color: AppColors.textDim, fontSize: 11),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                children: [
                  const Icon(Icons.battery_std, size: 14, color: AppColors.textDim),
                  const SizedBox(width: 4),
                  Text('${node.battery}%', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                ],
              ),
              Row(
                children: [
                  const Icon(Icons.signal_cellular_alt, size: 14, color: AppColors.textDim),
                  const SizedBox(width: 4),
                  Text('${node.rssi}dBm', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}