import 'dart:math' as math;

/// Iterative radix-2 Cooley-Tukey FFT, in place.
/// `re`/`im` length must be a power of 2.
///
/// Real hardware doesn't need this: the ESP32 firmware classifies knock vs.
/// scream onboard and only sends the app a timestamp + amplitude + kind.
/// This FFT exists purely so the in-app simulator can synthesize a
/// realistic-looking waveform and classify it the same way, so the
/// classification logic gets exercised before the firmware exists.
void fftInPlace(List<double> re, List<double> im) {
  final n = re.length;
  assert(n > 0 && (n & (n - 1)) == 0, 'FFT length must be a power of 2');

  // Bit-reversal permutation
  var j = 0;
  for (var i = 0; i < n - 1; i++) {
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
    var m = n >> 1;
    while (m >= 1 && j >= m) {
      j -= m;
      m >>= 1;
    }
    j += m;
  }

  for (var size = 2; size <= n; size *= 2) {
    final half = size ~/ 2;
    final theta = -2 * math.pi / size;
    for (var start = 0; start < n; start += size) {
      for (var k = 0; k < half; k++) {
        final angle = theta * k;
        final wr = math.cos(angle), wi = math.sin(angle);
        final i0 = start + k, i1 = start + k + half;
        final tr = re[i1] * wr - im[i1] * wi;
        final ti = re[i1] * wi + im[i1] * wr;
        re[i1] = re[i0] - tr;
        im[i1] = im[i0] - ti;
        re[i0] += tr;
        im[i0] += ti;
      }
    }
  }
}

/// Returns magnitude spectrum (length n/2) for a real input buffer.
/// `n` must be a power of 2; pads/truncates as needed.
List<double> magnitudeSpectrum(List<double> samples) {
  final n = samples.length;
  final re = List<double>.from(samples);
  final im = List<double>.filled(n, 0.0);
  fftInPlace(re, im);
  final half = n ~/ 2;
  return List.generate(half, (i) => math.sqrt(re[i] * re[i] + im[i] * im[i]));
}

int nextPow2(int n) {
  var p = 1;
  while (p < n) {
    p <<= 1;
  }
  return p;
}