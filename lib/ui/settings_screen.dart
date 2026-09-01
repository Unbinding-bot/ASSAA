import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../models/frequency_band.dart';
import '../theme.dart';

// =============================================================================
// SettingsScreen
// =============================================================================
//
// Sections:
//   1. Appearance   — theme picker (4 themes × light/dark)
//   2. Diagnostics  — showcase mode toggle
//   3. Triangulation DSP — frequency-colour palette editor  (spec §4.1)
//   4. About

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.settings});
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final c = settings.colors;
        return Scaffold(
          backgroundColor: c.bg,
          appBar: AppBar(
            backgroundColor: c.panel,
            foregroundColor: c.text,
            elevation:       0,
            title: Text('Settings',
                style: TextStyle(color: c.text, letterSpacing: 1.1)),
          ),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _sectionHeader('APPEARANCE', c),
              _ThemePicker(settings: settings, c: c),

              _sectionHeader('DIAGNOSTICS', c),
              _ShowcaseToggle(settings: settings, c: c),

              _sectionHeader('TRIANGULATION DSP', c),
              _FrequencyPaletteEditor(settings: settings, c: c),

              _sectionHeader('ABOUT', c),
              _AboutTile(c: c),

              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }

  static Widget _sectionHeader(String label, AppColors c) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(
          label,
          style: TextStyle(
              color:         c.accent,
              fontSize:      10,
              letterSpacing: 1.6,
              fontWeight:    FontWeight.bold),
        ),
      );
}

// =============================================================================
// 1. Theme picker  (spec: "add more themes, each with light/dark, dark default")
// =============================================================================

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.settings, required this.c});
  final AppSettings settings;
  final AppColors   c;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Light / dark toggle
        _SettingsTile(
          c:     c,
          icon:  settings.isDark ? Icons.dark_mode : Icons.light_mode,
          title: 'Colour mode',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Light', style: TextStyle(color: c.textDim, fontSize: 12)),
              Switch(
                value:     settings.isDark,
                onChanged: settings.setDarkMode,
              ),
              Text('Dark', style: TextStyle(color: c.textDim, fontSize: 12)),
            ],
          ),
        ),

        const SizedBox(height: 8),

        // Theme selection grid
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GridView.count(
            crossAxisCount: 2,
            shrinkWrap:     true,
            physics:        const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing:  8,
            childAspectRatio: 2.8,
            children: AppThemeId.values.map((id) {
              final colors  = appColorsFor(id, settings.isDark);
              final selected = settings.themeId == id;
              return GestureDetector(
                onTap: () => settings.setTheme(id),
                child: Container(
                  decoration: BoxDecoration(
                    color:        colors.panel,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected
                          ? colors.accent
                          : colors.panelBorder,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      // Colour swatches
                      _Swatch(colors.accent),
                      const SizedBox(width: 4),
                      _Swatch(colors.red),
                      const SizedBox(width: 4),
                      _Swatch(colors.green),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          id.label,
                          style: TextStyle(
                              color:      selected
                                  ? colors.accent
                                  : colors.text,
                              fontSize:   12,
                              fontWeight: selected
                                  ? FontWeight.bold
                                  : FontWeight.normal),
                        ),
                      ),
                      if (selected)
                        Icon(Icons.check_circle,
                            color: colors.accent, size: 16),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width:  12, height: 12,
        decoration: BoxDecoration(
          color:  color,
          shape:  BoxShape.circle,
        ),
      );
}

// =============================================================================
// 2. Showcase toggle
// =============================================================================

class _ShowcaseToggle extends StatelessWidget {
  const _ShowcaseToggle({required this.settings, required this.c});
  final AppSettings settings;
  final AppColors   c;

  @override
  Widget build(BuildContext context) {
    return _SettingsTile(
      c:    c,
      icon: Icons.monitor_heart_outlined,
      title: 'Showcase & Diagnostics tab',
      subtitle: 'Adds live waveform cards, STFT inspector, and '
                'manual triangulation to the navigation bar.',
      trailing: Switch(
        value:     settings.showcaseModeEnabled,
        onChanged: settings.setShowcaseMode,
      ),
    );
  }
}

// =============================================================================
// 3. Frequency–colour palette editor  (spec §4.1)
// =============================================================================

class _FrequencyPaletteEditor extends StatelessWidget {
  const _FrequencyPaletteEditor({
    required this.settings,
    required this.c,
  });
  final AppSettings settings;
  final AppColors   c;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Band list
        ...settings.frequencyPalette.asMap().entries.map((entry) {
          return _BandTile(
            band:     entry.value,
            settings: settings,
            c:        c,
          );
        }),

        // Action row
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.accent,
                    side:            BorderSide(color: c.accent),
                  ),
                  icon:  const Icon(Icons.add, size: 16),
                  label: const Text('ADD BAND', style: TextStyle(fontSize: 11)),
                  onPressed: () => _addBand(context),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.textDim,
                  side:            BorderSide(color: c.panelBorder),
                ),
                icon:  const Icon(Icons.restore, size: 16),
                label: const Text('REVERT', style: TextStyle(fontSize: 11)),
                onPressed: settings.resetPalette,
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _addBand(BuildContext context) {
    final idx = settings.frequencyPalette.length + 1;
    settings.addBand(FrequencyBand(
      id:    'band_custom_$idx',
      label: 'Custom Band $idx',
      minHz: 200,
      maxHz: 1000,
      color: const Color(0xFF9C27B0),
    ));
  }
}

