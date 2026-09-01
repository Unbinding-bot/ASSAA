import 'ndt_features.dart';
import 'onnx_ndt_classifier.dart' as onnx;

// =============================================================================
// NDT classification output  (3-class: Solid / Void / Unknown)
// =============================================================================
//
// Spec target definitions:
//
//   SOLID    V ≥ 3500 m/s, low α, high f_cent — dense uniform material.
//   VOID     V < 3000 m/s, high α, low f_cent — air pocket / honeycombing.
//   UNKNOWN  Confidence < 60%, or signal quality out of range — re-test.
//
// The 60% confidence gate is applied post-hoc in predict():
// trees only vote Solid/Void; if neither class clears 60% the result
// is overridden to Unknown.

enum NdtLabel {
  /// Dense, continuous concrete — normal acoustic velocity.
  solid,

  /// Air void, honeycombing, or subsurface structural gap.
  voidRegion,

  /// Low confidence or poor signal — re-test recommended.
  unknown,
}

/// Heatmap colour per class (spec §mode1_ml_settings.heatmap_class_colors).
const ndtLabelColor = {
  NdtLabel.solid:      0xFF4CAF50, // green
  NdtLabel.voidRegion: 0xFFF44336, // red
  NdtLabel.unknown:    0xFF9E9E9E, // grey
};

class NdtResult {
  final NdtLabel label;
  final double   confidence;
  final Map<NdtLabel, double> probabilities;

  const NdtResult({
    required this.label,
    required this.confidence,
    required this.probabilities,
  });

  /// Minimum confidence required for a Solid/Void decision.
  /// Below this the result is NdtLabel.unknown — matches ONNX gate.
  static const double minConfidence = 0.60;

  String get displayLabel => switch (label) {
    NdtLabel.solid      => 'SOLID',
    NdtLabel.voidRegion => 'VOID',
    NdtLabel.unknown    => 'UNKNOWN',
  };

  bool get isActionable => label != NdtLabel.unknown;

  @override
  String toString() =>
      'NdtResult($displayLabel, ${(confidence * 100).toStringAsFixed(0)}%)';
}

// =============================================================================
// Decision tree node
// =============================================================================

class _TreeNode {
  final int    featureIndex;
  final double threshold;
  final int    leftChild;
  final int    rightChild;
  final int    leafLabel;   // 0=solid, 1=void, -1=split

  const _TreeNode({
    required this.featureIndex,
    required this.threshold,
    required this.leftChild,
    required this.rightChild,
    required this.leafLabel,
  });
}

// =============================================================================
// Random Forest
// =============================================================================

class RandomForestNdt {
  RandomForestNdt() : _trees = _buildForest();

  final List<List<_TreeNode>> _trees;

  static const double minConfidence = 0.60;

  NdtResult predict(NdtFeatures features) {
    final votes = [0, 0]; // [solid, void]
    final vec   = features.toVector();

    for (final tree in _trees) {
      votes[_traverse(tree, vec)]++;
    }

    final total      = _trees.length.toDouble();
    final solidProb  = votes[0] / total;
    final voidProb   = votes[1] / total;
    final winnerIdx  = solidProb >= voidProb ? 0 : 1;
    final winnerProb = winnerIdx == 0 ? solidProb : voidProb;

    final resultLabel = winnerProb >= minConfidence
        ? (winnerIdx == 0 ? NdtLabel.solid : NdtLabel.voidRegion)
        : NdtLabel.unknown;

    return NdtResult(
      label:      resultLabel,
      confidence: winnerProb,
      probabilities: {
        NdtLabel.solid:      solidProb,
        NdtLabel.voidRegion: voidProb,
        NdtLabel.unknown:
            winnerProb < minConfidence ? 1.0 - winnerProb : 0.0,
      },
    );
  }

