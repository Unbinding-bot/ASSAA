import 'dart:math' as math;

import '../dsp/fft.dart';

// =============================================================================
// NDT feature vector  (spec §5.2 — 7-element vector X)
// =============================================================================
//
// X = [Δt,  V,  A_max,  f_dom,  f_cent,  α,  E]ᵀ
//
//   0. Δt     — Time of Flight (ms)
//      First-arrival wavefront latency from T0 to the threshold crossing.
//
//   1. V      — Stress Wave Speed (m/s)
//      V = d / (Δt / 1000), where d is the tapper→listener baseline
//      distance in metres.  Requires the caller to supply [baselineM].
//      Typical ranges: solid concrete ≥ 3000 m/s, void < 2200 m/s.
//
//   2. A_max  — Peak Amplitude (0–1 normalised)
//      Maximum absolute sample value in the capture window.
//      Voids absorb and scatter more energy → lower A_max at listener.
//
//   3. f_dom  — Dominant Frequency (Hz)
//      FFT peak magnitude bin in the post-ToF analysis window.
//      Solid: >2500 Hz.  Void: <1000 Hz (void acts as low-pass filter).
//
//   4. f_cent — Spectral Centroid (Hz)
//      Weighted mean frequency = Σ(k·|X[k]|) / Σ|X[k]|.
//      More sensitive to broad spectral shifts than a single peak bin.
//
//   5. α      — Decay Rate (neper/ms, log decrement of ring-down envelope)
//      Fit to the envelope of the post-arrival waveform.
//      Solid: fast decay (dense, absorbing).  Void: slow decay (resonant).
//
//   6. E      — Signal Energy (dimensionless)
//      E = Σ(aᵢ²) over the capture window.  Normalised by window length
//      so short and long captures are comparable.

/// Full 7-element NDT feature set for one tapper→listener path.
class NdtFeatures {
  /// 0. Time of Flight (ms).
  final double tofMs;

  /// 1. Stress wave speed (m/s). 0 if baseline distance unknown.
  final double waveSpeedMps;

  /// 2. Peak amplitude (0–1 normalised).
  final double peakAmplitude;

  /// 3. Dominant frequency — FFT peak bin (Hz).
  final double fDomHz;

  /// 4. Spectral centroid (Hz).
  final double fCentHz;

  /// 5. Waveform decay rate (neper/ms).  0 if not estimable.
  final double decayRateNpMs;

  /// 6. Signal energy (normalised, dimensionless).
  final double signalEnergy;

  /// ADC sample rate — kept for reference.
  final double sampleRateHz;

  const NdtFeatures({
    required this.tofMs,
    required this.waveSpeedMps,
    required this.peakAmplitude,
    required this.fDomHz,
    required this.fCentHz,
    required this.decayRateNpMs,
    required this.signalEnergy,
    required this.sampleRateHz,
  });

  static const vectorLength = 7;

  /// Feature vector in spec order: [Δt, V, A_max, f_dom, f_cent, α, E].
  List<double> toVector() => [
        tofMs,
        waveSpeedMps,
        peakAmplitude,
        fDomHz,
        fCentHz,
        decayRateNpMs,
        signalEnergy,
      ];

  // Convenience accessor kept for code that still reads echoDeltaMs
  // (the old feature 1).  Returns 0 — callers should migrate to the
  // new 7-element vector.
  double get echoDeltaMs => 0.0;

  // Old fPeakHz alias → fDomHz.
  double get fPeakHz => fDomHz;

  @override
  String toString() =>
      'NdtFeatures(Δt=${tofMs.toStringAsFixed(2)} ms, '
      'V=${waveSpeedMps.toStringAsFixed(0)} m/s, '
      'A=${peakAmplitude.toStringAsFixed(3)}, '
      'f_dom=${fDomHz.toStringAsFixed(0)} Hz, '
      'f_cent=${fCentHz.toStringAsFixed(0)} Hz, '
      'α=${decayRateNpMs.toStringAsFixed(3)} Np/ms, '
      'E=${signalEnergy.toStringAsFixed(4)})';
}

// =============================================================================
// Feature extractor
// =============================================================================

