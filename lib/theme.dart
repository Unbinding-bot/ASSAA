import 'package:flutter/material.dart';

// =============================================================================
// Theme identifiers
// =============================================================================

enum AppThemeId { sonar, ember, arctic, tactical }

extension AppThemeIdLabel on AppThemeId {
  String get label => switch (this) {
    AppThemeId.sonar    => 'Sonar',
    AppThemeId.ember    => 'Ember',
    AppThemeId.arctic   => 'Arctic',
    AppThemeId.tactical => 'Tactical',
  };
}

// =============================================================================
// Colour token set  — also registered as a ThemeExtension so any widget
// can access it via  Theme.of(context).extension<AppColors>()!
// =============================================================================

class AppColors extends ThemeExtension<AppColors> {
  const AppColors._({
    required this.bg,
    required this.panel,
    required this.panelBorder,
    required this.text,
    required this.textDim,
    required this.accent,
    required this.accentSoft,
    required this.red,
    required this.amber,
    required this.green,
    required this.rippleKnock,
    required this.rippleScream,
    required this.rippleImpact,
  });

  final Color bg;
  final Color panel;
  final Color panelBorder;
  final Color text;
  final Color textDim;
  final Color accent;
  final Color accentSoft;
  final Color red;
  final Color amber;
  final Color green;
  final Color rippleKnock;
  final Color rippleScream;
  final Color rippleImpact;

