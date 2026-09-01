import 'dart:developer' as dev;

import 'material_model.dart';
import 'person_presence_model.dart';
import 'random_forest_ndt.dart';

/// Owns all three on-device models and handles load-or-fallback so the
/// rest of the app never has to know whether a trained model exists yet.
///
/// Models:
///   personModel   — is this acoustic transient from a live person?
///   materialModel — what material did this tap ray pass through?
///   ndtModel      — SOLID / DELAMINATION / VOID classification (Mode 1)
///
/// Call initialize() once at startup. All three models are always usable
/// after that — heuristic / built-in forest if no trained asset exists.
class ModelManager {
  PersonPresenceModel personModel   = HeuristicPersonPresenceModel();
  MaterialModel       materialModel = HeuristicMaterialModel();
  NdtModel            ndtModel      = HeuristicNdtModel();

  bool personModelIsTrained   = false;
  bool materialModelIsTrained = false;
  bool ndtModelIsTrained      = false;

  Future<void> initialize() async {
    await Future.wait([
      _tryLoadPersonModel(),
      _tryLoadMaterialModel(),
      _tryLoadNdtModel(),
    ]);
  }

  Future<void> _tryLoadPersonModel() async {
    final tflite = TflitePersonPresenceModel();
    try {
      await tflite.load();
      personModel = tflite;
      personModelIsTrained = true;
      dev.log('Loaded trained person-presence model.', name: 'ml.manager');
    } catch (e) {
      personModel = HeuristicPersonPresenceModel();
      personModelIsTrained = false;
      dev.log('No trained person-presence model, using heuristic ($e).',
          name: 'ml.manager');
    }
  }

  Future<void> _tryLoadMaterialModel() async {
    final tflite = TfliteMaterialModel();
    try {
      await tflite.load();
      materialModel = tflite;
      materialModelIsTrained = true;
      dev.log('Loaded trained material model.', name: 'ml.manager');
    } catch (e) {
      materialModel = HeuristicMaterialModel();
      materialModelIsTrained = false;
      dev.log('No trained material model, using heuristic ($e).',
          name: 'ml.manager');
    }
  }

  Future<void> _tryLoadNdtModel() async {
    final tflite = TfliteNdtModel();
    try {
      await tflite.load();
      ndtModel = tflite;
      ndtModelIsTrained = true;
      dev.log('Loaded trained NDT model.', name: 'ml.manager');
    } catch (e) {
      // Expected — assets/models/ndt.tflite won't exist until field-trained.
      // The built-in Random Forest heuristic runs without any asset.
      ndtModel = HeuristicNdtModel();
      ndtModelIsTrained = false;
      dev.log('No trained NDT model, using built-in Random Forest ($e).',
          name: 'ml.manager');
    }
  }

  void dispose() {
    personModel.dispose();
    materialModel.dispose();
    ndtModel.dispose();
  }
}