/// Extract the full 7-feature [NdtFeatures] vector from a normalised piezo
/// waveform captured during a tap cycle.
///
/// @param samples         Normalised samples (–1.0 … +1.0).
/// @param sampleRateHz    ADC sample rate (10 000 Hz for the piezo ADC).
/// @param baselineM       Tapper→listener distance in metres.  Required for
///                        stress wave speed V; pass 0 to get V = 0.
/// @param tofThreshold    First-arrival threshold as fraction of peak (0.10).
/// @param postTofWindowMs FFT + decay analysis window length in ms (10 ms).
NdtFeatures extractNdtFeatures(
  List<double> samples,
  double sampleRateHz, {
  double baselineM        = 0.0,
  double tofThreshold     = 0.10,
  double postTofWindowMs  = 10.0,
}) {
  final zero = NdtFeatures(
    tofMs: 0, waveSpeedMps: 0, peakAmplitude: 0,
    fDomHz: 0, fCentHz: 0, decayRateNpMs: 0,
    signalEnergy: 0, sampleRateHz: sampleRateHz,
  );

  if (samples.isEmpty) { return zero; }

  final samplesPerMs = sampleRateHz / 1000.0;

  // ── 2. Peak amplitude ─────────────────────────────────────────────────────
  final peakAmp = samples.map((v) => v.abs()).reduce(math.max);
  if (peakAmp < 1e-9) { return zero; }

  // ── 0. Time of Flight ─────────────────────────────────────────────────────
  final tofThreshAbs = peakAmp * tofThreshold;
  int tofIdx = 0;
  for (var i = 0; i < samples.length; i++) {
    if (samples[i].abs() >= tofThreshAbs) { tofIdx = i; break; }
  }
  final tofMs = tofIdx / samplesPerMs;

  // ── 1. Stress wave speed ──────────────────────────────────────────────────
  final waveSpeedMps = (baselineM > 0.01 && tofMs > 0)
      ? baselineM / (tofMs / 1000.0)
      : 0.0;

  // ── Analysis window: post-ToF samples for FFT + decay ─────────────────────
  final windowSamples = (postTofWindowMs * samplesPerMs)
      .round()
      .clamp(4, samples.length - tofIdx)
      .toInt();
  final windowEnd   = tofIdx + windowSamples;
  final window      = samples.sublist(tofIdx, windowEnd);

  // ── 6. Signal energy ──────────────────────────────────────────────────────
  final energy = window.fold<double>(0.0, (s, v) => s + v * v) / window.length;

  // ── 3 & 4. FFT for f_dom and f_cent ──────────────────────────────────────
  final fftLen = nextPow2(windowSamples);
  final re = List<double>.filled(fftLen, 0.0);
  for (var i = 0; i < windowSamples; i++) {
    // Hann window to reduce spectral leakage.
    final w = 0.5 * (1 - math.cos(2 * math.pi * i / (windowSamples - 1)));
    re[i] = window[i] * w;
  }
  final im = List<double>.filled(fftLen, 0.0);
  fftInPlace(re, im);

  final half    = fftLen ~/ 2;
  final binHz   = sampleRateHz / fftLen;
  var maxMag    = 0.0;
  var maxBin    = 0;
  var magSum    = 0.0;
  var weightedF = 0.0;

  for (var k = 1; k < half; k++) {
    final mag = math.sqrt(re[k] * re[k] + im[k] * im[k]);
    if (mag > maxMag) { maxMag = mag; maxBin = k; }
    magSum    += mag;
    weightedF += k * binHz * mag;
  }
  final fDomHz  = maxBin * binHz;
  final fCentHz = magSum > 1e-9 ? weightedF / magSum : 0.0;

  // ── 5. Decay rate ─────────────────────────────────────────────────────────
  // Estimate the log-decrement of the waveform envelope by fitting a
  // straight line to log(|env|) vs time using least-squares.
  //
  // Envelope extracted by a simple peak-holding follower:
  //   env[i] = max(|samples[i]|, env[i-1] · exp(-1/τ_hold))
  // where τ_hold = 2 sample periods (light smoothing).
  const tauHold = 2.0;
  final tauDecay = math.exp(-1.0 / tauHold);
  final logEnv   = <double>[];
  final tVec     = <double>[];
  var   envVal   = 0.0;

  for (var i = 0; i < window.length; i++) {
    envVal = math.max(window[i].abs(), envVal * tauDecay);
    if (envVal > 1e-6) {
      logEnv.add(math.log(envVal));
      tVec.add(i / samplesPerMs); // time in ms
    }
  }

  double decayRateNpMs = 0.0;
  if (logEnv.length >= 4) {
    // Ordinary least squares on (tVec, logEnv) → slope = −α.
    final n    = logEnv.length.toDouble();
    final tMean = tVec.fold<double>(0, (s, v) => s + v) / n;
    final lMean = logEnv.fold<double>(0, (s, v) => s + v) / n;
    var stt = 0.0, stl = 0.0;
    for (var i = 0; i < logEnv.length; i++) {
      stt += (tVec[i] - tMean) * (tVec[i] - tMean);
      stl += (tVec[i] - tMean) * (logEnv[i] - lMean);
    }
    final slope = stt > 1e-12 ? stl / stt : 0.0;
    // Negate: a decaying signal has a negative slope → positive decay rate.
    decayRateNpMs = (-slope).clamp(0.0, 100.0).toDouble();
  }

  return NdtFeatures(
    tofMs:         tofMs,
    waveSpeedMps:  waveSpeedMps,
    peakAmplitude: peakAmp,
    fDomHz:        fDomHz,
    fCentHz:       fCentHz,
    decayRateNpMs: decayRateNpMs,
    signalEnergy:  energy,
    sampleRateHz:  sampleRateHz,
  );
}

/// Convenience overload for firmware int16 waveform (12-bit ADC × 8 scale).
NdtFeatures extractNdtFeaturesFromInt16(
  List<int> samplesInt16,
  double sampleRateHz, {
  double baselineM       = 0.0,
  double tofThreshold    = 0.10,
  double postTofWindowMs = 10.0,
}) {
  final normalised = samplesInt16.map((s) => s / 32768.0).toList();
  return extractNdtFeatures(
    normalised,
    sampleRateHz,
    baselineM:       baselineM,
    tofThreshold:    tofThreshold,
    postTofWindowMs: postTofWindowMs,
  );
}
