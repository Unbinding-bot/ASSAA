import 'dart:math' as math;

// =============================================================================
// Adaptive Noise Floor Threshold  (spec §3.2 Method A)
// =============================================================================
//
// Arrival time t_i at node i is latched when the filtered amplitude exceeds:
//
//   T_thresh = μ_noise + k · σ_noise     (k ≈ 4.5)
//
// where μ_noise and σ_noise are estimated from a rolling window of recent
// "silence" samples — samples that have not themselves crossed the threshold.
//
// ── Why adaptive rather than fixed ─────────────────────────────────────────
//
//   Field environments change: a generator turning on, wind across the rubble,
//   traffic — all raise the ambient noise floor temporarily. A fixed threshold
//   (like the previous 0.04 RMS) either misses quiet signals or generates
//   false triggers in noisy conditions. The adaptive estimator tracks the
//   noise floor in real time and scales the threshold accordingly.
//
// ── Welford online algorithm ────────────────────────────────────────────────
//
//   μ and σ are maintained with Welford's single-pass online algorithm so no
//   circular buffer of samples is needed. Each update is O(1) and
//   numerically stable even for long-running streams.
//
//   On each non-triggering sample x:
//     n    ← n + 1
//     δ    ← x − μ
//     μ    ← μ + δ/n
//     δ2   ← x − μ          (use updated μ)
//     M2   ← M2 + δ·δ2
//     σ²  = M2 / n           (population variance)
//
// ── First-arrival latching ──────────────────────────────────────────────────
//
//   checkArrival() returns true on the first sample that exceeds the
//   threshold after a refractory period (default 5 ms). Subsequent crossings
//   within the refractory window are ignored so a single impact doesn't
//   trigger multiple T0 latches.

/// Per-channel adaptive threshold estimator.
///
/// Create one instance per node/channel and call [updateNoise] on every
/// background sample and [checkArrival] on every incoming sample.
class AdaptiveThreshold {
  /// @param k         Threshold multiplier (spec default 4.5).
  /// @param minThresh Absolute minimum threshold regardless of noise level.
  ///                  Prevents triggering on pure DC bias at startup.
  /// @param refractoryMs Refractory period after a trigger in milliseconds.
  AdaptiveThreshold({
    this.k            = 4.5,
    this.minThresh    = 0.01,
    this.refractoryMs = 5.0,
  });

  final double k;
  final double minThresh;
  final double refractoryMs;

  // Welford online estimator state.
  int    _n  = 0;
  double _mu = 0.0;
  double _m2 = 0.0;

  double _lastTriggerMs = -1e9;

  /// Background noise mean (μ_noise).
  double get noiseMean => _mu;

  /// Background noise standard deviation (σ_noise).
  double get noiseStd => _n > 1 ? math.sqrt(_m2 / _n) : 0.0;

  /// Current threshold:  T = max(minThresh, μ + k·σ).
  double get threshold => math.max(minThresh, _mu + k * noiseStd);

  /// Feed a sample that is considered background noise into the estimator.
  ///
  /// Typically called during a known-silence calibration window, or on any
  /// sample whose absolute value is below the current threshold (conservative
  /// self-update so a long ringing tail doesn't inflate σ).
  void updateNoise(double sample) {
    final x = sample.abs();
    _n++;
    final delta  = x - _mu;
    _mu += delta / _n;
    final delta2 = x - _mu;
    _m2 += delta * delta2;
  }

  /// Check whether [sample] constitutes a first-arrival event.
  ///
  /// @param sample      Current filtered sample value (signed or absolute).
  /// @param nowMs       Current time in milliseconds (e.g. timestampUs/1000).
  /// @param updateBg    If true and the sample is below threshold, also feed
  ///                    it into the noise estimator (default true — steady-state
  ///                    tracking). Set false during known-event windows so the
  ///                    impact waveform doesn't corrupt the noise model.
  ///
  /// Returns true on the first crossing after a refractory period.
  bool checkArrival(double sample, double nowMs, {bool updateBg = true}) {
    final absVal = sample.abs();
    final thresh = threshold;

    if (absVal < thresh) {
      if (updateBg) { updateNoise(sample); }
      return false;
    }

    // Below refractory guard — still a valid event but not a new T0.
    if (nowMs - _lastTriggerMs < refractoryMs) { return false; }

    _lastTriggerMs = nowMs;
    return true;
  }

  /// Scan a complete frame of samples and return the index of the first
  /// arrival, or -1 if none found.
  ///
  /// @param samples      List of (signed) samples.
  /// @param frameStartMs Wall-clock time of samples[0] in milliseconds.
  /// @param sampleRateHz Sampling rate (used to convert index → ms).
  int firstArrivalIndex(
    List<double> samples,
    double frameStartMs,
    double sampleRateHz,
  ) {
    final msPerSample = 1000.0 / sampleRateHz;
    for (var i = 0; i < samples.length; i++) {
      final nowMs = frameStartMs + i * msPerSample;
      if (checkArrival(samples[i], nowMs)) { return i; }
    }
    return -1;
  }

  /// Reset the estimator (call when switching to a new source or after a
  /// long silence gap that would otherwise leave a stale noise model).
  void reset() {
    _n  = 0;
    _mu = 0.0;
    _m2 = 0.0;
    _lastTriggerMs = -1e9;
  }

  /// Force-seed the noise model from a known-quiet calibration window.
  ///
  /// More accurate than the online warm-up because it uses the full window
  /// at once. Replaces any accumulated online state.
  void calibrateFromWindow(List<double> quietSamples) {
    if (quietSamples.isEmpty) { return; }
    reset();
    for (final s in quietSamples) { updateNoise(s); }
  }

  @override
  String toString() =>
      'AdaptiveThreshold(μ=${noiseMean.toStringAsFixed(4)}, '
      'σ=${noiseStd.toStringAsFixed(4)}, '
      'T=${threshold.toStringAsFixed(4)}, k=$k)';
}

// =============================================================================
// Multi-channel arrival-time estimator
// =============================================================================

/// Runs one [AdaptiveThreshold] per node and returns a map of
/// nodeId → arrival time (ms) for the first qualifying sample in each frame.
///
/// This is the Method A entry point that AppController calls per SyncedFrameSet.
Map<int, double> estimateArrivalTimesMethodA({
  required Map<int, List<double>> framesByNode,  // nodeId → filtered samples
  required Map<int, AdaptiveThreshold> detectors, // nodeId → estimator
  required double frameStartMs,
  required double sampleRateHz,
}) {
  final arrivals = <int, double>{};
  final msPerSample = 1000.0 / sampleRateHz;

  for (final entry in framesByNode.entries) {
    final nodeId  = entry.key;
    final samples = entry.value;
    final det     = detectors.putIfAbsent(
        nodeId, () => AdaptiveThreshold());

    final idx = det.firstArrivalIndex(samples, frameStartMs, sampleRateHz);
    if (idx >= 0) {
      arrivals[nodeId] = frameStartMs + idx * msPerSample;
    }
  }
  return arrivals;
}
