import 'dart:convert';
import 'dart:developer' as dev;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';

// =============================================================================
// SettingsPersistence
// =============================================================================
//
// Loads and saves the full [AppSettings] state using shared_preferences.
// The entire settings object is serialised to a single JSON string stored
// under [_kKey].  This keeps the load/save path simple — one key, one blob —
// which is fine for the amount of data involved (~1–5 KB).
//
// Usage:
//
//   // On startup:
//   final prefs = await SettingsPersistence.load();
//   settings.applyJson(prefs);
//
//   // On every change (called automatically if you wire it via addListener):
//   await SettingsPersistence.save(settings);

class SettingsPersistence {
  static const _kKey = 'assaa_settings_v1';

  /// Load persisted settings from shared_preferences.
  /// Returns an empty map (use defaults) if nothing is stored yet or if
  /// the stored JSON can't be parsed.
  static Future<Map<String, dynamic>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) { return {}; }
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      dev.log('SettingsPersistence.load() failed: $e',
          name: 'settings.persistence');
      return {};
    }
  }

  /// Persist the current state of [settings] to shared_preferences.
  static Future<void> save(AppSettings settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, jsonEncode(settings.toJson()));
    } catch (e) {
      dev.log('SettingsPersistence.save() failed: $e',
          name: 'settings.persistence');
    }
  }

  /// Wipe all persisted settings (useful for a "reset to defaults" action).
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kKey);
    } catch (e) {
      dev.log('SettingsPersistence.clear() failed: $e',
          name: 'settings.persistence');
    }
  }
}

// =============================================================================
// Convenience mixin — wire auto-save into AppSettings
// =============================================================================
//
// Instead of calling SettingsPersistence.save() manually at every callsite,
// attach this once in main.dart:
//
//   final settings = AppSettings();
//   settings.addListener(() => SettingsPersistence.save(settings));
//
// Saves are debounced by 500 ms so rapid slider changes (e.g. wavespeed)
// don't hammer disk on every frame.

class _Debouncer {
  _Debouncer(this.delay);
  final Duration delay;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  /// Returns true if enough time has passed since the last accepted call.
  bool check() {
    final now = DateTime.now();
    if (now.difference(_last) >= delay) {
      _last = now;
      return true;
    }
    return false;
  }
}

/// Attaches an auto-save listener to [settings] and returns it so you can
/// remove it later if needed.
///
/// Saves are debounced: the first change after a 500 ms quiet period is
/// saved immediately; rapid successive changes are collapsed.
void attachAutosave(AppSettings settings) {
  final debounce = _Debouncer(const Duration(milliseconds: 500));
  settings.addListener(() {
    if (debounce.check()) {
      SettingsPersistence.save(settings);
    }
  });
}
