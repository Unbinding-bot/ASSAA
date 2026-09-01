import 'dart:math' as math;

import '../dsp/fft.dart';

// =============================================================================
// NDT feature vector — 26 elements
// =============================================================================
//
// The ONNX model was trained on a 26-feature pandas DataFrame built from:
//
//   23 acoustic / DSP metrics  (indices 0–22)
//    3 one-hot impactor flags  (indices 23–25, from pd.get_dummies on
//                               'impactor_node' ∈ {"Node A","Node B","Node C"})
//
// ── Acoustic / DSP metrics (0–22) ────────────────────────────────────────────
//
//  Per-waveform (7 features, computed once per tapper→listener path):
//   0  tofMs           — Time of Flight (ms), first-arrival crossing
//   1  waveSpeedMps    — V = baseline_m / (tofMs/1000)  (m/s)
//   2  peakAmplitude   — max |sample| in capture window (0–1)
//   3  fDomHz          — FFT dominant frequency (Hz), Hann-windowed
//   4  fCentHz         — Spectral centroid (Hz)
//   5  decayRateNpMs   — Log-decrement decay rate (Np/ms), OLS on envelope
//   6  signalEnergy    — Mean-squared energy over capture window
//
//  FFT band energies (5 features):
//   7  bandLow         — Energy fraction 0–500 Hz
//   8  bandMid         — Energy fraction 500–1500 Hz
//   9  bandHigh        — Energy fraction 1500–4000 Hz
//  10  bandVhf         — Energy fraction 4000–8000 Hz
//  11  bandRatio       — bandLow / (bandHigh + 1e-9)   (void → high ratio)
//
//  Waveform shape (5 features):
//  12  zeroCrossingRate — Zero crossings per ms (normalised by duration)
//  13  rmsAmplitude    — RMS of capture window
//  14  crestFactor     — peakAmplitude / rmsAmplitude
//  15  skewness        — Waveform asymmetry (3rd standardised moment)
//  16  kurtosis        — Peakedness (4th standardised moment)
//
//  Structural / path (3 features):
//  17  baselineM       — Physical tapper→listener distance (m)
//  18  normTof         — tofMs / baselineM  (ms/m, normalised travel time)
//  19  attenuationDb   — 20·log10(peakAmplitude / referenceAmplitude)
//                        where referenceAmplitude = 1.0 (full-scale input)
//
//  Multi-path summary (3 features — averaged across all listener paths
//  for this tap cycle, so each prediction represents the whole quadrant):
//  20  meanWaveSpeed   — Mean V across all paths in the active triangle
//  21  stdWaveSpeed    — Std-dev of V (higher = heterogeneous material)
//  22  meanDecayRate   — Mean α across paths
//
// ── One-hot impactor node (23–25) ────────────────────────────────────────────
//  23  impactorIsNodeA  — 1.0 if tapper == "Node A", else 0.0
//  24  impactorIsNodeB  — 1.0 if tapper == "Node B", else 0.0
//  25  impactorIsNodeC  — 1.0 if tapper == "Node C", else 0.0
//
// Only one of indices 23–25 is 1.0 per prediction.
// Nodes are mapped to A/B/C by their sorted position in the active triangle
// (lowest node ID = Node A, middle = Node B, highest = Node C).

/// One-hot encoding of the impactor node within the active triangle.
enum ImpactorNode { nodeA, nodeB, nodeC }

/// Full 26-element NDT feature vector matching the ONNX model input.
class NdtFeatures {
  // ── Per-path acoustic features (0–6) ───────────────────────────────────────
  final double tofMs;
  final double waveSpeedMps;
  final double peakAmplitude;
  final double fDomHz;
  final double fCentHz;
  final double decayRateNpMs;
  final double signalEnergy;

  // ── Band energies (7–11) ────────────────────────────────────────────────────
  final double bandLow;
  final double bandMid;
  final double bandHigh;
  final double bandVhf;
  final double bandRatio;

  // ── Waveform shape (12–16) ──────────────────────────────────────────────────
  final double zeroCrossingRate;
  final double rmsAmplitude;
  final double crestFactor;
  final double skewness;
  final double kurtosis;

  // ── Structural / path (17–19) ───────────────────────────────────────────────
  final double baselineM;
  final double normTof;
  final double attenuationDb;

  // ── Multi-path triangle summary (20–22) ─────────────────────────────────────
  final double meanWaveSpeed;
  final double stdWaveSpeed;
  final double meanDecayRate;

  // ── One-hot impactor node (23–25) ───────────────────────────────────────────
  final ImpactorNode impactorNode;

  // ── Metadata (not part of feature vector) ───────────────────────────────────
  final double sampleRateHz;

