import 'ndt_features.dart';

// =============================================================================
// NDT classification output
// =============================================================================

enum NdtLabel {
  /// Dense, continuous concrete — no anomaly detected.
  solid,

  /// Partial bond failure / horizontal crack.
  delamination,

  /// Air void, honeycomb, or hollow region.
  voidRegion,
}

class NdtResult {
  final NdtLabel label;
  final double confidence;
  final Map<NdtLabel, double> probabilities;

  const NdtResult({
    required this.label,
    required this.confidence,
    required this.probabilities,
  });

  String get displayLabel => switch (label) {
    NdtLabel.solid        => 'SOLID',
    NdtLabel.delamination => 'DELAMINATION',
    NdtLabel.voidRegion   => 'VOID',
  };

  @override
  String toString() =>
      'NdtResult($displayLabel, ${(confidence * 100).toStringAsFixed(0)}%)';
}

// =============================================================================
// Decision tree node
// =============================================================================

class _TreeNode {
  final int    featureIndex; // -1 = leaf
  final double threshold;
  final int    leftChild;
  final int    rightChild;
  final int    leafLabel;   // NdtLabel index on leaves, -1 on splits

  const _TreeNode({
    required this.featureIndex,
    required this.threshold,
    required this.leftChild,
    required this.rightChild,
    required this.leafLabel,
  });
}

// =============================================================================
// Random Forest — 7-feature, 15 trees, depth ≤ 5
// =============================================================================
//
// Feature indices (spec §5.2):
//   0 → tofMs          (Δt, ms)
//   1 → waveSpeedMps   (V, m/s)      NEW
//   2 → peakAmplitude  (A_max, 0–1)  NEW
//   3 → fDomHz         (f_dom, Hz)
//   4 → fCentHz        (f_cent, Hz)  NEW
//   5 → decayRateNpMs  (α, Np/ms)    NEW
//   6 → signalEnergy   (E)           NEW
//
// Calibration basis (spec §5.1, §6.1):
//
//   SOLID       V ≥ 3000 m/s, f_dom > 2500 Hz, fast decay (α > 0.15),
//               small echo, high A_max at given distance.
//
//   DELAMINATION  V 2200–3000 m/s, f_dom 1000–2500 Hz, moderate α,
//               noticeable echo (echoDeltaMs 1–5 ms), mid A_max.
//
//   VOID        V < 2200 m/s, f_dom < 1000 Hz, slow decay (α < 0.08),
//               large echo or no clear echo (total scatter), low A_max.
//
// Tree structure: each tree is a depth-5 binary tree with 7 split nodes
// and 8 leaf nodes, covering all 7 features across the 15-tree ensemble.
// Each tree uses a different random subset of 4 features (column sampling)
// to increase diversity.

class RandomForestNdt {
  RandomForestNdt() : _trees = _buildForest();

  final List<List<_TreeNode>> _trees;

  static const _labels = [
    NdtLabel.solid,
    NdtLabel.delamination,
    NdtLabel.voidRegion,
  ];