  // ThemeExtension boilerplate
  @override
  AppColors copyWith({
    Color? bg, Color? panel, Color? panelBorder,
    Color? text, Color? textDim, Color? accent, Color? accentSoft,
    Color? red, Color? amber, Color? green,
    Color? rippleKnock, Color? rippleScream, Color? rippleImpact,
  }) => AppColors._(
    bg:           bg           ?? this.bg,
    panel:        panel        ?? this.panel,
    panelBorder:  panelBorder  ?? this.panelBorder,
    text:         text         ?? this.text,
    textDim:      textDim      ?? this.textDim,
    accent:       accent       ?? this.accent,
    accentSoft:   accentSoft   ?? this.accentSoft,
    red:          red          ?? this.red,
    amber:        amber        ?? this.amber,
    green:        green        ?? this.green,
    rippleKnock:  rippleKnock  ?? this.rippleKnock,
    rippleScream: rippleScream ?? this.rippleScream,
    rippleImpact: rippleImpact ?? this.rippleImpact,
  );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) { return this; }
    return AppColors._(
      bg:           Color.lerp(bg,           other.bg,           t)!,
      panel:        Color.lerp(panel,        other.panel,        t)!,
      panelBorder:  Color.lerp(panelBorder,  other.panelBorder,  t)!,
      text:         Color.lerp(text,         other.text,         t)!,
      textDim:      Color.lerp(textDim,      other.textDim,      t)!,
      accent:       Color.lerp(accent,       other.accent,       t)!,
      accentSoft:   Color.lerp(accentSoft,   other.accentSoft,   t)!,
      red:          Color.lerp(red,          other.red,          t)!,
      amber:        Color.lerp(amber,        other.amber,        t)!,
      green:        Color.lerp(green,        other.green,        t)!,
      rippleKnock:  Color.lerp(rippleKnock,  other.rippleKnock,  t)!,
      rippleScream: Color.lerp(rippleScream, other.rippleScream, t)!,
      rippleImpact: Color.lerp(rippleImpact, other.rippleImpact, t)!,
    );
  }

  /// Convenience: read from the current Flutter theme context.
  /// Falls back to sonarDark if the extension is not present.
  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>() ?? sonarDark;

  // ---------------------------------------------------------------------------
  // Sonar — default dark: deep navy + teal.  Light: off-white + teal.
  // ---------------------------------------------------------------------------
  static const sonarDark = AppColors._(
    bg:           Color(0xFF0B0E10),
    panel:        Color(0xFF12171A),
    panelBorder:  Color(0xFF1F2A2E),
    text:         Color(0xFFDFE6E8),
    textDim:      Color(0xFF7C8B90),
    accent:       Color(0xFF35C9C1),
    accentSoft:   Color(0xFF1E7470),
    red:          Color(0xFFE8483F),
    amber:        Color(0xFFE8A83F),
    green:        Color(0xFF3FBF72),
    rippleKnock:  Color(0xFFFFEB3B),
    rippleScream: Color(0xFF4CAF50),
    rippleImpact: Color(0xFFF44336),
  );
  static const sonarLight = AppColors._(
    bg:           Color(0xFFF0F4F5),
    panel:        Color(0xFFFFFFFF),
    panelBorder:  Color(0xFFCDD8DC),
    text:         Color(0xFF1A2426),
    textDim:      Color(0xFF607880),
    accent:       Color(0xFF0B8C85),
    accentSoft:   Color(0xFFB2E8E6),
    red:          Color(0xFFD32F2F),
    amber:        Color(0xFFF57F17),
    green:        Color(0xFF2E7D32),
    rippleKnock:  Color(0xFFF9A825),
    rippleScream: Color(0xFF388E3C),
    rippleImpact: Color(0xFFC62828),
  );

  // ---------------------------------------------------------------------------
  // Ember — dark: near-black + warm orange.  Light: cream + burnt orange.
  // ---------------------------------------------------------------------------
  static const emberDark = AppColors._(
    bg:           Color(0xFF100C08),
    panel:        Color(0xFF1C1410),
    panelBorder:  Color(0xFF2E2218),
    text:         Color(0xFFEDE0D5),
    textDim:      Color(0xFF8C7060),
    accent:       Color(0xFFFF7043),
    accentSoft:   Color(0xFF7A2E18),
    red:          Color(0xFFEF5350),
    amber:        Color(0xFFFFCA28),
    green:        Color(0xFF66BB6A),
    rippleKnock:  Color(0xFFFFCA28),
    rippleScream: Color(0xFFFF7043),
    rippleImpact: Color(0xFFEF5350),
  );
  static const emberLight = AppColors._(
    bg:           Color(0xFFFFF8F4),
    panel:        Color(0xFFFFFFFF),
    panelBorder:  Color(0xFFE8D5C8),
    text:         Color(0xFF2A1A10),
    textDim:      Color(0xFF8C6050),
    accent:       Color(0xFFBF360C),
    accentSoft:   Color(0xFFFFCCBC),
    red:          Color(0xFFC62828),
    amber:        Color(0xFFF57F17),
    green:        Color(0xFF2E7D32),
    rippleKnock:  Color(0xFFF57F17),
    rippleScream: Color(0xFFBF360C),
    rippleImpact: Color(0xFFC62828),
  );

  // ---------------------------------------------------------------------------
  // Arctic — dark: slate-black + ice blue.  Light: glacial white + blue.
  // ---------------------------------------------------------------------------
  static const arcticDark = AppColors._(
    bg:           Color(0xFF090D12),
    panel:        Color(0xFF101620),
    panelBorder:  Color(0xFF1C2840),
    text:         Color(0xFFD8E8F8),
    textDim:      Color(0xFF5A7090),
    accent:       Color(0xFF40C4FF),
    accentSoft:   Color(0xFF0D5C80),
    red:          Color(0xFFEF5350),
    amber:        Color(0xFFFFD54F),
    green:        Color(0xFF69F0AE),
    rippleKnock:  Color(0xFFFFD54F),
    rippleScream: Color(0xFF69F0AE),
    rippleImpact: Color(0xFFEF5350),
  );
  static const arcticLight = AppColors._(
    bg:           Color(0xFFF2F8FF),
    panel:        Color(0xFFFFFFFF),
    panelBorder:  Color(0xFFBDD6EE),
    text:         Color(0xFF0A1828),
    textDim:      Color(0xFF507090),
    accent:       Color(0xFF0277BD),
    accentSoft:   Color(0xFFB3E5FC),
    red:          Color(0xFFB71C1C),
    amber:        Color(0xFFF57F17),
    green:        Color(0xFF1B5E20),
    rippleKnock:  Color(0xFFF57F17),
    rippleScream: Color(0xFF1B5E20),
    rippleImpact: Color(0xFFB71C1C),
  );

  // ---------------------------------------------------------------------------
  // Tactical — dark: military green-black.  Light: sand + olive.
  // ---------------------------------------------------------------------------
  static const tacticalDark = AppColors._(
    bg:           Color(0xFF0A0D08),
    panel:        Color(0xFF131810),
    panelBorder:  Color(0xFF222E1A),
    text:         Color(0xFFD4DCC8),
    textDim:      Color(0xFF6A7A58),
    accent:       Color(0xFF8BC34A),
    accentSoft:   Color(0xFF3A5C18),
    red:          Color(0xFFFF5252),
    amber:        Color(0xFFFFD740),
    green:        Color(0xFF69F0AE),
    rippleKnock:  Color(0xFFFFD740),
    rippleScream: Color(0xFF8BC34A),
    rippleImpact: Color(0xFFFF5252),
  );
  static const tacticalLight = AppColors._(
    bg:           Color(0xFFF5F0E8),
    panel:        Color(0xFFFFFFFF),
    panelBorder:  Color(0xFFD4C8A8),
    text:         Color(0xFF1A200E),
    textDim:      Color(0xFF6A7050),
    accent:       Color(0xFF558B2F),
    accentSoft:   Color(0xFFDCEDC8),
    red:          Color(0xFFB71C1C),
    amber:        Color(0xFFF57F17),
    green:        Color(0xFF1B5E20),
    rippleKnock:  Color(0xFFF57F17),
    rippleScream: Color(0xFF558B2F),
    rippleImpact: Color(0xFFB71C1C),
  );
}

