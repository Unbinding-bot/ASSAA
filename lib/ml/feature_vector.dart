import '../dsp/fft.dart';

/// A fixed-length summary of a short signal snippet, small enough to send
/// over the mesh (7 floats vs. a raw waveform) but rich enough for a
/// trained classifier to work with. Both AI models (person-presence and
/// material) consume features derived from this shape -- person-presence
/// uses this class directly, material uses the analogous TapFeatures in
/// ml/material_model.dart.
///
/// Field order is fixed and matches `toVector()` -- if you retrain a
/// model with a different feature set, update both together.
class SignalFeatures {
  final double durationMs;
  final double lowBandEnergy; // 0-150Hz share of total spectral energy
  final double midBandEnergy; // 150-300Hz share
  final double vocalBandEnergy; // 300-3000Hz share (scream/vocal territory)
  final double spectralCentroidHz; // "brightness" of the sound
  final double zeroCrossingRate; // crossings per second
  final double peakAmplitude; // 0-1 normalized

  const SignalFeatures({
    required this.durationMs,
    required this.lowBandEnergy,
    required this.midBandEnergy,
    required this.vocalBandEnergy,
    required this.spectralCentroidHz,
    required this.zeroCrossingRate,
    required this.peakAmplitude,
  });

  static const vectorLength = 7;

  List<double> toVector() => [
        durationMs,
        lowBandEnergy,
        midBandEnergy,
        vocalBandEnergy,
        spectralCentroidHz,
        zeroCrossingRate,
        peakAmplitude,
      ];

  /// Parses the feature vector out of a live "detection_raw" JSON message
  /// (see services/data_source.dart for the wire format).
  factory SignalFeatures.fromJson(Map<String, dynamic> json) {
    return SignalFeatures(
      durationMs: (json['durationMs'] as num).toDouble(),
      lowBandEnergy: (json['lowBand'] as num).toDouble(),
      midBandEnergy: (json['midBand'] as num).toDouble(),
      vocalBandEnergy: (json['vocalBand'] as num).toDouble(),
      spectralCentroidHz: (json['centroidHz'] as num).toDouble(),
      zeroCrossingRate: (json['zcr'] as num).toDouble(),
      peakAmplitude: (json['peakAmp'] as num).toDouble(),
    );
  }
}

/// Extracts a SignalFeatures summary from a raw waveform snippet. Used by
/// the simulator (and, if you ever stream a raw debug window from real
/// hardware, by that path too) -- production firmware would run the
/// equivalent computation onboard in C and only send the result.
SignalFeatures extractFeatures(List<double> samples, double sampleRateHz) {
  if (samples.isEmpty) {
    return const SignalFeatures(
      durationMs: 0,
      lowBandEnergy: 0,
      midBandEnergy: 0,
      vocalBandEnergy: 0,
      spectralCentroidHz: 0,
      zeroCrossingRate: 0,
      peakAmplitude: 0,
    );
  }

  final durationMs = samples.length / sampleRateHz * 1000;

  var peak = 0.0;
  var crossings = 0;
  for (var i = 0; i < samples.length; i++) {
    final v = samples[i].abs();
    if (v > peak) peak = v;
    if (i > 0 && (samples[i] >= 0) != (samples[i - 1] >= 0)) crossings++;
  }
  final zcr = crossings / (samples.length / sampleRateHz);

  final n = nextPow2(samples.length);
  final padded = List<double>.filled(n, 0.0);
  for (var i = 0; i < samples.length; i++) {
    padded[i] = samples[i];
  }
  final spectrum = magnitudeSpectrum(padded);
  final binHz = sampleRateHz / n;
  final total = spectrum.fold<double>(0.0, (a, b) => a + b) + 1e-9;

  double bandEnergy(double loHz, double hiHz) {
    final loBin = (loHz / binHz).floor().clamp(0, spectrum.length - 1).toInt();
    final hiBin = (hiHz / binHz).ceil().clamp(0, spectrum.length - 1).toInt();
    var sum = 0.0;
    for (var i = loBin; i <= hiBin; i++) {
      sum += spectrum[i];
    }
    return sum;
  }

  var weightedFreqSum = 0.0;
  for (var i = 0; i < spectrum.length; i++) {
    weightedFreqSum += i * binHz * spectrum[i];
  }
  final centroidHz = weightedFreqSum / total;

  return SignalFeatures(
    durationMs: durationMs,
    lowBandEnergy: bandEnergy(0, 150) / total,
    midBandEnergy: bandEnergy(150, 300) / total,
    vocalBandEnergy: bandEnergy(300, 3000) / total,
    spectralCentroidHz: centroidHz,
    zeroCrossingRate: zcr,
    peakAmplitude: peak,
  );
}