class _BandTile extends StatelessWidget {
  const _BandTile({
    required this.band,
    required this.settings,
    required this.c,
  });
  final FrequencyBand band;
  final AppSettings   settings;
  final AppColors     c;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color:        c.panel,
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: c.panelBorder),
      ),
      child: Row(
        children: [
          // Colour swatch — tap to pick colour
          GestureDetector(
            onTap: () => _pickColor(context),
            child: Container(
              width:  28, height: 28,
              decoration: BoxDecoration(
                color:        band.color,
                shape:        BoxShape.circle,
                border: Border.all(
                    color: band.color.withValues(alpha: 0.5), width: 2),
              ),
              child: const Icon(Icons.colorize, size: 14, color: Colors.white),
            ),
          ),
          const SizedBox(width: 10),

          // Label + freq range
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(band.label,
                    style: TextStyle(
                        color:      c.text,
                        fontSize:   12,
                        fontWeight: FontWeight.bold)),
                Text(
                  '${band.minHz.round()} Hz – ${band.maxHz.round()} Hz',
                  style: TextStyle(color: c.textDim, fontSize: 10),
                ),
              ],
            ),
          ),

          // Edit button
          IconButton(
            icon:      Icon(Icons.tune, color: c.textDim, size: 18),
            tooltip:   'Edit band',
            onPressed: () => _editBand(context),
          ),

          // Delete button
          IconButton(
            icon:      Icon(Icons.delete_outline, color: c.red, size: 18),
            tooltip:   'Remove band',
            onPressed: () => settings.removeBand(band.id),
          ),
        ],
      ),
    );
  }

  void _pickColor(BuildContext context) {
    // Simple colour palette picker — 12 preset colours.
    const presets = [
      Color(0xFFFFEB3B), Color(0xFFFF9800), Color(0xFFF44336),
      Color(0xFFE91E63), Color(0xFF9C27B0), Color(0xFF673AB7),
      Color(0xFF2196F3), Color(0xFF00BCD4), Color(0xFF4CAF50),
      Color(0xFF8BC34A), Color(0xFF009688), Color(0xFF607D8B),
    ];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.panel,
        title: Text('Pick colour', style: TextStyle(color: c.text)),
        content: Wrap(
          spacing: 8, runSpacing: 8,
          children: presets.map((col) => GestureDetector(
            onTap: () {
              settings.updateBand(band.id, band.copyWith(color: col));
              Navigator.pop(ctx);
            },
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color:  col,
                shape:  BoxShape.circle,
                border: Border.all(
                  color: col == band.color
                      ? Colors.white
                      : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
          )).toList(),
        ),
      ),
    );
  }

  void _editBand(BuildContext context) {
    final labelCtrl = TextEditingController(text: band.label);
    var minHz = band.minHz;
    var maxHz = band.maxHz;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: c.panel,
          title: Text('Edit band', style: TextStyle(color: c.text)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Label
              TextField(
                controller: labelCtrl,
                style:      TextStyle(color: c.text),
                decoration: InputDecoration(
                  labelText:  'Label',
                  labelStyle: TextStyle(color: c.textDim),
                ),
              ),
              const SizedBox(height: 16),
              // Min freq
              Text('Low: ${minHz.round()} Hz',
                  style: TextStyle(color: c.textDim, fontSize: 11)),
              Slider(
                value:    minHz.clamp(20, maxHz - 20),
                min:      20,
                max:      9980,
                onChanged: (v) => setSt(() => minHz = v),
              ),
              // Max freq
              Text('High: ${maxHz.round()} Hz',
                  style: TextStyle(color: c.textDim, fontSize: 11)),
              Slider(
                value:    maxHz.clamp(minHz + 20, 10000),
                min:      40,
                max:      10000,
                onChanged: (v) => setSt(() => maxHz = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: c.textDim)),
            ),
            TextButton(
              onPressed: () {
                settings.updateBand(
                  band.id,
                  band.copyWith(
                    label: labelCtrl.text.trim(),
                    minHz: minHz,
                    maxHz: maxHz,
                  ),
                );
                Navigator.pop(ctx);
              },
              child: Text('Save', style: TextStyle(color: c.accent)),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 4. About tile
// =============================================================================

class _AboutTile extends StatelessWidget {
  const _AboutTile({required this.c});
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return _SettingsTile(
      c:        c,
      icon:     Icons.info_outline,
      title:    'ASSAA',
      subtitle: 'Acoustic Search & Seismic Array Analysis\n'
                'ESP32-C3 + Chan→LM TDOA engine',
    );
  }
}

// =============================================================================
// Shared tile widget
// =============================================================================

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.c,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });
  final AppColors    c;
  final IconData     icon;
  final String       title;
  final String?      subtitle;
  final Widget?      trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      tileColor:   Colors.transparent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading:  Icon(icon, color: c.accent, size: 20),
      title:    Text(title,
          style: TextStyle(color: c.text, fontSize: 13)),
      subtitle: subtitle != null
          ? Text(subtitle!,
              style: TextStyle(color: c.textDim, fontSize: 10))
          : null,
      trailing:  trailing,
    );
  }
}
