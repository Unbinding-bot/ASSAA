import '../ml/feature_vector.dart';
import '../models/event.dart';
import 'fft.dart';

/// Classifies a short waveform snippet centered on a threshold-crossing
/// transient. Used by the simulator; the ESP32 firmware will eventually
/// run the equivalent logic onboard and just report the result.
///
/// Heuristic, not a trained model -- this is the placeholder the NIP
/// collaboration (Dr. Soriano's lab) is meant to replace with an actual
/// trained classifier. Keep this function's signature stable so swapping
/// the body for a model call later doesn't ripple through the app.
///
/// Rough separation used here:
///  - knock:  short duration (<150ms), energy concentrated below ~150Hz,
///            sharp attack/decay -> low spectral spread
///  - scream: longer duration (>200ms), meaningful energy in the
///            ~300-3000Hz vocal/formant range
///  - unknown: neither pattern is clear (background noise, debris shift,
///            the rig's own tap pulse if not already excluded by timing)
class ClassificationResult {
  final EventKind kind;
  final double confidence;
  const ClassificationResult(this.kind, this.confidence);
}

ClassificationResult classifyTransient(
  List<double> samples,
  double sampleRateHz,
) {
  if (samples.isEmpty) {
    return const ClassificationResult(EventKind.unknown, 0.0);
  }

  final durationMs = samples.length / sampleRateHz * 1000;
  final n = nextPow2(samples.length);
  final padded = List<double>.filled(n, 0.0);
  for (var i = 0; i < samples.length; i++) {
    padded[i] = samples[i];
  }
  final spectrum = magnitudeSpectrum(padded);
  final binHz = sampleRateHz / n;

  double bandEnergy(double loHz, double hiHz) {
    final loBin = (loHz / binHz).floor().clamp(0, spectrum.length - 1).toInt();
    final hiBin = (hiHz / binHz).ceil().clamp(0, spectrum.length - 1).toInt();
    var sum = 0.0;
    for (var i = loBin; i <= hiBin; i++) {
      sum += spectrum[i];
    }
    return sum;
  }

  final total = spectrum.fold<double>(0.0, (a, b) => a + b) + 1e-9;
  final lowBand = bandEnergy(0, 150) / total; // knock territory
  final vocalBand = bandEnergy(300, 3000) / total; // scream territory

  if (durationMs < 150 && lowBand > 0.55) {
    final confidence = (lowBand).clamp(0.0, 1.0).toDouble();
    return ClassificationResult(EventKind.knock, confidence);
  }
  if (durationMs > 200 && vocalBand > 0.35) {
    final confidence = (vocalBand + 0.2).clamp(0.0, 1.0).toDouble();
    return ClassificationResult(EventKind.scream, confidence);
  }
  return const ClassificationResult(EventKind.unknown, 0.3);
}

/// Simple threshold + refractory-period peak detector over a streaming
/// buffer. Marks a transient start whenever |sample| crosses `threshold`
/// and at least `refractoryMs` has passed since the last trigger.
class ThresholdDetector {
  final double threshold;
  final double refractoryMs;
  double _lastTriggerMs = -1e9;

  ThresholdDetector({this.threshold = 0.3, this.refractoryMs = 120});

  bool check(double sampleAbs, double nowMs) {
    if (sampleAbs < threshold) return false;
    if (nowMs - _lastTriggerMs < refractoryMs) return false;
    _lastTriggerMs = nowMs;
    return true;
  }
}

/// Derives a knock/scream/unknown category directly from an already
/// -extracted SignalFeatures summary, for the live "detection_raw"
/// protocol path where the app receives features rather than a raw
/// waveform. Same rough separation as classifyTransient() above, just
/// operating on the compact feature vector instead of samples.
EventKind kindFromFeatures(SignalFeatures f) {
  if (f.durationMs < 150 && f.lowBandEnergy > 0.5) return EventKind.knock;
  if (f.durationMs > 200 && f.vocalBandEnergy > 0.3) return EventKind.scream;
  return EventKind.unknown;
}