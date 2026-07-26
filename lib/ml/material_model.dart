import 'dart:developer' as dev;

import 'package:tflite_flutter/tflite_flutter.dart';

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

/// Backbone for a trained on-device model, mirroring
/// TflitePersonPresenceModel. Expects `assets/models/material.tflite`
/// with a 4-input, 4-class-softmax output; falls back to the heuristic
/// via ModelManager if the asset isn't present.
class TfliteMaterialModel implements MaterialModel {
  TfliteMaterialModel({this.assetPath = 'assets/models/material.tflite'});
  final String assetPath;
  Interpreter? _interpreter;

  static const _classOrder = [
    MaterialType.concrete,
    MaterialType.airVoid,
    MaterialType.possibleBody,
    MaterialType.unknown,
  ];

  @override
  Future<void> load() async {
    _interpreter = await Interpreter.fromAsset(assetPath);
  }

  @override
  MaterialResult predict(TapFeatures f) {
    final interpreter = _interpreter;
    if (interpreter == null) {
      throw StateError('TfliteMaterialModel.predict() called before load()');
    }
    final input = [f.toVector()];
    final output = [List<double>.filled(_classOrder.length, 0.0)];
    try {
      interpreter.run(input, output);
    } catch (e) {
      dev.log('Material inference failed: $e', name: 'ml.material');
      rethrow;
    }
    final probs = <MaterialType, double>{};
    for (var i = 0; i < _classOrder.length; i++) {
      probs[_classOrder[i]] = output[0][i];
    }
    return MaterialResult(probs);
  }

  @override
  void dispose() {
    _interpreter?.close();
  }
}