import 'package:flutter/material.dart';

import '../models/frequency_band.dart';
import '../models/waypoint.dart';
import '../theme.dart';

// =============================================================================
// Layer visibility flags  (spec §3.1)
// =============================================================================

class LayerVisibility {
  bool nodes    = true;
  bool ripples  = true;
  bool heatmap  = false;
  bool flags    = true;
  bool guidance = true;

  Map<String, bool> toJson() => {
    'nodes':    nodes,
    'ripples':  ripples,
    'heatmap':  heatmap,
    'flags':    flags,
    'guidance': guidance,
  };

  void applyJson(Map<String, dynamic> j) {
    nodes    = j['nodes']    as bool? ?? nodes;
    ripples  = j['ripples']  as bool? ?? ripples;
    heatmap  = j['heatmap']  as bool? ?? heatmap;
    flags    = j['flags']    as bool? ?? flags;
    guidance = j['guidance'] as bool? ?? guidance;
  }
}

// =============================================================================
// AppSettings
// =============================================================================

class AppSettings extends ChangeNotifier {
  AppThemeId themeId = AppThemeId.sonar;
  bool isDark = true;

  AppColors get colors => appColorsFor(themeId, isDark);
  ThemeData get themeData => buildAppTheme(colors, isDark);

  void setTheme(AppThemeId id) { themeId = id; notifyListeners(); }
  void setDarkMode(bool dark)  { isDark  = dark; notifyListeners(); }

  bool showcaseModeEnabled = false;
  void setShowcaseMode(bool e) { showcaseModeEnabled = e; notifyListeners(); }

  final layers = LayerVisibility();

  void toggleLayer(String key) {
    switch (key) {
      case 'nodes':    layers.nodes    = !layers.nodes;    break;
      case 'ripples':  layers.ripples  = !layers.ripples;  break;
      case 'heatmap':  layers.heatmap  = !layers.heatmap;  break;
      case 'flags':    layers.flags    = !layers.flags;    break;
      case 'guidance': layers.guidance = !layers.guidance; break;
    }
    notifyListeners();
  }

  List<FrequencyBand> frequencyPalette =
      List<FrequencyBand>.from(defaultFrequencyPalette);

  void addBand(FrequencyBand b)  { frequencyPalette.add(b); notifyListeners(); }
  void removeBand(String id)     { frequencyPalette.removeWhere((b) => b.id == id); notifyListeners(); }
  void resetPalette()            { frequencyPalette = List.from(defaultFrequencyPalette); notifyListeners(); }

  void updateBand(String id, FrequencyBand updated) {
    final idx = frequencyPalette.indexWhere((b) => b.id == id);
    if (idx >= 0) { frequencyPalette[idx] = updated; }
    notifyListeners();
  }

  Color colorForFrequency(double hz) => rippleColorForFrequency(hz, frequencyPalette);

  final List<Waypoint> waypoints = [];

  void addWaypoint(Waypoint wp)   { waypoints.add(wp); notifyListeners(); }
  void removeWaypoint(String id)  { waypoints.removeWhere((w) => w.id == id); notifyListeners(); }

  void updateWaypoint(String id, void Function(Waypoint) mutate) {
    final wp = waypoints.firstWhere((w) => w.id == id,
        orElse: () => throw StateError('Waypoint $id not found'));
    mutate(wp);
    notifyListeners();
  }

  void setNavTarget(String? id) {
    for (final wp in waypoints) { wp.isNavTarget = (wp.id == id); }
    notifyListeners();
  }

  Waypoint? get activeNavTarget =>
      waypoints.where((w) => w.isNavTarget).cast<Waypoint?>().firstOrNull;

  Map<String, dynamic> toJson() => {
    'system_config': {
      'showcase_mode_enabled': showcaseModeEnabled,
      'theme_id': themeId.name,
      'is_dark':  isDark,
    },
    'triangulation_settings': {
      'frequency_color_palette': frequencyPalette.map((b) => b.toJson()).toList(),
    },
    'map_settings': {
      'visible_layers': layers.toJson(),
      'waypoints':      waypoints.map((w) => w.toJson()).toList(),
    },
  };

  void applyJson(Map<String, dynamic> j) {
    final sys = j['system_config'] as Map<String, dynamic>? ?? {};
    showcaseModeEnabled = sys['showcase_mode_enabled'] as bool? ?? false;
    isDark = sys['is_dark'] as bool? ?? true;
    themeId = AppThemeId.values.firstWhere(
        (e) => e.name == (sys['theme_id'] as String? ?? 'sonar'),
        orElse: () => AppThemeId.sonar);

    final palette = ((j['triangulation_settings']
            as Map<String, dynamic>?)?['frequency_color_palette']) as List?;
    if (palette != null) {
      frequencyPalette = palette
          .map((e) => FrequencyBand.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    final map = j['map_settings'] as Map<String, dynamic>? ?? {};
    final lj  = map['visible_layers'] as Map<String, dynamic>?;
    if (lj != null) { layers.applyJson(lj); }

    final wjs = map['waypoints'] as List?;
    if (wjs != null) {
      waypoints
        ..clear()
        ..addAll(wjs.map((w) => Waypoint.fromJson(w as Map<String, dynamic>)));
    }
    notifyListeners();
  }
}
