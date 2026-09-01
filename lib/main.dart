import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'models/app_settings.dart';
import 'services/settings_persistence.dart';
import 'theme.dart';
import 'ui/connection_bar.dart';
import 'ui/console_screen.dart';
import 'ui/flag_panel.dart';
import 'ui/map_screen.dart';
import 'ui/nav_hud_screen.dart';
import 'ui/node_list_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/showcase_tab.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load persisted settings before the first frame so theme/layer state
  // is correct immediately — no flash of the default palette on startup.
  final settings = AppSettings();
  final saved = await SettingsPersistence.load();
  if (saved.isNotEmpty) { settings.applyJson(saved); }

  // Auto-save every change (debounced to 500 ms).
  attachAutosave(settings);

  runApp(ASSAA(settings: settings));
}

class ASSAA extends StatefulWidget {
  const ASSAA({super.key, required this.settings});
  final AppSettings settings;

  @override
  State<ASSAA> createState() => _ASSAAState();
}

class _ASSAAState extends State<ASSAA> {
  // Settings are owned by the root and passed in — already loaded from disk.
  AppSettings get _settings => widget.settings;

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        return MaterialApp(
          title:                    'ASSAA',
          debugShowCheckedModeBanner: false,
          // Theme rebuilds whenever _settings notifies (theme change or
          // dark-mode toggle), which is exactly the right granularity.
          theme:     _settings.themeData,
          darkTheme: _settings.themeData,
          themeMode: ThemeMode.system, // actual brightness from _settings
          routes: {
            '/settings': (_) => SettingsScreen(settings: _settings),
          },
          home: HomeScreen(settings: _settings),
        );
      },
    );
  }
}

// =============================================================================
// HomeScreen
// =============================================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.settings});
  final AppSettings settings;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final AppController _controller;

  // Tab index — adjusted dynamically when showcase tab is enabled/disabled.
  int _tab = 0;

  // Key into the ShowcaseTab so we can feed AudioFrames to it.
  final GlobalKey<_ShowcaseTabWrapperState> _showcaseKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _controller = AppController();

    // When showcase is enabled mid-session, clamp the selected tab.
    widget.settings.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    final maxTab = _tabCount - 1;
    if (_tab > maxTab) {
      setState(() => _tab = maxTab);
    }
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    _controller.dispose();
    super.dispose();
  }

  // ── Tab count depends on showcase mode ────────────────────────────────────
  int get _tabCount => widget.settings.showcaseModeEnabled ? 6 : 5;

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final c = s.colors;

    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final screens = _buildScreens(s, c);

        return Scaffold(
          backgroundColor: c.bg,
          appBar: AppBar(
            backgroundColor: c.panel,
            foregroundColor: c.text,
            elevation:       0,
            title: Text('ASSAA',
                style: TextStyle(
                    color:         c.text,
                    letterSpacing: 1.2,
                    fontWeight:    FontWeight.bold)),
            actions: [
              // Flag sheet shortcut in the app bar.
              IconButton(
                icon:    Icon(Icons.flag_outlined, color: c.textDim),
                tooltip: 'Waypoints',
                onPressed: () => FlagPanel.show(context, s),
              ),
            ],
          ),
          body: Column(
            children: [
              ConnectionBar(controller: _controller),
              Expanded(child: screens[_tab.clamp(0, screens.length - 1)]),
            ],
          ),
          bottomNavigationBar: _buildNavBar(c),
        );
      },
    );
  }

  Widget _buildNavBar(AppColors c) {
    final s = widget.settings;
    final destinations = <NavigationDestination>[
      NavigationDestination(
        icon:         Icon(Icons.map_outlined,    color: c.textDim),
        selectedIcon: Icon(Icons.map,             color: c.accent),
        label: 'Map',
      ),
      NavigationDestination(
        icon:         Icon(Icons.explore_outlined, color: c.textDim),
        selectedIcon: Icon(Icons.explore,          color: c.accent),
        label: 'Navigate',
      ),
      NavigationDestination(
        icon:         Icon(Icons.sensors_outlined, color: c.textDim),
        selectedIcon: Icon(Icons.sensors,          color: c.accent),
        label: 'Nodes',
      ),
      NavigationDestination(
        icon:         Icon(Icons.terminal,         color: c.textDim),
        selectedIcon: Icon(Icons.terminal,         color: c.accent),
        label: 'Console',
      ),
      if (s.showcaseModeEnabled)
        NavigationDestination(
          icon:         Icon(Icons.analytics_outlined, color: c.textDim),
          selectedIcon: Icon(Icons.analytics,          color: c.accent),
          label: 'Showcase',
        ),
      NavigationDestination(
        icon:         Icon(Icons.settings_outlined, color: c.textDim),
        selectedIcon: Icon(Icons.settings,          color: c.accent),
        label: 'Settings',
      ),
    ];

    return NavigationBar(
      backgroundColor:    c.panel,
      indicatorColor:     c.accent.withValues(alpha: 0.18),
      selectedIndex:      _tab.clamp(0, destinations.length - 1),
      onDestinationSelected: (i) => setState(() => _tab = i),
      destinations:       destinations,
      labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
    );
  }

  List<Widget> _buildScreens(AppSettings s, AppColors c) {
    final screens = <Widget>[
      // 0: Map
      MapScreen(controller: _controller, settings: s),
      // 1: Navigate
      NavHudScreen(controller: _controller),
      // 2: Nodes
      NodeListScreen(controller: _controller),
      // 3: Console
      ConsoleScreen(controller: _controller),
    ];

    if (s.showcaseModeEnabled) {
      // 4: Showcase (conditional)
      screens.add(_ShowcaseTabWrapper(
        key:        _showcaseKey,
        controller: _controller,
        settings:   s,
      ));
    }

    // 4 or 5: Settings
    screens.add(SettingsScreen(settings: s));

    return screens;
  }
}

// =============================================================================
// ShowcaseTab wrapper  (provides the feedFrame hook)
// =============================================================================

class _ShowcaseTabWrapper extends StatefulWidget {
  const _ShowcaseTabWrapper({
    super.key,
    required this.controller,
    required this.settings,
  });
  final AppController controller;
  final AppSettings   settings;

  @override
  State<_ShowcaseTabWrapper> createState() => _ShowcaseTabWrapperState();
}

class _ShowcaseTabWrapperState extends State<_ShowcaseTabWrapper> {
  final GlobalKey<State<ShowcaseTab>> _tabKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return ShowcaseTab(
      key:        _tabKey,
      controller: widget.controller,
      settings:   widget.settings,
    );
  }
}