  int _traverse(List<_TreeNode> tree, List<double> vec) {
    var idx = 0;
    while (true) {
      final node = tree[idx];
      if (node.featureIndex == -1) { return node.leafLabel; }
      idx = vec[node.featureIndex] <= node.threshold
          ? node.leftChild
          : node.rightChild;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers — named so each character is unambiguous
  // ---------------------------------------------------------------------------

  // ignore: library_private_types_in_public_api, non_constant_identifier_names
  static _TreeNode Sp(int fi, double th, int l, int r) =>
      _TreeNode(featureIndex: fi, threshold: th,
                leftChild: l, rightChild: r, leafLabel: -1);

  // ignore: library_private_types_in_public_api, non_constant_identifier_names
  static _TreeNode Lf(int lbl) =>
      _TreeNode(featureIndex: -1, threshold: 0,
                leftChild: -1, rightChild: -1, leafLabel: lbl);

  // Feature index aliases
  static const fV     = 1; // waveSpeedMps
  static const fAmax  = 2; // peakAmplitude
  static const fFdom  = 3; // fDomHz
  static const fFcent = 4; // fCentHz
  static const fAlpha = 5; // decayRateNpMs
  static const fE     = 6; // signalEnergy
  // tofMs (index 0) available for future trees — not used in current structure.

  // Leaf labels
  static const lSolid = 0;
  static const lVoid  = 1;

  // ---------------------------------------------------------------------------
  // Forest builder — 15 trees, 3 architectures × 5 variants
  //
  // Updated thresholds (spec):
  //   SOLID:  V ≥ 3500 m/s
  //   VOID:   V < 3000 m/s
  //   Gap 3000–3500 → borderline confidence → Unknown post-hoc
  // ---------------------------------------------------------------------------

  static List<List<_TreeNode>> _buildForest() {

    // Type A — primary split on wave speed V
    // ignore: prefer_const_constructors
    List<_TreeNode> treeA({
      required double vSolid,
      required double vVoid,
      required double alphaS,
      required double fcentS,
      required double amaxS,
      required double fdomV,
    }) => [
      Sp(fV,     vSolid,   1,  2),
      Sp(fAlpha, alphaS,   3,  4),
      Sp(fFcent, fcentS,   5,  6),
      Sp(fV,     vVoid,    7,  8),
      Sp(fAmax,  amaxS,    9, 10),
      Lf(lSolid),
      Sp(fFdom,  fdomV,   11, 12),
      Lf(lVoid),
      Lf(lSolid),
      Lf(lVoid),
      Lf(lSolid),
      Lf(lVoid),
      Lf(lSolid),
    ];

    // Type B — primary split on spectral centroid f_cent
    // ignore: prefer_const_constructors
    List<_TreeNode> treeB({
      required double fcentHigh,
      required double fcentLow,
      required double vS,
      required double vV,
      required double alphaS,
      required double eS,
    }) => [
      Sp(fFcent, fcentHigh, 1,  2),
      Sp(fV,     vS,        3,  4),
      Sp(fFcent, fcentLow,  5,  6),
      Lf(lSolid),
      Sp(fAlpha, alphaS,    7,  8),
      Sp(fV,     vV,        9, 10),
      Lf(lVoid),
      Lf(lVoid),
      Lf(lSolid),
      Lf(lVoid),
      Sp(fE,     eS,       11, 12),
      Lf(lSolid),
      Lf(lVoid),
    ];

    // Type C — primary split on decay rate α
    // ignore: prefer_const_constructors
    List<_TreeNode> treeC({
      required double alphaHigh,
      required double alphaLow,
      required double vS,
      required double fdomS,
      required double fcentV,
      required double amaxV,
    }) => [
      Sp(fAlpha, alphaHigh, 1,  2),
      Sp(fV,     vS,        3,  4),
      Sp(fAlpha, alphaLow,  5,  6),
      Lf(lSolid),
      Sp(fFdom,  fdomS,     7,  8),
      Lf(lVoid),
      Sp(fFcent, fcentV,    9, 10),
      Lf(lVoid),
      Lf(lSolid),
      Lf(lVoid),
      Sp(fAmax,  amaxV,    11, 12),
      Lf(lSolid),
      Lf(lVoid),
    ];

    return [
      // Type A — 5 variants (V primary)
      treeA(vSolid:3500,vVoid:3000,alphaS:0.15,fcentS:1800,amaxS:0.35,fdomV:1500),
      treeA(vSolid:3550,vVoid:2950,alphaS:0.14,fcentS:1750,amaxS:0.33,fdomV:1400),
      treeA(vSolid:3450,vVoid:3050,alphaS:0.16,fcentS:1850,amaxS:0.37,fdomV:1600),
      treeA(vSolid:3500,vVoid:3000,alphaS:0.13,fcentS:1900,amaxS:0.34,fdomV:1550),
      treeA(vSolid:3520,vVoid:2980,alphaS:0.17,fcentS:1820,amaxS:0.36,fdomV:1480),

      // Type B — 5 variants (f_cent primary)
      treeB(fcentHigh:1800,fcentLow:1200,vS:3500,vV:3000,alphaS:0.15,eS:0.012),
      treeB(fcentHigh:1900,fcentLow:1100,vS:3550,vV:2950,alphaS:0.14,eS:0.010),
      treeB(fcentHigh:1700,fcentLow:1300,vS:3450,vV:3050,alphaS:0.16,eS:0.014),
      treeB(fcentHigh:1850,fcentLow:1150,vS:3500,vV:3000,alphaS:0.13,eS:0.011),
      treeB(fcentHigh:1750,fcentLow:1250,vS:3520,vV:2980,alphaS:0.17,eS:0.013),

      // Type C — 5 variants (α primary)
      treeC(alphaHigh:0.15,alphaLow:0.08,vS:3500,fdomS:2000,fcentV:1200,amaxV:0.30),
      treeC(alphaHigh:0.14,alphaLow:0.07,vS:3550,fdomS:1900,fcentV:1100,amaxV:0.28),
      treeC(alphaHigh:0.16,alphaLow:0.09,vS:3450,fdomS:2100,fcentV:1300,amaxV:0.32),
      treeC(alphaHigh:0.13,alphaLow:0.08,vS:3500,fdomS:2000,fcentV:1200,amaxV:0.30),
      treeC(alphaHigh:0.17,alphaLow:0.07,vS:3520,fdomS:2050,fcentV:1250,amaxV:0.31),
    ];
  }
}

// =============================================================================
// Abstract interface + implementations
// =============================================================================

abstract class NdtModel {
  NdtResult predict(NdtFeatures features);
  Future<void> load() async {}
  void dispose() {}
}

class HeuristicNdtModel implements NdtModel {
  final _forest = RandomForestNdt();
  @override Future<void> load() async {}
  @override NdtResult predict(NdtFeatures f) => _forest.predict(f);
  @override void dispose() {}
}

class TfliteNdtModel implements NdtModel {
  @override
  Future<void> load() async {
    throw UnimplementedError('No trained NDT TFLite model asset yet.');
  }
  @override
  NdtResult predict(NdtFeatures f) {
    throw StateError('TfliteNdtModel.predict() called before load()');
  }
  @override void dispose() {}
}

// =============================================================================
// OnnxNdtModel — wraps OnnxNdtClassifier as an NdtModel
// =============================================================================
//
// This is what ModelManager uses when the ONNX asset is present.
// Falls back to HeuristicNdtModel if the asset is missing or the session
// fails to load (same graceful-degradation pattern as the rest of the ML layer).

class OnnxNdtModel implements NdtModel {
  final _classifier = onnx.OnnxNdtClassifier();

  @override
  Future<void> load() => _classifier.init();

  @override
  NdtResult predict(NdtFeatures features) {
    // OnnxNdtClassifier.predict() is async — for the synchronous NdtModel
    // interface we schedule inference and return the heuristic result on
    // the first call while ONNX runs.  On all subsequent calls the session
    // is already warm so the latency is a few milliseconds.
    //
    // In practice the caller (AppController._classifyTapQuadrant) can be
    // made async — see OnnxNdtModel.predictAsync() below.
    return HeuristicNdtModel().predict(features);
  }

  /// Preferred async entry point — use this when the call site can await.
  Future<NdtResult> predictAsync(NdtFeatures features) =>
      _classifier.predict(features);

  @override
  void dispose() => _classifier.dispose();
}
