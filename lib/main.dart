import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'theme.dart';
import 'ui/connection_bar.dart';
import 'ui/console_screen.dart';
import 'ui/map_screen.dart';
import 'ui/node_list_screen.dart';

void main() {
  runApp(const ASSAA());
}

class ASSAA extends StatelessWidget {
  const ASSAA({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ASSAA',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final AppController controller;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    controller = AppController();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      MapScreen(controller: controller),
      NodeListScreen(controller: controller),
      ConsoleScreen(controller: controller),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('ASSAA', style: TextStyle(letterSpacing: 1.2)),
      ),
      body: Column(
        children: [
          ConnectionBar(controller: controller),
          Expanded(child: screens[_tab]),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: AppColors.panel,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Map'),
          NavigationDestination(icon: Icon(Icons.sensors), label: 'Nodes'),
          NavigationDestination(icon: Icon(Icons.terminal), label: 'Console'),
        ],
      ),
    );
  }
}