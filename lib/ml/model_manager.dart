import 'dart:developer' as dev;

import 'material_model.dart';
import 'person_presence_model.dart';
import 'random_forest_ndt.dart';

// =============================================================================
// ModelManager
// =============================================================================
//
// Owns all three on-device models and handles load-or-fallback so the
// rest of the app never has to know whether a trained asset exists yet.
//
//   personModel   — is this acoustic transient from a live person?
//                   (TFLite, falls back to heuristic)
//
//   materialModel — what material did this tap ray pass through?
//                   (TFLite, falls back to heuristic)
//
//   ndtModel      — SOLID / VOID / UNKNOWN classification (Mode 1)
//                   Primary:  OnnxNdtModel  (ndt_random_forest_tuned_95pct.onnx)
//                   Fallback: HeuristicNdtModel  (built-in Random Forest)
//
// Call initialize() once at startup. All three models are always usable
// afterward — heuristic / built-in forest when no trained asset is present.

class ModelManager {
  PersonPresenceModel personModel   = HeuristicPersonPresenceModel();
  MaterialModel       materialModel = HeuristicMaterialModel();
  NdtModel            ndtModel      = HeuristicNdtModel();

  bool personModelIsTrained   = false;
  bool materialModelIsTrained = false;
  bool ndtModelIsTrained      = false;

  /// Expose the ONNX wrapper when loaded, so callers that can await may
  /// use [OnnxNdtModel.predictAsync] for the full async inference path.
  OnnxNdtModel? _onnxNdtModel;
  OnnxNdtModel? get onnxNdtModel => _onnxNdtModel;

  Future<void> initialize() async {
    await Future.wait([
      _tryLoadPersonModel(),
      _tryLoadMaterialModel(),
      _tryLoadNdtModel(),
    ]);
  }

  // ── Person-presence (TFLite) ───────────────────────────────────────────────

  Future<void> _tryLoadPersonModel() async {
    final tflite = TflitePersonPresenceModel();
    try {
      await tflite.load();
      personModel         = tflite;
      personModelIsTrained = true;
      dev.log('Loaded trained person-presence model.', name: 'ml.manager');
    } catch (e) {
      personModel         = HeuristicPersonPresenceModel();
      personModelIsTrained = false;
      dev.log('No trained person-presence model, using heuristic ($e).',
          name: 'ml.manager');
    }
  }

  // ── Material classifier (TFLite) ───────────────────────────────────────────

  Future<void> _tryLoadMaterialModel() async {
    final tflite = TfliteMaterialModel();
    try {
      await tflite.load();
      materialModel         = tflite;
      materialModelIsTrained = true;
      dev.log('Loaded trained material model.', name: 'ml.manager');
    } catch (e) {
      materialModel         = HeuristicMaterialModel();
      materialModelIsTrained = false;
      dev.log('No trained material model, using heuristic ($e).',
          name: 'ml.manager');
    }
  }

  // ── NDT void classifier (ONNX, primary) ────────────────────────────────────
  //
  // Tries to load the ONNX model first.  If the asset is missing or the
  // OrtSession fails to initialise, falls back to the built-in Random Forest
  // heuristic — exactly the same graceful-degradation approach used for the
  // TFLite models above.

  Future<void> _tryLoadNdtModel() async {
    final onnx = OnnxNdtModel();
    try {
      await onnx.load(); // loads OrtSession from assets/models/...onnx
      _onnxNdtModel  = onnx;
      ndtModel        = onnx;
      ndtModelIsTrained = true;
      dev.log('Loaded ONNX NDT model (26-feature, 95 % tuned).',
          name: 'ml.manager');
    } catch (e) {
      // Asset not present yet, or ORT init failed — use built-in forest.
      onnx.dispose();
      _onnxNdtModel  = null;
      ndtModel        = HeuristicNdtModel();
      ndtModelIsTrained = false;
      dev.log('No ONNX NDT model, using built-in Random Forest ($e).',
          name: 'ml.manager');
    }
  }

  void dispose() {
    personModel.dispose();
    materialModel.dispose();
    ndtModel.dispose();
  }
}
