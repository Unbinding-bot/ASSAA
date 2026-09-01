import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

import '../ml/ndt_features.dart';
import '../ml/random_forest_ndt.dart';

// =============================================================================
// OnnxNdtClassifier
// =============================================================================
//
// Loads  assets/models/ndt_random_forest_tuned_95pct.onnx  at runtime and
// runs inference for Mode 1 NDT void detection.
//
// ── Model I/O contract ────────────────────────────────────────────────────────
//
//   Input  tensor name : 'float_input'
//   Input  shape       : [1, 26]    — one sample, 26 float features
//   Input  dtype       : float32
//
//   Output 0 (label)   : tensor<string> [1]     — "Solid", "Void", "Unknown"
//   Output 1 (probs)   : tensor<map<string,float>> [1]  — probability dict
//
// The model was exported from a scikit-learn RandomForestClassifier via
// sklearn-onnx with a FloatTensorType([None, 26]) input spec.
//
// ── 60 % confidence gate ─────────────────────────────────────────────────────
//
// If the winning class probability < minConfidence (0.60), the result is
// overridden to NdtLabel.unknown regardless of the model's top class.
// This mirrors the spec requirement and is consistent with the heuristic
// Random Forest fallback in random_forest_ndt.dart.

const _kAssetPath = 'assets/models/ndt_random_forest_tuned_95pct.onnx';
const _kInputName = 'float_input';

class OnnxNdtClassifier {
  OrtSession? _session;
  bool _initialized = false;

  /// Load the ONNX session from assets.  Safe to call multiple times —
  /// subsequent calls are no-ops if the session is already loaded.
  Future<void> init() async {
    if (_initialized) { return; }
    try {
      OrtEnv.instance.init();
      final opts  = OrtSessionOptions();
      final bytes = await rootBundle.load(_kAssetPath);
      _session    = OrtSession.fromBuffer(
          bytes.buffer.asUint8List(), opts);
      _initialized = true;
      dev.log('ONNX NDT model loaded ($_kAssetPath).',
          name: 'ml.onnx');
    } catch (e) {
      dev.log('ONNX NDT model load failed: $e', name: 'ml.onnx');
      rethrow;
    }
  }

  /// Run inference on a 26-element feature vector.
  ///
  /// Returns an [NdtResult] with the 60 % confidence gate applied.
  /// Throws [StateError] if [init] has not been called successfully.
  Future<NdtResult> predict(NdtFeatures features) async {
    final session = _session;
    if (session == null) {
      throw StateError(
          'OnnxNdtClassifier: session not initialised — call init() first.');
    }

    final vec    = features.toVector();
    assert(vec.length == NdtFeatures.vectorLength,
        'Feature vector length must be ${NdtFeatures.vectorLength}, '
        'got ${vec.length}');

    // Build [1, 26] float32 input tensor.
    final f32   = Float32List.fromList(vec);
    final input = OrtValueTensor.createTensorWithDataList(f32, [1, 26]);
    final opts  = OrtRunOptions();

    try {
      final outputs = await session.runAsync(
          opts, {_kInputName: input});

      input.release();
      opts.release();

      // Output 0 — predicted label string.
      final rawLabel =
          ((outputs?[0]?.value as List?)?.first as String?) ?? 'Unknown';

      // Output 1 — probability map {label: probability}.
      final rawProbs =
          (outputs?[1]?.value as List?)?.first as Map? ?? {};

      final solidProb  = (rawProbs['Solid']   as num?)?.toDouble() ?? 0.0;
      final voidProb   = (rawProbs['Void']    as num?)?.toDouble() ?? 0.0;
      final unknownProb= (rawProbs['Unknown'] as num?)?.toDouble() ?? 0.0;

      final winnerProb = switch (rawLabel) {
        'Solid'   => solidProb,
        'Void'    => voidProb,
        _         => unknownProb,
      };

      // Apply 60 % confidence gate.
      final label = winnerProb >= NdtResult.minConfidence
          ? _labelFromString(rawLabel)
          : NdtLabel.unknown;

      return NdtResult(
        label:      label,
        confidence: winnerProb,
        probabilities: {
          NdtLabel.solid:      solidProb,
          NdtLabel.voidRegion: voidProb,
          NdtLabel.unknown:    winnerProb < NdtResult.minConfidence
              ? 1.0 - winnerProb
              : unknownProb,
        },
      );
    } catch (e) {
      dev.log('ONNX inference error: $e', name: 'ml.onnx');
      input.release();
      opts.release();
      rethrow;
    }
  }

  void dispose() {
    _session?.release();
    _session = null;
    _initialized = false;
  }

  static NdtLabel _labelFromString(String s) => switch (s) {
    'Solid'   => NdtLabel.solid,
    'Void'    => NdtLabel.voidRegion,
    _         => NdtLabel.unknown,
  };
}
