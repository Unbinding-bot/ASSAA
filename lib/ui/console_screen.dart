import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../theme.dart';

class ConsoleScreen extends StatelessWidget {
  const ConsoleScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return StreamBuilder<void>(
      stream: controller.onChange,
      builder: (context, _) {
        final lines = controller.logLines.toList();
        if (lines.isEmpty) {
          return Center(
            child: Text('No events yet.',
                style: TextStyle(color: c.textDim)),
          );
        }
        return ListView.builder(
          padding:   const EdgeInsets.all(12),
          itemCount: lines.length,
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              lines[i],
              style: TextStyle(
                  color: c.text, fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        );
      },
    );
  }
}