  const NdtFeatures({
    required this.tofMs,
    required this.waveSpeedMps,
    required this.peakAmplitude,
    required this.fDomHz,
    required this.fCentHz,
    required this.decayRateNpMs,
    required this.signalEnergy,
    required this.bandLow,
    required this.bandMid,
    required this.bandHigh,
    required this.bandVhf,
    required this.bandRatio,
    required this.zeroCrossingRate,
    required this.rmsAmplitude,
    required this.crestFactor,
    required this.skewness,
    required this.kurtosis,
    required this.baselineM,
    required this.normTof,
    required this.attenuationDb,
    required this.meanWaveSpeed,
    required this.stdWaveSpeed,
    required this.meanDecayRate,
    required this.impactorNode,
    required this.sampleRateHz,
  });

  static const vectorLength = 26;

  /// Returns the 26-element Float32 list in the exact training column order.
  ///
  /// Indices 23–25 are the one-hot impactor flags:
  ///   [impactor_node_Node A, impactor_node_Node B, impactor_node_Node C]
  List<double> toVector() => [
        // 0–6  acoustic / DSP
        tofMs,
        waveSpeedMps,
        peakAmplitude,
        fDomHz,
        fCentHz,
        decayRateNpMs,
        signalEnergy,
        // 7–11 band energies
        bandLow,
        bandMid,
        bandHigh,
        bandVhf,
        bandRatio,
        // 12–16 waveform shape
        zeroCrossingRate,
        rmsAmplitude,
        crestFactor,
        skewness,
        kurtosis,
        // 17–19 structural
        baselineM,
        normTof,
        attenuationDb,
        // 20–22 triangle summary
        meanWaveSpeed,
        stdWaveSpeed,
        meanDecayRate,
        // 23–25 one-hot impactor node
        impactorNode == ImpactorNode.nodeA ? 1.0 : 0.0,
        impactorNode == ImpactorNode.nodeB ? 1.0 : 0.0,
        impactorNode == ImpactorNode.nodeC ? 1.0 : 0.0,
      ];

  // Backward-compat getters used by HeuristicNdtModel / app_controller.
  double get echoDeltaMs => 0.0;
  double get fPeakHz     => fDomHz;

  @override
  String toString() =>
      'NdtFeatures(tof=${tofMs.toStringAsFixed(2)}ms '
      'V=${waveSpeedMps.toStringAsFixed(0)}m/s '
      'f_dom=${fDomHz.toStringAsFixed(0)}Hz '
      'node=$impactorNode)';
}

// =============================================================================
// Feature extractor
// =============================================================================

