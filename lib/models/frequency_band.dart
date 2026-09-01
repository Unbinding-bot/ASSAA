import 'dart:ui';

/// One entry in the user-editable frequency-colour palette.
///
/// Frequency ranges are stored in Hz.  The [color] is the solid colour
/// used when f_peak falls in the centre of this band.  Adjacent bands
/// blend via linear interpolation (see [interpolatedColorFor]).
class FrequencyBand {
  final String id;
  final String label;
  final double minHz;
  final double maxHz;
  final Color color;

  const FrequencyBand({
    required this.id,
    required this.label,
    required this.minHz,
    required this.maxHz,
    required this.color,
  });

  /// Centre frequency of this band.
  double get centerHz => (minHz + maxHz) / 2;

  bool contains(double hz) => hz >= minHz && hz <= maxHz;

  FrequencyBand copyWith({
    String? id,
    String? label,
    double? minHz,
    double? maxHz,
    Color? color,
  }) => FrequencyBand(
    id:    id    ?? this.id,
    label: label ?? this.label,
    minHz: minHz ?? this.minHz,
    maxHz: maxHz ?? this.maxHz,
    color: color ?? this.color,
  );

  Map<String, dynamic> toJson() => {
    'id':    id,
    'label': label,
    'min_freq_hz': minHz,
    'max_freq_hz': maxHz,
    'hex_color':   '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
  };

  factory FrequencyBand.fromJson(Map<String, dynamic> j) {
    final hex = (j['hex_color'] as String).replaceFirst('#', '');
    final argb = hex.length == 6 ? 'FF$hex' : hex;
    return FrequencyBand(
      id:    j['id']    as String,
      label: j['label'] as String,
      minHz: (j['min_freq_hz'] as num).toDouble(),
      maxHz: (j['max_freq_hz'] as num).toDouble(),
      color: Color(int.parse(argb, radix: 16)),
    );
  }
}

// =============================================================================
// Default palette  (spec §3, §4.1)
// =============================================================================

const defaultFrequencyPalette = [
  FrequencyBand(
    id:    'band_knock',
    label: 'Structural Knocking',
    minHz: 100,
    maxHz: 600,
    color: Color(0xFFFFEB3B), // yellow
  ),
  FrequencyBand(
    id:    'band_scream',
    label: 'Distress Scream',
    minHz: 601,
    maxHz: 4500,
    color: Color(0xFF4CAF50), // green
  ),
  FrequencyBand(
    id:    'band_impact',
    label: 'Kinetic Impact',
    minHz: 4501,
    maxHz: 10000,
    color: Color(0xFFF44336), // red
  ),
];

// =============================================================================
// Colour lookup
// =============================================================================

/// Return the interpolated ripple colour for a given peak frequency.
///
/// Algorithm (spec §4.2):
///   1. If f_peak falls within a band, return that band's colour directly.
///   2. If f_peak is between two bands, linearly interpolate between the
///      upper colour of the lower band and the lower colour of the upper band.
///   3. Clamp to the outermost bands' colours beyond the palette range.
Color rippleColorForFrequency(double fPeakHz, List<FrequencyBand> palette) {
  if (palette.isEmpty) { return const Color(0xFF35C9C1); } // fallback accent

  // Sort by minHz so the logic below is order-independent.
  final sorted = [...palette]..sort((a, b) => a.minHz.compareTo(b.minHz));

  // Below lowest band.
  if (fPeakHz <= sorted.first.minHz) { return sorted.first.color; }

  // Above highest band.
  if (fPeakHz >= sorted.last.maxHz) { return sorted.last.color; }

  // Within a band.
  for (final band in sorted) {
    if (band.contains(fPeakHz)) { return band.color; }
  }

  // Between two bands — interpolate.
  for (var i = 0; i < sorted.length - 1; i++) {
    final lo = sorted[i];
    final hi = sorted[i + 1];
    if (fPeakHz > lo.maxHz && fPeakHz < hi.minHz) {
      final t = (fPeakHz - lo.maxHz) / (hi.minHz - lo.maxHz);
      return Color.lerp(lo.color, hi.color, t.clamp(0.0, 1.0))!;
    }
  }

  return sorted.last.color;
}