// =============================================================================
// Lookup helper
// =============================================================================

AppColors appColorsFor(AppThemeId id, bool isDark) => switch (id) {
  AppThemeId.sonar    => isDark ? AppColors.sonarDark    : AppColors.sonarLight,
  AppThemeId.ember    => isDark ? AppColors.emberDark    : AppColors.emberLight,
  AppThemeId.arctic   => isDark ? AppColors.arcticDark   : AppColors.arcticLight,
  AppThemeId.tactical => isDark ? AppColors.tacticalDark : AppColors.tacticalLight,
};

// =============================================================================
// Flutter ThemeData builder
// =============================================================================

ThemeData buildAppTheme(AppColors c, bool isDark) {
  final brightness = isDark ? Brightness.dark : Brightness.light;
  return ThemeData(
    useMaterial3: true,
    brightness:   brightness,
    scaffoldBackgroundColor: c.bg,
    // Register AppColors as a ThemeExtension so ANY widget can read it via
    // AppColors.of(context) without needing it passed as a constructor param.
    extensions: [c],
    colorScheme: ColorScheme(
      brightness:   brightness,
      primary:      c.accent,
      onPrimary:    isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
      secondary:    c.accentSoft,
      onSecondary:  c.text,
      error:        c.red,
      onError:      const Color(0xFFFFFFFF),
      surface:      c.panel,
      onSurface:    c.text,
    ),
    fontFamily: 'monospace',
    appBarTheme: AppBarTheme(
      backgroundColor: c.panel,
      foregroundColor: c.text,
      elevation:       0,
    ),
    cardTheme: CardThemeData(
      color:     c.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: c.panelBorder),
      ),
    ),
    textTheme: TextTheme(
      bodyMedium: TextStyle(color: c.text),
      bodySmall:  TextStyle(color: c.textDim),
      labelSmall: TextStyle(color: c.textDim, fontFamily: 'monospace'),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor:   c.accent,
      thumbColor:         c.accent,
      inactiveTrackColor: c.panelBorder,
      overlayColor:       c.accent.withValues(alpha: 0.15),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.accent : c.textDim),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? c.accent.withValues(alpha: 0.4)
              : c.panelBorder),
    ),
    dividerTheme:    DividerThemeData(color: c.panelBorder, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor:    c.panel,
      indicatorColor:     c.accent.withValues(alpha: 0.18),
      iconTheme: WidgetStateProperty.all(
          IconThemeData(color: c.textDim)),
      labelTextStyle: WidgetStateProperty.all(
          TextStyle(color: c.textDim, fontSize: 11)),
    ),
  );
}

