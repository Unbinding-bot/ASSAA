import 'package:flutter/material.dart';

/// Dark, high-contrast, instrument-panel palette. This is a field tool
/// used at night over rubble, often one-handed -- not a marketing page,
/// so the design goal is glanceability and big touch targets over polish.
class AppColors {
  static const bg = Color(0xFF0B0E10);
  static const panel = Color(0xFF12171A);
  static const panelBorder = Color(0xFF1F2A2E);
  static const text = Color(0xFFDFE6E8);
  static const textDim = Color(0xFF7C8B90);
  static const accent = Color(0xFF35C9C1); // sonar teal
  static const red = Color(0xFFE8483F);
  static const amber = Color(0xFFE8A83F);
  static const green = Color(0xFF3FBF72);
}

ThemeData buildAppTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accent,
      secondary: AppColors.accent,
      surface: AppColors.panel,
    ),
    fontFamily: 'monospace',
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.panel,
      foregroundColor: AppColors.text,
      elevation: 0,
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: AppColors.text),
      bodySmall: TextStyle(color: AppColors.textDim),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: AppColors.accent,
      thumbColor: AppColors.accent,
      inactiveTrackColor: AppColors.panelBorder,
    ),
    useMaterial3: true,
  );
}