/// Extract the full 26-feature [NdtFeatures] vector from a raw piezo waveform.
///
/// @param samples          Normalised samples (–1.0 … +1.0).
/// @param sampleRateHz     ADC rate (10 000 Hz for the piezo ADC).
/// @param baselineM        Tapper→listener distance in metres (for V, normTof).
/// @param impactorNode     Which node fired the servo (for one-hot encoding).
/// @param triangleStats    Optional [_TriangleStats] — mean/std V and mean α
///                         across the whole triangle.  If null, single-path
///                         values are used for the summary features.
/// @param tofThreshold     First-arrival threshold as fraction of peak (0.10).
/// @param postTofWindowMs  Analysis window after ToF (ms, default 10).
NdtFeatures extractNdtFeatures(
  List<double> samples,
  double sampleRateHz, {
  double baselineM        = 0.0,
  ImpactorNode impactorNode = ImpactorNode.nodeA,
  _TriangleStats? triangleStats,
  double tofThreshold     = 0.10,
  double postTofWindowMs  = 10.0,
}) {
  final zero = NdtFeatures(
    tofMs: 0, waveSpeedMps: 0, peakAmplitude: 0,
    fDomHz: 0, fCentHz: 0, decayRateNpMs: 0, signalEnergy: 0,
    bandLow: 0, bandMid: 0, bandHigh: 0, bandVhf: 0, bandRatio: 0,
    zeroCrossingRate: 0, rmsAmplitude: 0, crestFactor: 1,
    skewness: 0, kurtosis: 0,
    baselineM: baselineM, normTof: 0, attenuationDb: 0,
    meanWaveSpeed: 0, stdWaveSpeed: 0, meanDecayRate: 0,
    impactorNode: impactorNode,
    sampleRateHz: sampleRateHz,
  );

  if (samples.isEmpty) { return zero; }

  final samplesPerMs = sampleRateHz / 1000.0;

  // ── Peak amplitude ─────────────────────────────────────────────────────────
  final peakAmp = samples.map((v) => v.abs()).reduce(math.max);
  if (peakAmp < 1e-9) { return zero; }

  // ── Time of Flight ─────────────────────────────────────────────────────────
  final tofThreshAbs = peakAmp * tofThreshold;
  int tofIdx = 0;
  for (var i = 0; i < samples.length; i++) {
    if (samples[i].abs() >= tofThreshAbs) { tofIdx = i; break; }
  }
  final tofMs = tofIdx / samplesPerMs;

  // ── Wave speed ─────────────────────────────────────────────────────────────
  final waveSpeedMps = (baselineM > 0.01 && tofMs > 0)
      ? baselineM / (tofMs / 1000.0) : 0.0;

  // ── Analysis window (post-ToF) ─────────────────────────────────────────────
  final windowSamples = (postTofWindowMs * samplesPerMs)
      .round().clamp(4, samples.length - tofIdx).toInt();
  final window = samples.sublist(tofIdx, tofIdx + windowSamples);

  // ── RMS, crest factor ─────────────────────────────────────────────────────
  final sumSq  = window.fold<double>(0.0, (s, v) => s + v * v);
  final energy = sumSq / window.length;
  final rms    = math.sqrt(energy);
  final crest  = rms > 1e-9 ? peakAmp / rms : 1.0;

  // ── Zero-crossing rate ─────────────────────────────────────────────────────
  var crossings = 0;
  for (var i = 1; i < window.length; i++) {
    if ((window[i] >= 0) != (window[i - 1] >= 0)) { crossings++; }
  }
  final zcr = crossings / (window.length / samplesPerMs); // per ms

  // ── Skewness and kurtosis ─────────────────────────────────────────────────
  final mean  = window.fold<double>(0.0, (s, v) => s + v) / window.length;
  var m2 = 0.0, m3 = 0.0, m4 = 0.0;
  for (final v in window) {
    final d = v - mean;
    m2 += d * d;
    m3 += d * d * d;
    m4 += d * d * d * d;
  }
  m2 /= window.length;
  m3 /= window.length;
  m4 /= window.length;
  final sigma  = math.sqrt(m2 + 1e-12);
  final skew   = m3 / (sigma * sigma * sigma);
  final kurt   = (m4 / (sigma * sigma * sigma * sigma)) - 3.0; // excess

  // ── FFT — band energies, f_dom, f_cent ────────────────────────────────────
  final fftLen = nextPow2(windowSamples);
  final re = List<double>.filled(fftLen, 0.0);
  for (var i = 0; i < windowSamples; i++) {
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

  // Band energy accumulators (Hz boundaries)
  var eLow = 0.0, eMid = 0.0, eHigh = 0.0, eVhf = 0.0;

  for (var k = 1; k < half; k++) {
    final mag  = math.sqrt(re[k] * re[k] + im[k] * im[k]);
    final freq = k * binHz;
    if (mag > maxMag) { maxMag = mag; maxBin = k; }
    magSum    += mag;
    weightedF += freq * mag;
    if      (freq <  500)  { eLow  += mag; }
    else if (freq < 1500)  { eMid  += mag; }
    else if (freq < 4000)  { eHigh += mag; }
    else                   { eVhf  += mag; }
  }

  final fDomHz  = maxBin * binHz;
  final fCentHz = magSum > 1e-9 ? weightedF / magSum : 0.0;
  final eTot    = magSum + 1e-9;
  final bLow    = eLow  / eTot;
  final bMid    = eMid  / eTot;
  final bHigh   = eHigh / eTot;
  final bVhf    = eVhf  / eTot;
  final bRatio  = bLow  / (bHigh + 1e-9);

  // ── Decay rate (OLS on log-envelope) ─────────────────────────────────────
  const tauHold  = 2.0;
  final tauDecay = math.exp(-1.0 / tauHold);
  final logEnv   = <double>[];
  final tVec     = <double>[];
  var   envVal   = 0.0;
  for (var i = 0; i < window.length; i++) {
    envVal = math.max(window[i].abs(), envVal * tauDecay);
    if (envVal > 1e-6) {
      logEnv.add(math.log(envVal));
      tVec.add(i / samplesPerMs);
    }
  }
  double decayRateNpMs = 0.0;
  if (logEnv.length >= 4) {
    final n     = logEnv.length.toDouble();
    final tMean = tVec.fold<double>(0, (s, v) => s + v) / n;
    final lMean = logEnv.fold<double>(0, (s, v) => s + v) / n;
    var stt = 0.0, stl = 0.0;
    for (var i = 0; i < logEnv.length; i++) {
      stt += (tVec[i] - tMean) * (tVec[i] - tMean);
      stl += (tVec[i] - tMean) * (logEnv[i] - lMean);
    }
    decayRateNpMs = stt > 1e-12
        ? (-stl / stt).clamp(0.0, 100.0).toDouble() : 0.0;
  }

  // ── Structural / path features ────────────────────────────────────────────
  final normTof       = (baselineM > 0.01 && tofMs > 0)
      ? tofMs / baselineM : 0.0;
  final attenuationDb = 20 * math.log(peakAmp + 1e-9) / math.ln10;
  // (reference = 1.0 full scale; attenuation is negative for <1.0)

  // ── Triangle summary (fallback: use own path values) ──────────────────────
  final mV  = triangleStats?.meanWaveSpeed ?? waveSpeedMps;
  final sV  = triangleStats?.stdWaveSpeed  ?? 0.0;
  final mA  = triangleStats?.meanDecayRate ?? decayRateNpMs;

  return NdtFeatures(
    tofMs:           tofMs,
    waveSpeedMps:    waveSpeedMps,
    peakAmplitude:   peakAmp,
    fDomHz:          fDomHz,
    fCentHz:         fCentHz,
    decayRateNpMs:   decayRateNpMs,
    signalEnergy:    energy,
    bandLow:         bLow,
    bandMid:         bMid,
    bandHigh:        bHigh,
    bandVhf:         bVhf,
    bandRatio:       bRatio,
    zeroCrossingRate: zcr,
    rmsAmplitude:    rms,
    crestFactor:     crest,
    skewness:        skew,
    kurtosis:        kurt,
    baselineM:       baselineM,
    normTof:         normTof,
    attenuationDb:   attenuationDb,
    meanWaveSpeed:   mV,
    stdWaveSpeed:    sV,
    meanDecayRate:   mA,
    impactorNode:    impactorNode,
    sampleRateHz:    sampleRateHz,
  );
}

/// Triangle-level summary statistics passed into [extractNdtFeatures] so
/// the multi-path features (indices 20–22) reflect the whole quadrant rather
/// than only the current tapper→listener path.
///
/// Build this once per tap cycle from all paths in the active triangle,
/// then pass the same instance to every [extractNdtFeatures] call.
class _TriangleStats {
  final double meanWaveSpeed;
  final double stdWaveSpeed;
  final double meanDecayRate;
  const _TriangleStats({
    required this.meanWaveSpeed,
    required this.stdWaveSpeed,
    required this.meanDecayRate,
  });
}

/// Compute [_TriangleStats] from a list of per-path [NdtFeatures] objects
/// (one per tapper→listener path in the active triangle).
_TriangleStats computeTriangleStats(List<NdtFeatures> paths) {
  if (paths.isEmpty) {
    return const _TriangleStats(
        meanWaveSpeed: 0, stdWaveSpeed: 0, meanDecayRate: 0);
  }
  final n       = paths.length.toDouble();
  final meanV   = paths.map((p) => p.waveSpeedMps).reduce((a, b) => a + b) / n;
  final meanA   = paths.map((p) => p.decayRateNpMs).reduce((a, b) => a + b) / n;
  var   varV    = 0.0;
  for (final p in paths) {
    varV += (p.waveSpeedMps - meanV) * (p.waveSpeedMps - meanV);
  }
  return _TriangleStats(
    meanWaveSpeed: meanV,
    stdWaveSpeed:  math.sqrt(varV / n),
    meanDecayRate: meanA,
  );
}

/// Determine which [ImpactorNode] slot a tapper occupies in the active
/// triangle by sorting the three node IDs and assigning A/B/C by rank.
ImpactorNode impactorNodeFromIds(int tapperId, List<int> triangleIds) {
  final sorted = List<int>.from(triangleIds)..sort();
  final idx    = sorted.indexOf(tapperId).clamp(0, 2);
  return ImpactorNode.values[idx];
}

/// Convenience overload — extract features from firmware int16 waveform.
NdtFeatures extractNdtFeaturesFromInt16(
  List<int> samplesInt16,
  double sampleRateHz, {
  double baselineM        = 0.0,
  ImpactorNode impactorNode = ImpactorNode.nodeA,
  _TriangleStats? triangleStats,
  double tofThreshold     = 0.10,
  double postTofWindowMs  = 10.0,
}) {
  final normalised = samplesInt16.map((s) => s / 32768.0).toList();
  return extractNdtFeatures(
    normalised,
    sampleRateHz,
    baselineM:      baselineM,
    impactorNode:   impactorNode,
    triangleStats:  triangleStats,
    tofThreshold:   tofThreshold,
    postTofWindowMs: postTofWindowMs,
  );
}
