import 'dart:math' as math;

import 'fft.dart';

/// Generalized Cross-Correlation with Phase Transform (GCC-PHAT).
///
/// Estimates the time delay of arrival (TDOA) between two time-aligned
/// audio frames from nodes i and j:
///
///   R_ij^GCC-PHAT(τ) = IFFT { (Xi · Xj*) / |Xi · Xj*| }
///   τ̂_ij = argmax_τ R_ij^GCC-PHAT(τ)
///
/// The PHAT (Phase Transform) whitening step — dividing by the magnitude
/// of the cross-power spectrum — flattens the spectrum so the
/// cross-correlation peak is as sharp as possible regardless of how
/// colored the input signal is. This is the key step that makes GCC-PHAT
/// robust to reverberation and multi-path in enclosed rubble spaces
/// (doc §4.3, §6.3).
///
/// Returns the estimated delay in seconds. Positive means frame B arrived
/// later than frame A (i.e. the source is closer to node A).
///
/// Both frames must be the same length. Zero-pad to a power of 2 for
/// best FFT performance — use [gccPhatPadded] which handles this
/// automatically.

/// Core GCC-PHAT: both input lists must already be the same power-of-2
/// length. Returns delay in seconds.
double gccPhat(
  List<double> frameA,
  List<double> frameB,
  double sampleRateHz,
) {
  assert(frameA.length == frameB.length, 'GCC-PHAT: frames must be same length');
  final n = frameA.length;
  assert(n > 0 && (n & (n - 1)) == 0, 'GCC-PHAT: frame length must be power of 2');

  // --- Forward FFT of both frames ---
  final reA = List<double>.from(frameA);
  final imA = List<double>.filled(n, 0.0);
  fftInPlace(reA, imA);

  final reB = List<double>.from(frameB);
  final imB = List<double>.filled(n, 0.0);
  fftInPlace(reB, imB);

  // --- Cross-power spectrum: Xi(f) · Xj*(f) ---
  // Complex multiply A by conjugate of B:
  //   (reA + j·imA)(reB - j·imB) = reA·reB + imA·imB  +  j(imA·reB - reA·imB)
  final reX = List<double>.filled(n, 0.0);
  final imX = List<double>.filled(n, 0.0);
  for (var k = 0; k < n; k++) {
    reX[k] = reA[k] * reB[k] + imA[k] * imB[k];
    imX[k] = imA[k] * reB[k] - reA[k] * imB[k];
  }

  // --- PHAT whitening: divide each bin by its magnitude ---
  // This makes every bin contribute equally regardless of spectral shape,
  // which sharpens the peak but can amplify noise at very low SNR bins.
  // A small epsilon floor prevents division by zero on silent channels.
  const eps = 1e-10;
  for (var k = 0; k < n; k++) {
    final mag = math.sqrt(reX[k] * reX[k] + imX[k] * imX[k]) + eps;
    reX[k] /= mag;
    imX[k] /= mag;
  }

  // --- Inverse FFT of the whitened cross-power spectrum ---
  // IFFT via conjugate trick: IFFT(X) = conj(FFT(conj(X))) / N
  for (var k = 0; k < n; k++) {
    imX[k] = -imX[k]; // conjugate
  }
  fftInPlace(reX, imX);
  for (var k = 0; k < n; k++) {
    reX[k] /= n;
    // imaginary part discarded — it should be ~0 for real inputs.
    // ignore: no-op
  }

  // --- Find the peak of the GCC-PHAT function ---
  // Lags run from 0 to n/2-1 (positive delays, source closer to B) and
  // from n/2 to n-1 (negative delays, source closer to A), stored in
  // circular order. We search both halves and map back to a signed lag.
  final half = n ~/ 2;
  var bestLag = 0;
  var bestVal = reX[0];

  for (var i = 1; i < n; i++) {
    if (reX[i] > bestVal) {
      bestVal = reX[i];
      bestLag = i;
    }
  }

  // Convert circular index to signed lag in samples.
  final signedLag = bestLag > half ? bestLag - n : bestLag;

  // Convert samples to seconds.
  return signedLag / sampleRateHz;
}

/// Convenience wrapper that zero-pads both frames to the next power of 2,
/// runs GCC-PHAT, and returns the delay in seconds.
///
/// Frames do not need to be the same length — shorter one is zero-padded.
/// Using [extraPad] doubles the FFT size for sub-sample accuracy (useful
/// when the array spacing is small and you need <0.1 sample resolution).
double gccPhatPadded(
  List<double> frameA,
  List<double> frameB,
  double sampleRateHz, {
  bool extraPad = false,
}) {
  final rawLen = math.max(frameA.length, frameB.length);
  var n = nextPow2(rawLen);
  if (extraPad) n *= 2; // zero-pad 2× for interpolated peak accuracy

  final a = List<double>.filled(n, 0.0);
  final b = List<double>.filled(n, 0.0);
  for (var i = 0; i < frameA.length; i++) { a[i] = frameA[i]; }
  for (var i = 0; i < frameB.length; i++) { b[i] = frameB[i]; }

  return gccPhat(a, b, sampleRateHz);
}

/// Given a set of per-pair TDOA delay estimates (seconds) and the
/// corresponding node pair identifiers, produces a map from (nodeA_id,
/// nodeB_id) → delay_seconds suitable for feeding into the LM TDOA solver.
///
/// Pairs where either frame was silent (all zeros, peak value < [minPeak])
/// are skipped so noisy/dead channels don't poison the solver.
Map<(int, int), double> estimateAllDelays({
  required Map<int, List<double>> framesByNode, // nodeId → filtered samples
  required double sampleRateHz,
  double minPeak = 0.01,
}) {
  final result = <(int, int), double>{};
  final ids = framesByNode.keys.toList()..sort();

  for (var i = 0; i < ids.length; i++) {
    for (var j = i + 1; j < ids.length; j++) {
      final a = framesByNode[ids[i]]!;
      final b = framesByNode[ids[j]]!;

      // Quick energy check — skip silent channels.
      final peakA = a.fold<double>(0, (m, v) => math.max(m, v.abs()));
      final peakB = b.fold<double>(0, (m, v) => math.max(m, v.abs()));
      if (peakA < minPeak || peakB < minPeak) continue;

      result[(ids[i], ids[j])] = gccPhatPadded(a, b, sampleRateHz, extraPad: true);
    }
  }
  return result;
}
