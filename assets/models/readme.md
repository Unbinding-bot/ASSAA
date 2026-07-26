# assets/models/

Drop trained TFLite models here, named exactly:

- `person_presence.tflite` -- input: 7 floats (see SignalFeatures.toVector()
  in lib/ml/feature_vector.dart), output: 1 float (sigmoid probability,
  0-1, that a transient is a live person).
- `material.tflite` -- input: 4 floats (see TapFeatures.toVector() in
  lib/ml/material_model.dart), output: 4 floats (softmax over
  concrete/airVoid/possibleBody/unknown, in that order).

Until these exist, ModelManager (lib/ml/model_manager.dart) catches the
load failure and falls back to the rule-based heuristic models
automatically -- nothing else in the app needs to change when you drop a
real model in here.

This placeholder file exists only so `flutter pub get` doesn't choke on my big fat cock
an empty declared asset directory.
(or leave it, it won't be loaded as anything).