  NdtResult predict(NdtFeatures features) {
    final votes = [0, 0, 0];
    final vec   = features.toVector();

    for (final tree in _trees) {
      votes[_traverse(tree, vec)]++;
    }

    final total     = _trees.length.toDouble();
    final probs     = {
      NdtLabel.solid:        votes[0] / total,
      NdtLabel.delamination: votes[1] / total,
      NdtLabel.voidRegion:   votes[2] / total,
    };
    final winnerIdx =
        votes.indexed.reduce((a, b) => a.$2 >= b.$2 ? a : b).$1;

    return NdtResult(
      label:         _labels[winnerIdx],
      confidence:    votes[winnerIdx] / total,
      probabilities: probs,
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
  // Forest builder
  // ---------------------------------------------------------------------------
  //
  // Shorthand helpers keep the tree definitions readable.
  // _s(fi, th, l, r) = split node.  _L(lbl) = leaf node.

  static _TreeNode _s(int fi, double th, int l, int r) =>
      _TreeNode(featureIndex: fi, threshold: th,
                leftChild: l, rightChild: r, leafLabel: -1);

  static _TreeNode _L(int lbl) =>
      _TreeNode(featureIndex: -1, threshold: 0,
                leftChild: -1, rightChild: -1, leafLabel: lbl);

  // Feature indices
  static const _tof   = 0; // tofMs
  static const _v     = 1; // waveSpeedMps
  static const _amax  = 2; // peakAmplitude
  static const _fdom  = 3; // fDomHz
  static const _fcent = 4; // fCentHz
  static const _alpha = 5; // decayRateNpMs
  static const _e     = 6; // signalEnergy

  // Leaf label constants
  static const _solid  = 0;
  static const _delam  = 1;
  static const _void_  = 2;

  static List<List<_TreeNode>> _buildForest() {
    // Each tree is written as a flat BFS list.
    // The tree helper takes threshold parameters for bootstrap diversity.
    // 15 trees × 7 split nodes + 8 leaves = 15 nodes per tree.
    //
    // Tree layout (depth-5, using different feature priorities per tree):
    //
    //          [0]
    //         /   \
    //       [1]   [2]
    //       / \   / \
    //      [3][4][5][6]
    //      /\ /\ /\ /\
    //     L L L L L L L L    (nodes 7–14)

    // ignore: prefer_const_constructors
    List<_TreeNode> treeA({
      // Primary on V (wave speed)
      required double vSolid,   // ≤ → not solid
      required double vVoid,    // > → void
      required double fSolid,   // f_dom ≤ → delamination side
      required double alphaSolid, // α > → solid (fast decay)
      required double tofDelam,  // ToF ≤ → delamination vs void
      required double fVoid,    // f_dom ≤ → void
      required double aDelam,   // A_max > → delamination (not void)
    }) {
      return [
        _s(_v,    vSolid,   1,  2),  // 0  V ≤ vSolid → left (not solid)
        _s(_fdom, fSolid,   3,  4),  // 1  f_dom ≤ → delamination territory
        _s(_v,    vVoid,    5,  6),  // 2  V > vVoid → right = void
        _s(_alpha,alphaSolid,7, 8),  // 3  α check
        _s(_tof,  tofDelam, 9, 10),  // 4  ToF check
        _s(_fdom, fVoid,   11, 12),  // 5  f_dom check
        _L(_void_),                   // 6  V very high but low f → odd case → void
        _L(_delam),                   // 7  slow decay + low f → delamination
        _L(_solid),                   // 8  fast decay + low f → solid (noise)
        _L(_delam),                   // 9  mid-V, low f, short ToF → delamination
        _L(_void_),                   // 10 mid-V, low f, long ToF → void
        _s(_amax, aDelam,  13, 14),  // 11 mid-V, mid f
        _L(_void_),                   // 12 V high, low f → solid leaning void
        _L(_delam),                   // 13 high A_max → delamination
        _L(_void_),                   // 14 low A_max → void
      ];
    }

    // ignore: prefer_const_constructors
    List<_TreeNode> treeB({
      // Primary on ToF, secondary on f_cent
      required double tofSolid,
      required double tofVoid,
      required double fcentSolid,
      required double fcentDelam,
      required double eSolid,
      required double alphaVoid,
      required double vDelam,
    }) {
      return [
        _s(_tof,   tofSolid,  1,  2),  // 0
        _s(_fcent, fcentSolid,3,  4),  // 1  short ToF
        _s(_tof,   tofVoid,   5,  6),  // 2  long ToF
        _s(_e,     eSolid,    7,  8),  // 3  short ToF + low f_cent
        _L(_solid),                     // 4  short ToF + high f_cent → solid
        _s(_v,     vDelam,    9, 10),  // 5  mid ToF
        _s(_alpha, alphaVoid, 11,12),  // 6  very long ToF
        _L(_void_),                     // 7  short ToF + low f_cent + low E
        _L(_delam),                     // 8  short ToF + low f_cent + high E
        _L(_delam),                     // 9  mid ToF + high V → delamination
        _L(_void_),                     // 10 mid ToF + low V → void
        _s(_fcent, fcentDelam,13,14),  // 11 long ToF + fast decay
        _L(_void_),                     // 12 long ToF + slow decay → void
        _L(_delam),                     // 13 long ToF + fast decay + high f_cent
        _L(_void_),                     // 14 long ToF + fast decay + low f_cent
      ];
    }

    // ignore: prefer_const_constructors
    List<_TreeNode> treeC({
      // Primary on f_dom, secondary on α (decay rate)
      required double fHigh,
      required double fLow,
      required double alphaHigh,
      required double alphaLow,
      required double vHigh,
      required double tofShort,
      required double amaxHigh,
    }) {
      return [
        _s(_fdom,  fHigh,    1,  2),  // 0
        _s(_alpha, alphaHigh,3,  4),  // 1  high f_dom → solid or delamination
        _s(_fdom,  fLow,     5,  6),  // 2  low f_dom → delamination or void
        _L(_solid),                    // 3  high f + fast decay → solid
        _s(_tof,   tofShort, 7,  8),  // 4  high f + slow decay
        _s(_v,     vHigh,    9, 10),  // 5  mid f
        _s(_alpha, alphaLow, 11,12),  // 6  low f
        _L(_delam),                    // 7  high f + slow decay + short ToF
        _L(_solid),                    // 8  high f + slow decay + long ToF
        _L(_delam),                    // 9  mid f + high V → delamination
        _L(_void_),                    // 10 mid f + low V → void
        _s(_amax,  amaxHigh, 13,14),  // 11 low f + fast decay
        _L(_void_),                    // 12 low f + slow decay → void
        _L(_delam),                    // 13 low f + fast decay + high A_max
        _L(_void_),                    // 14 low f + fast decay + low A_max
      ];
    }

    // Build 15 trees: 5 of each type with bootstrap threshold variation.
    return [
      // ── Type A (V primary) ─────────────────────────────────────────────────
      treeA(vSolid:3000, vVoid:2200, fSolid:1000, alphaSolid:0.15, tofDelam:4.0, fVoid:800,  aDelam:0.4),
      treeA(vSolid:3100, vVoid:2100, fSolid:1100, alphaSolid:0.14, tofDelam:3.8, fVoid:750,  aDelam:0.38),
      treeA(vSolid:2900, vVoid:2300, fSolid: 900, alphaSolid:0.16, tofDelam:4.2, fVoid:850,  aDelam:0.42),
      treeA(vSolid:3050, vVoid:2150, fSolid:1050, alphaSolid:0.13, tofDelam:3.9, fVoid:780,  aDelam:0.41),
      treeA(vSolid:2950, vVoid:2250, fSolid: 950, alphaSolid:0.17, tofDelam:4.1, fVoid:820,  aDelam:0.39),

      // ── Type B (ToF primary) ───────────────────────────────────────────────
      treeB(tofSolid:3.0, tofVoid:5.0, fcentSolid:1500, fcentDelam:900, eSolid:0.01, alphaVoid:0.06, vDelam:2500),
      treeB(tofSolid:2.8, tofVoid:4.8, fcentSolid:1600, fcentDelam:850, eSolid:0.008,alphaVoid:0.05, vDelam:2400),
      treeB(tofSolid:3.2, tofVoid:5.2, fcentSolid:1400, fcentDelam:950, eSolid:0.012,alphaVoid:0.07, vDelam:2600),
      treeB(tofSolid:3.1, tofVoid:5.1, fcentSolid:1550, fcentDelam:900, eSolid:0.009,alphaVoid:0.055,vDelam:2550),
      treeB(tofSolid:2.9, tofVoid:4.9, fcentSolid:1450, fcentDelam:880, eSolid:0.011,alphaVoid:0.065,vDelam:2450),

      // ── Type C (f_dom primary) ─────────────────────────────────────────────
      treeC(fHigh:2500, fLow:1000, alphaHigh:0.15, alphaLow:0.06, vHigh:2500, tofShort:3.5, amaxHigh:0.35),
      treeC(fHigh:2600, fLow: 950, alphaHigh:0.14, alphaLow:0.05, vHigh:2400, tofShort:3.3, amaxHigh:0.33),
      treeC(fHigh:2400, fLow:1050, alphaHigh:0.16, alphaLow:0.07, vHigh:2600, tofShort:3.7, amaxHigh:0.37),
      treeC(fHigh:2550, fLow: 980, alphaHigh:0.13, alphaLow:0.055,vHigh:2450, tofShort:3.4, amaxHigh:0.34),
      treeC(fHigh:2450, fLow:1020, alphaHigh:0.17, alphaLow:0.065,vHigh:2550, tofShort:3.6, amaxHigh:0.36),
    ];
  }
}

// =============================================================================
// Abstract interface + concrete implementations
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
