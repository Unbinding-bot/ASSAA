/// What an active-mode tap path most likely passed through.
enum MaterialType { concrete, airVoid, possibleBody, unknown }

/// Features describing one tapper->listener path from a single tap
/// cycle, used to classify what the ray likely passed through.
///
/// `amplitudeDecay` needs the firmware to report received-pulse
/// amplitude alongside travel time (not just the timestamp) -- until
/// that's wired up, callers can pass 0.0 and the heuristic model falls
/// back to travel-time residual alone.
class TapFeatures {
  final double travelTimeMs;
  final double expectedTravelTimeMs; // at the calibrated baseline wavespeed
  final double residualMs; // measured - expected
  final double amplitudeDecay; // 0 = arrived as strong as expected, 1 = gone

  const TapFeatures({
    required this.travelTimeMs,
    required this.expectedTravelTimeMs,
    required this.residualMs,
    this.amplitudeDecay = 0.0,
  });

  static const vectorLength = 4;

  List<double> toVector() =>
      [travelTimeMs, expectedTravelTimeMs, residualMs, amplitudeDecay];
}

class MaterialResult {
  final Map<MaterialType, double> probabilities;
  const MaterialResult(this.probabilities);

  MaterialType get predicted =>
      probabilities.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

  double get confidence => probabilities[predicted] ?? 0.0;
}

abstract class MaterialModel {
  Future<void> load();
  MaterialResult predict(TapFeatures features);
  void dispose() {}
}

/// Rule-based placeholder. Real seismic material discrimination (rebar
/// vs. void vs. body reflection) is exactly what the NIP collaboration is
/// meant to improve on with actual training data -- this just gives the
/// pipeline something sane to run against until then.
class HeuristicMaterialModel implements MaterialModel {
  @override
  Future<void> load() async {}

  @override
  MaterialResult predict(TapFeatures f) {
    // Residual near zero (or negative/noise) -> solid, continuous path.
    if (f.residualMs <= 0.3) {
      return const MaterialResult({
        MaterialType.concrete: 0.75,
        MaterialType.airVoid: 0.15,
        MaterialType.possibleBody: 0.02,
        MaterialType.unknown: 0.08,
      });
    }
    // Moderate slowdown with little amplitude loss -> more likely an air
    // gap (sound still gets through, just detours/scatters).
    if (f.residualMs < 2.0 && f.amplitudeDecay < 0.5) {
      return const MaterialResult({
        MaterialType.concrete: 0.15,
        MaterialType.airVoid: 0.65,
        MaterialType.possibleBody: 0.1,
        MaterialType.unknown: 0.1,
      });
    }
    // Large slowdown AND significant amplitude loss -> soft tissue
    // absorbs and scatters more than an empty void would. Still a rough
    // heuristic, not a confident diagnosis -- flagged distinctly so a
    // rescuer knows this needs a passive-mode corroborating knock/scream,
    // not to dig based on this signal alone.
    return const MaterialResult({
      MaterialType.concrete: 0.05,
      MaterialType.airVoid: 0.25,
      MaterialType.possibleBody: 0.55,
      MaterialType.unknown: 0.15,
    });
  }

  @override
  void dispose() {}
}

/// Backbone for a trained on-device model. Once a TFLite or ONNX asset
/// exists at `assets/models/material.tflite`, wire a runtime loader here
/// (see OnnxNdtModel for the ONNX pattern). Until then, load() throws
/// UnimplementedError and ModelManager falls back to HeuristicMaterialModel.
class TfliteMaterialModel implements MaterialModel {
  TfliteMaterialModel({this.assetPath = 'assets/models/material.tflite'});
  final String assetPath;

  @override
  Future<void> load() async {
    throw UnimplementedError(
      'No trained material model asset yet. '
      'Place a trained .tflite or .onnx file at $assetPath and wire a '
      'runtime loader here (see OnnxNdtModel for the ONNX pattern).');
  }

  @override
  MaterialResult predict(TapFeatures f) {
    throw StateError('TfliteMaterialModel.predict() called before load()');
  }

  @override
  void dispose() {}
}
