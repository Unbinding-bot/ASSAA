import 'dart:developer' as dev;

import 'material_model.dart';
import 'person_presence_model.dart';

/// Owns both AI models and handles the load-or-fall-back logic so the
/// rest of the app never has to know whether a trained model exists yet.
/// Call `initialize()` once at startup; `personModel`/`materialModel` are
/// always usable afterward (heuristic if nothing else loaded).
class ModelManager {
  PersonPresenceModel personModel = HeuristicPersonPresenceModel();
  MaterialModel materialModel = HeuristicMaterialModel();

  bool personModelIsTrained = false;
  bool materialModelIsTrained = false;

  Future<void> initialize() async {
    await Future.wait([_tryLoadPersonModel(), _tryLoadMaterialModel()]);
  }

  Future<void> _tryLoadPersonModel() async {
    final tflite = TflitePersonPresenceModel();
    try {
      await tflite.load();
      personModel = tflite;
      personModelIsTrained = true;
      dev.log('Loaded trained person-presence model.', name: 'ml.manager');
    } catch (e) {
      // Expected until a trained model exists -- assets/models/
      // person_presence.tflite won't be there yet. Not an error worth
      // surfacing loudly, just fall back.
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

  void dispose() {
    personModel.dispose();
    materialModel.dispose();
  }
}