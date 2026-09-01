import 'dart:math' as math;

// =============================================================================
// 2nd-order IIR Butterworth bandpass filter
// =============================================================================
//
// Implements the difference equation:
//   y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − a1·y[n-1] − a2·y[n-2]
//
// Coefficients follow the Audio EQ Cookbook (Bristow-Johnson) BPF formulation.
//
// ── Filter presets (spec §3.1) ───────────────────────────────────────────────
//
//   knock:    f0=300 Hz,  Δf=300 Hz   (150–450 Hz)   — structural tapping
//   scream:   f0=3000 Hz, Δf=1600 Hz  (2200–3800 Hz) — vocal distress
//   metallic: f0=7000 Hz, Δf=4000 Hz  (5000–9000 Hz) — tool/rock impacts
//   custom:   f0 and Δf set at runtime via [CustomFilterProfile]
//             (spec §3.1 "Custom Operator Profile": 50–10000 Hz, 20–4000 Hz)

// =============================================================================
// Filter band enum
// =============================================================================

/// Named filter presets plus the runtime-configurable custom profile.
enum FilterBand { knock, scream, metallic, custom }

extension FilterBandParams on FilterBand {
  /// Centre frequency in Hz. Returns 0 for [custom] — use
  /// [CustomFilterProfile] to supply the actual value.
  double get centerHz {
    switch (this) {
      case FilterBand.knock:    return 300;
      case FilterBand.scream:   return 3000;
      case FilterBand.metallic: return 7000;
      case FilterBand.custom:   return 0; // caller-supplied
    }
  }

  /// Bandwidth in Hz. Returns 0 for [custom].
  double get bandwidthHz {
    switch (this) {
      case FilterBand.knock:    return 300;
      case FilterBand.scream:   return 1600;
      case FilterBand.metallic: return 4000;
      case FilterBand.custom:   return 0;
    }
  }

  /// Human-readable display name for the UI.
  String get label {
    switch (this) {
      case FilterBand.knock:    return 'Structural Knock';
      case FilterBand.scream:   return 'Vocal / Distress';
      case FilterBand.metallic: return 'High Impact';
      case FilterBand.custom:   return 'Custom';
    }
  }
}

// =============================================================================
// Custom operator profile (spec §3.1 fourth row)
// =============================================================================

/// Mutable runtime-configurable frequency profile.
/// Shared app-wide — AppController holds one instance and the UI writes to it.
///
/// Valid ranges per spec:
///   f0:  50–10 000 Hz
///   Δf:  20–4 000 Hz
class CustomFilterProfile {
  static const double minF0   =    50;
  static const double maxF0   = 10000;
  static const double minBw   =    20;
  static const double maxBw   =  4000;

  double _centerHz    = 1000;
  double _bandwidthHz =  500;

  double get centerHz    => _centerHz;
  double get bandwidthHz => _bandwidthHz;

  /// Update the profile. Values are clamped to the valid range.
  /// Returns true if the values actually changed (caller can rebuild filter).
  bool update({double? centerHz, double? bandwidthHz}) {
    bool changed = false;
    if (centerHz != null) {
      final v = centerHz.clamp(minF0, maxF0);
      if (v != _centerHz) { _centerHz = v; changed = true; }
    }
    if (bandwidthHz != null) {
      final v = bandwidthHz.clamp(minBw, maxBw);
      if (v != _bandwidthHz) { _bandwidthHz = v; changed = true; }
    }
    return changed;
  }
}

// =============================================================================
// Biquad coefficient struct
// =============================================================================

class _Biquad {
  final double b0, b1, b2, a1, a2;
  const _Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);
}

_Biquad _butterBandpass(double centerHz, double bwHz, double sampleRateHz) {
  final w0    = 2 * math.pi * centerHz / sampleRateHz;
  final q     = centerHz / bwHz;
  final alpha = math.sin(w0) / (2 * q);
  final cosW0 = math.cos(w0);
  final a0    = 1 + alpha;

  return _Biquad(
    alpha / a0,       // b0
    0.0,              // b1
    -alpha / a0,      // b2
    (-2 * cosW0) / a0, // a1 (sign-negated)
    (1 - alpha) / a0,  // a2
  );
}

// =============================================================================
// IirBandpassFilter
// =============================================================================

/// Stateful single-channel biquad filter.
///
/// State persists across [process] / [processBatch] calls so streaming
/// audio can be fed frame-by-frame without boundary artefacts.
class IirBandpassFilter {
  IirBandpassFilter({
    required double centerHz,
    required double bandwidthHz,
    required double sampleRateHz,
  }) : _c = _butterBandpass(centerHz, bandwidthHz, sampleRateHz);

  /// Construct from a named [FilterBand] preset.
  factory IirBandpassFilter.preset(FilterBand band, double sampleRateHz) {
    assert(band != FilterBand.custom,
        'Use IirBandpassFilter.custom() for the custom profile.');
    return IirBandpassFilter(
      centerHz:    band.centerHz,
      bandwidthHz: band.bandwidthHz,
      sampleRateHz: sampleRateHz,
    );
  }

  /// Construct from the [CustomFilterProfile] runtime configuration.
  factory IirBandpassFilter.fromProfile(
      CustomFilterProfile profile, double sampleRateHz) {
    return IirBandpassFilter(
      centerHz:     profile.centerHz,
      bandwidthHz:  profile.bandwidthHz,
      sampleRateHz: sampleRateHz,
    );
  }

  _Biquad _c;

  double _x1 = 0, _x2 = 0;
  double _y1 = 0, _y2 = 0;

  /// Recompute coefficients in place. Call when the custom profile changes.
  /// Resets filter state to avoid a transient burst from stale history.
  void updateCoefficients({
    required double centerHz,
    required double bandwidthHz,
    required double sampleRateHz,
  }) {
    _c = _butterBandpass(centerHz, bandwidthHz, sampleRateHz);
    reset();
  }

  double process(double x) {
    final y = _c.b0 * x + _c.b1 * _x1 + _c.b2 * _x2
            - _c.a1 * _y1 - _c.a2 * _y2;
    _x2 = _x1; _x1 = x;
    _y2 = _y1; _y1 = y;
    return y;
  }

  List<double> processBatch(List<double> samples) {
    final out = List<double>.filled(samples.length, 0.0);
    for (var i = 0; i < samples.length; i++) { out[i] = process(samples[i]); }
    return out;
  }

  void reset() { _x1 = _x2 = _y1 = _y2 = 0; }
}
