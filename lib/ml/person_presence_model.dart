import 'feature_vector.dart';

/// Output of the person-presence model: is the transient that produced
/// these features actually a live person, vs. debris settling, machinery,
/// or another false trigger.
class PersonPresenceResult {
  final double probability; // 0-1
  final bool isPerson;
  const PersonPresenceResult(this.probability) : isPerson = probability >= 0.5;
}

/// Interface both the placeholder heuristic and the eventual trained
/// model implement. Keep this signature stable -- swapping the
/// implementation the app uses should be a one-line change in
/// ModelManager, nothing downstream should need to know which one is
/// active.
abstract class PersonPresenceModel {
  Future<void> load();
  PersonPresenceResult predict(SignalFeatures features);
  void dispose() {}
}

/// Rule-based placeholder, standing in until the NIP collaboration
/// (Dr. Soriano's lab) produces an actual trained classifier. Scores
/// "how biological does this look" as a smooth 0-1 value rather than a
/// hard yes/no, using the same rough separations as the original
/// transient classifier (duration + band energy), so results are at
/// least directionally sane before real training data exists.
class HeuristicPersonPresenceModel implements PersonPresenceModel {
  @override
  Future<void> load() async {} // nothing to load

  @override
  PersonPresenceResult predict(SignalFeatures f) {
    // Knock-like: short, low-frequency-dominant, sharp.
    final knockScore = f.durationMs < 150
        ? (f.lowBandEnergy - 0.3).clamp(0.0, 1.0)
        : 0.0;
    // Scream-like: longer, vocal-band energy present.
    final screamScore = f.durationMs > 200
        ? (f.vocalBandEnergy - 0.15).clamp(0.0, 1.0)
        : 0.0;
    // Debris/noise tends to be either very short with broadband (not
    // low-band-concentrated) energy, or have an implausibly high zero
    // crossing rate for a knock/scream. Penalize both.
    final noisePenalty = f.zeroCrossingRate > 400 ? 0.3 : 0.0;

    final score =
        (knockScore.clamp(0.0, 1.0) + screamScore.clamp(0.0, 1.0)) - noisePenalty;
    return PersonPresenceResult(score.clamp(0.0, 1.0).toDouble());
  }

  @override
  void dispose() {}
}

/// Backbone for a trained on-device model. Once a TFLite asset exists at
/// `assets/models/person_presence.tflite`, this stub can be replaced with
/// a full ONNX or TFLite runtime loader (same pattern as OnnxNdtModel).
/// Until then, load() throws UnimplementedError and ModelManager falls back
/// to the HeuristicPersonPresenceModel.
class TflitePersonPresenceModel implements PersonPresenceModel {
  TflitePersonPresenceModel({
    this.assetPath = 'assets/models/person_presence.tflite',
  });
  final String assetPath;

  @override
  Future<void> load() async {
    throw UnimplementedError(
      'No trained person-presence model asset yet. '
      'Place a trained .tflite or .onnx file at $assetPath and wire a '
      'runtime loader here (see OnnxNdtModel for the ONNX pattern).');
  }

  @override
  PersonPresenceResult predict(SignalFeatures f) {
    throw StateError(
      'TflitePersonPresenceModel.predict() called before load()');
  }

  @override
  void dispose() {}
}