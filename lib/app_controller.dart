import 'dart:async';
import 'dart:collection';

import 'dsp/iir_filter.dart';
import 'dsp/gcc_phat.dart';
import 'dsp/transient_detector.dart';
import 'localization/ftm_calibration.dart';
import 'localization/fusion.dart';
import 'localization/navigation.dart';
import 'localization/quadrant_selector.dart';
import 'localization/rssi_localization.dart';
import 'localization/tdoa_solver.dart';
import 'localization/tomography.dart';
import 'math3d.dart';
import 'ml/model_manager.dart';
import 'ml/ndt_features.dart';
import 'ml/random_forest_ndt.dart';
import 'models/event.dart';
import 'models/node.dart';
import 'models/rescuer.dart';
import 'models/voxel.dart';
import 'services/data_source.dart';
import 'services/esp32_connection.dart';
import 'services/simulation_service.dart';
import 'services/udp_audio_receiver.dart';

export 'ml/random_forest_ndt.dart' show NdtResult, NdtLabel;
export 'localization/quadrant_selector.dart' show QuadrantResult;

enum ConnectionMode { none, sim, live }

// ---------------------------------------------------------------------------
// Per-node IIR filter bank
// ---------------------------------------------------------------------------

class _NodeFilterBank {
  _NodeFilterBank(double sampleRateHz, CustomFilterProfile customProfile)
      : knock    = IirBandpassFilter.preset(FilterBand.knock,    sampleRateHz),
        scream   = IirBandpassFilter.preset(FilterBand.scream,   sampleRateHz),
        metallic = IirBandpassFilter.preset(FilterBand.metallic, sampleRateHz),
        custom   = IirBandpassFilter.fromProfile(customProfile,  sampleRateHz),
        _sampleRateHz = sampleRateHz;

  final IirBandpassFilter knock;
  final IirBandpassFilter scream;
  final IirBandpassFilter metallic;
  IirBandpassFilter custom;
  final double _sampleRateHz;

  void rebuildCustom(CustomFilterProfile profile) {
    custom = IirBandpassFilter.fromProfile(profile, _sampleRateHz);
  }

  (List<double>, FilterBand) bestBand(List<double> raw,
      {bool includeCustom = false}) {
    final kOut = knock.processBatch(raw);
    final sOut = scream.processBatch(raw);
    final mOut = metallic.processBatch(raw);
    final kRms = _rms(kOut), sRms = _rms(sOut), mRms = _rms(mOut);

    if (includeCustom) {
      final cOut = custom.processBatch(raw);
      final cRms = _rms(cOut);
      if (cRms >= kRms && cRms >= sRms && cRms >= mRms) {
        return (cOut, FilterBand.custom);
      }
    }

    if (kRms >= sRms && kRms >= mRms) { return (kOut, FilterBand.knock); }
    if (sRms >= kRms && sRms >= mRms) { return (sOut, FilterBand.scream); }
    return (mOut, FilterBand.metallic);
  }

  static double _rms(List<double> s) {
    if (s.isEmpty) { return 0; }
    var sum = 0.0;
    for (final v in s) { sum += v * v; }
    return sum / s.length;
  }
}

// ---------------------------------------------------------------------------
// AppController
// ---------------------------------------------------------------------------

/// Central state owner and DSP/ML hub.
///
/// ── Mode 1 (Active NDT) pipeline ─────────────────────────────────────────
///
///   TapCycle arrives
///     → selectTriangleFromTapCycle()   picks 3 closest nodes
///     → extractNdtFeatures()           ToF, ΔT_echo, f_peak per path
///     → ndtModel.predict()             SOLID / VOID / UNKNOWN
///     → backProjectTapCycle()          tomography on selected triangle
///     → fuseVoxelGrid()
///     → lastNdtResult published to UI
///
/// ── Mode 2 (Passive Triangulation) pipeline ──────────────────────────────
///
///   AudioFrame arrives per node
///     → IIR filter bank → AudioFrameSynchronizer
///     → SyncedFrameSet emitted
///     → selectTriangleFromFrameTimestamps()   pick 3 active nodes
///     → estimateAllDelays() on those 3 only   GCC-PHAT
///     → solveTdoaLM(fixedZ = planeZ)          2-D hyperbolic solve
///     → applyTdoaResult + fuseVoxelGrid
///     → _recomputeNavVector()
///
/// ── Fallback ─────────────────────────────────────────────────────────────
///
///   If quadrant selection returns null (< 3 nodes with valid arrivals),
///   both pipelines fall back to using all available nodes — same behaviour
///   as before the quadrant-aware architecture was added.
class AppController {
  AppController() {
    grid = VoxelGrid(
      nx: 10, ny: 10, nz: 1,   // flat 2-D grid — z-axis is depth estimate only
      origin: const Vec3(-5, -5, 0.0),
      cellSize: 1.0,
    );
    // ignore: unawaited_futures
    modelManager.initialize().then((_) {
      _log('Person: ${modelManager.personModelIsTrained ? "trained" : "heuristic"}.  '
          'Material: ${modelManager.materialModelIsTrained ? "trained" : "heuristic"}.  '
          'NDT: ${modelManager.ndtModelIsTrained ? "trained" : "Random Forest"}.');
      _notify();
    });
  }

  // ── Public state (read by UI) ────────────────────────────────────────────

  final modelManager = ModelManager();
  ConnectionStatus connectionStatus = ConnectionStatus.disconnected;
  ConnectionMode mode = ConnectionMode.none;

  final nodes = <int, SensorNode>{};
  late final VoxelGrid grid;

  final recentEvents    = Queue<DetectionEvent>();
  final recentTapCycles = Queue<TapCycle>();
  final logLines        = Queue<String>();
  static const _maxLog  = 200;

  TdoaResult?      lastFix;
  RescuerFix?      rescuerFix;
  NavigationVector? navigationVector;

  /// Most recent NDT classification result (Mode 1). Null before first tap.
  NdtResult? lastNdtResult;

  /// The 3-node triangle that produced [lastNdtResult] / [lastFix].
  /// UI uses this to highlight the active nodes on the map.
  QuadrantResult? activeQuadrant;

  double wavespeedMps       = 340.0;
  double rssiTxPowerAt1m    = -40.0;
  double rssiPathLossExponent = 3.0;
  double userHeadingRad     = 0.0;

  // ── Private DSP state ────────────────────────────────────────────────────

  static const double _kSampleRateHz = 10000.0; // piezo ADC @ 10 kHz

  /// Shared custom filter profile — written by the UI, read by filter banks.
  final customFilterProfile = CustomFilterProfile();

  /// Whether the custom profile is included in the best-band competition.
  bool useCustomFilterBand = false;

  final _filterBanks            = <int, _NodeFilterBank>{};
  final _frameSynchronizer      = AudioFrameSynchronizer();
  StreamSubscription? _syncSub;
  final _latestFilteredFrames   = <int, List<double>>{};

  // Timestamp of transient detection per node — used for quadrant selection
  // in the GCC-PHAT path (we use the frame timestamp where energy exceeded
  // threshold as a proxy for arrival time).
  final _latestTransientUs      = <int, int>{}; // nodeId → µs

  final _ftmDistances = <(int, int), List<double>>{};
  final _rescuerSamples = <int, RescuerRssiSample>{};
  final _navSmoother = NavigationSmoother();

  DataSource? _source;
  StreamSubscription? _sub;
  StreamSubscription? _statusSub;

  final _onChange = StreamController<void>.broadcast();
  Stream<void> get onChange => _onChange.stream;

  // ── Connection management ────────────────────────────────────────────────

  Future<void> connectSim() async {
    await _swapSource(SimulationService());
    mode = ConnectionMode.sim;
    _log('Simulation started.');
    _notify();
  }

  Future<void> connectLive(Uri gatewayUri) async {
    await _swapSource(Esp32GatewayConnection(gatewayUri));
    mode = ConnectionMode.live;
    _log('Connecting to $gatewayUri …');
    _notify();
  }

  Future<void> _swapSource(DataSource next) async {
    _sub?.cancel();
    _statusSub?.cancel();
    _syncSub?.cancel();
    _source?.stop();

    nodes.clear();
    grid.resetAll();
    recentEvents.clear();
    recentTapCycles.clear();
    lastFix = null;
    lastNdtResult = null;
    activeQuadrant = null;
    rescuerFix = null;
    navigationVector = null;
    _rescuerSamples.clear();
    _filterBanks.clear();
    _latestFilteredFrames.clear();
    _latestTransientUs.clear();
    _ftmDistances.clear();
    _navSmoother.reset();
    connectionStatus = ConnectionStatus.disconnected;

    _source = next;
    _sub = next.messages.listen(_handleMessage, onError: (e) {
      _log('Data source error: $e');
      _notify();
    });
    _statusSub = next.status.listen((s) {
      connectionStatus = s;
      _notify();
    });
    _syncSub = _frameSynchronizer.sets.listen(_handleSyncedFrameSet);
    await next.start();
  }

  void disconnect() {
    _sub?.cancel();
    _statusSub?.cancel();
    _syncSub?.cancel();
    _source?.stop();
    _source = null;
    mode = ConnectionMode.none;
    connectionStatus = ConnectionStatus.disconnected;
    _log('Disconnected.');
    _notify();
  }

  // ── Calibration setters ───────────────────────────────────────────────────

  void setWavespeed(double mps) { wavespeedMps = mps; _notify(); }

  void setRssiCalibration({double? txPowerAt1m, double? pathLossExponent}) {
    if (txPowerAt1m != null)    { rssiTxPowerAt1m = txPowerAt1m; }
    if (pathLossExponent != null) { rssiPathLossExponent = pathLossExponent; }
    _notify();
  }

  void setUserHeading(double radians) {
    userHeadingRad = radians;
    _recomputeNavVector();
    _notify();
  }

  /// Update the custom operator frequency profile (spec §3.1 fourth row).
  /// Rebuilds all active per-node filter banks so the change takes effect
  /// on the next audio frame without a reconnect.
  void setCustomFilterProfile({double? centerHz, double? bandwidthHz}) {
    final changed = customFilterProfile.update(
        centerHz: centerHz, bandwidthHz: bandwidthHz);
    if (changed) {
      for (final bank in _filterBanks.values) {
        bank.rebuildCustom(customFilterProfile);
      }
      _notify();
    }
  }

  void setUseCustomFilterBand({required bool enabled}) {
    useCustomFilterBand = enabled;
    _notify();
  }

  // ── Message router ────────────────────────────────────────────────────────

  void _handleMessage(Object msg) {
    if (msg is SensorNode) {
      nodes[msg.id] = msg;
    } else if (msg is AudioFrame) {
      _handleAudioFrame(msg);
    } else if (msg is TapCycle) {
      _handleTapCycle(msg);
    } else if (msg is TapData) {
      _log('TapData from node ${msg.nodeId}');
    } else if (msg is RawDetectionSample) {
      _handleRawDetection(msg);
    } else if (msg is DetectionEvent) {
      _handleDetection(msg);
    } else if (msg is RescuerRssiSample) {
      _handleRescuerRssi(msg);
    } else if (msg is FtmMeasurement) {
      _handleFtmMeasurement(msg);
    }
    _notify();
  }

  // =========================================================================
  // MODE 2 — Passive triangulation  (IIR → sync → GCC-PHAT → LM, 3-node)
  // =========================================================================

  void _handleAudioFrame(AudioFrame frame) {
    final bank = _filterBanks.putIfAbsent(
        frame.nodeId, () => _NodeFilterBank(_kSampleRateHz, customFilterProfile));
    final (filtered, band) = bank.bestBand(frame.samples,
        includeCustom: useCustomFilterBand);
    _latestFilteredFrames[frame.nodeId] = filtered;
    _frameSynchronizer.add(frame);
    _detectTransientInFrame(frame.nodeId, filtered, band,
        frame.timestampUs / 1000.0, frame.timestampUs);
  }

  void _handleSyncedFrameSet(SyncedFrameSet set) {
    if (set.frames.length < 3) { return; }

    final filteredByNode = <int, List<double>>{};
    for (final entry in set.frames.entries) {
      final f = _latestFilteredFrames[entry.key];
      if (f != null) { filteredByNode[entry.key] = f; }
    }
    if (filteredByNode.length < 3) { return; }

    // ── Quadrant selection ─────────────────────────────────────────────────
    // Use each node's most recent transient timestamp as the arrival proxy.
    // Nodes that haven't seen a transient recently are excluded from selection
    // (their _latestTransientUs entry will be old and sorted to the back).
    final frameTs = <int, int>{};
    for (final id in filteredByNode.keys) {
      frameTs[id] = _latestTransientUs[id] ?? set.windowTimestampUs;
    }

    final quadrant = selectTriangleFromFrameTimestamps(
      frameTimestampsUs: frameTs,
      allNodes: nodes,
    );

    // Use only the 3 quadrant nodes; fall back to all nodes if selection fails.
    final activeIds = quadrant?.nodes.map((n) => n.id).toSet()
        ?? filteredByNode.keys.toSet();
    final activeFiltered = {
      for (final id in activeIds)
        if (filteredByNode.containsKey(id)) id: filteredByNode[id]!,
    };
    if (activeFiltered.length < 3) { return; }

    // ── GCC-PHAT on the selected triangle only ─────────────────────────────
    final delays = estimateAllDelays(
      framesByNode: activeFiltered,
      sampleRateHz: _kSampleRateHz,
    );
    if (delays.isEmpty) { return; }

    final refId = activeFiltered.keys.reduce((a, b) => a < b ? a : b);
    final rangeDiffs = <int, double>{};
    for (final entry in delays.entries) {
      final (idA, idB) = entry.key;
      final delayS = entry.value;
      if (idA == refId) {
        rangeDiffs[idB] = delayS * wavespeedMps;
      } else if (idB == refId) {
        rangeDiffs[idA] = -delayS * wavespeedMps;
      }
    }
    if (rangeDiffs.length < 2) { return; }

    final nodePositions = {
      for (final id in activeFiltered.keys)
        if (nodes.containsKey(id)) id: nodes[id]!.position,
    };
    if (nodePositions.length < 3) { return; }

    // Always constrain to z=0 — the map is 2-D. The z component of the
    // result is the solver's depth estimate (shown as a chip on the map).
    const fixedZ    = 0.0;
    final initGuess = quadrant?.triangleCentroid ?? _gridCenter();

    final result = solveTdoaLM(
      rangeDiffsM:   rangeDiffs,
      nodePositions: nodePositions,
      refNodeId:     refId,
      initialGuess:  initGuess,
      fixedZ:        fixedZ,
    );

    if (result != null) {
      lastFix        = result;
      activeQuadrant = quadrant;
      applyTdoaResult(grid, result);
      fuseVoxelGrid(grid);
      _recomputeNavVector();
      final qLabel = quadrant != null
          ? 'Q[${quadrant.nodes.map((n) => n.id).join(',')}]'
          : 'full';
      _log('Mode 2 fix $qLabel → '
          '(${result.position.x.toStringAsFixed(1)}, '
          '${result.position.y.toStringAsFixed(1)}) m  '
          'conf ${(result.confidence * 100).toStringAsFixed(0)}%');
      _notify();
    }
  }

  void _detectTransientInFrame(int nodeId, List<double> filtered,
      FilterBand band, double timestampMs, int timestampUs) {
    final rms = _NodeFilterBank._rms(filtered);
    const threshold = 0.04;
    if (rms < threshold) { return; }

    // Record the µs timestamp of this transient for quadrant selection.
    _latestTransientUs[nodeId] = timestampUs;

    final kind = switch (band) {
      FilterBand.knock    => EventKind.knock,
      FilterBand.scream   => EventKind.scream,
      FilterBand.metallic => EventKind.metallic,
      FilterBand.custom   => EventKind.knock, // custom band treated as knock-type transient
    };
    recentEvents.addFirst(DetectionEvent(
      nodeId:     nodeId,
      timestampMs: timestampMs,
      kind:       kind,
      amplitude:  rms.clamp(0.0, 1.0).toDouble(),
      confidence: (rms / 0.5).clamp(0.0, 1.0).toDouble(),
    ));
    while (recentEvents.length > 100) { recentEvents.removeLast(); }
  }

  // =========================================================================
  // MODE 1 — Active NDT  (quadrant select → NDT features → Random Forest)
  // =========================================================================

  Future<void> _handleTapCycle(TapCycle cycle) async {
    recentTapCycles.addFirst(cycle);
    while (recentTapCycles.length > 30) { recentTapCycles.removeLast(); }

    // ── Quadrant selection ─────────────────────────────────────────────────
    final quadrant = selectTriangleFromTapCycle(
      cycle:    cycle,
      allNodes: nodes,
    );

    if (quadrant != null) {
      activeQuadrant = quadrant;

      // ── NDT feature extraction + Random Forest ─────────────────────────
      // Run on each tapper→listener path within the selected triangle.
      // Uses the TapCycle's arrivalMs as ToF directly; echo/freq come from
      // the waveform in TapData.  Since TapData waveforms may not have
      // arrived yet (they're a separate message), we derive features from
      // timing + heuristic waveform models when no raw waveform is cached.
      final ndtResult = await _classifyTapQuadrant(cycle, quadrant);
      if (ndtResult != null) {
        lastNdtResult = ndtResult;
        _log('NDT [${quadrant.nodes.map((n) => n.id).join(',')}]: '
            '${ndtResult.displayLabel} '
            '(${(ndtResult.confidence * 100).toStringAsFixed(0)}%)');
      }
    }

    // ── Tomography back-projection on triangle nodes only ─────────────────
    // Build a filtered cycle containing only the quadrant nodes.
    final filteredCycle = quadrant != null
        ? TapCycle(
            tapperId: cycle.tapperId,
            arrivalMs: {
              for (final e in cycle.arrivalMs.entries)
                if (quadrant.nodes.any((n) => n.id == e.key)) e.key: e.value,
            },
            firedAt: cycle.firedAt,
          )
        : cycle; // fallback: use all nodes

    backProjectTapCycle(
      cycle:                filteredCycle,
      nodes:                nodes,
      grid:                 grid,
      baselineWavespeedMps: wavespeedMps,
    );
    fuseVoxelGrid(grid);

    _log('Tap cycle node ${cycle.tapperId}: '
        '${filteredCycle.arrivalMs.length} arrivals'
        '${quadrant != null ? " (triangle)" : " (all nodes)"}.');
  }

  /// Extracts NDT features from travel-time data and classifies the quadrant.
  ///
  /// When a raw waveform is available in [_cachedPiezoWaveforms] (keyed by
  /// nodeId, populated when TapData arrives) it is used for full feature
  /// extraction. Otherwise we synthesise an NdtFeatures vector from the
  /// travel-time residual alone (ToF from arrivalMs, echo=0, f_peak inferred
  /// from wavespeed) so the classifier still runs with degraded but non-zero
  /// input.
  Future<NdtResult?> _classifyTapQuadrant(
      TapCycle cycle, QuadrantResult quadrant) async {
    final tapper = nodes[cycle.tapperId];
    if (tapper == null) { return null; }

    // Collect one NdtFeatures per tapper→listener path in the triangle.
    final featuresList = <NdtFeatures>[];

    for (final node in quadrant.nodes) {
      if (node.id == cycle.tapperId) { continue; }
      final measuredMs = cycle.arrivalMs[node.id];
      if (measuredMs == null) { continue; }
      final distM = tapper.position.distanceTo(node.position);

      // Try raw waveform first.
      final waveform = _cachedPiezoWaveforms[node.id];
      if (waveform != null && waveform.isNotEmpty) {
        final iNode = impactorNodeFromIds(
          cycle.tapperId,
          quadrant.nodes.map((n) => n.id).toList(),
        );
        featuresList.add(extractNdtFeatures(
          waveform,
          _kSampleRateHz,
          baselineM:    distM,
          impactorNode: iNode,
        ));
      } else {
        // Synthesise from travel-time residual.
        final distM2      = tapper.position.distanceTo(node.position);
        final vMs = distM2 > 0 ? distM2 / (measuredMs / 1000.0) : wavespeedMps;
        final inferredFdom  = (vMs / 340.0 * 1500.0).clamp(200.0, 8000.0);
        final inferredAlpha = vMs >= 3500 ? 0.18 : vMs >= 3000 ? 0.11 : 0.05;
        // Determine one-hot slot from the tapper's rank in the triangle.
        final iNode = impactorNodeFromIds(
          cycle.tapperId,
          quadrant.nodes.map((n) => n.id).toList(),
        );
        featuresList.add(NdtFeatures(
          tofMs:           measuredMs,
          waveSpeedMps:    vMs,
          peakAmplitude:   0.5,
          fDomHz:          inferredFdom,
          fCentHz:         inferredFdom * 0.85,
          decayRateNpMs:   inferredAlpha,
          signalEnergy:    0.01,
          bandLow:         vMs < 3000 ? 0.6 : 0.2,
          bandMid:         0.2,
          bandHigh:        vMs >= 3500 ? 0.5 : 0.15,
          bandVhf:         0.05,
          bandRatio:       vMs < 3000 ? 3.0 : 0.4,
          zeroCrossingRate: inferredAlpha * 10,
          rmsAmplitude:    0.35,
          crestFactor:     1.4,
          skewness:        0.0,
          kurtosis:        0.0,
          baselineM:       distM2,
          normTof:         distM2 > 0.01 ? measuredMs / distM2 : 0.0,
          attenuationDb:   -6.0,
          meanWaveSpeed:   vMs,
          stdWaveSpeed:    0.0,
          meanDecayRate:   inferredAlpha,
          impactorNode:    iNode,
          sampleRateHz:    _kSampleRateHz,
        ));
      }
    }

    if (featuresList.isEmpty) { return null; }

    // Average the feature vectors across paths, then classify once.
    // This gives a single per-quadrant label rather than per-path noise.
    double avg(double Function(NdtFeatures) f) =>
        featuresList.map(f).reduce((a, b) => a + b) / featuresList.length;

    // Determine the impactor node slot for the whole quadrant.
    final iNode = impactorNodeFromIds(
      cycle.tapperId,
      quadrant.nodes.map((n) => n.id).toList(),
    );

    final avgFeatures = NdtFeatures(
      tofMs:           avg((f) => f.tofMs),
      waveSpeedMps:    avg((f) => f.waveSpeedMps),
      peakAmplitude:   avg((f) => f.peakAmplitude),
      fDomHz:          avg((f) => f.fDomHz),
      fCentHz:         avg((f) => f.fCentHz),
      decayRateNpMs:   avg((f) => f.decayRateNpMs),
      signalEnergy:    avg((f) => f.signalEnergy),
      bandLow:         avg((f) => f.bandLow),
      bandMid:         avg((f) => f.bandMid),
      bandHigh:        avg((f) => f.bandHigh),
      bandVhf:         avg((f) => f.bandVhf),
      bandRatio:       avg((f) => f.bandRatio),
      zeroCrossingRate: avg((f) => f.zeroCrossingRate),
      rmsAmplitude:    avg((f) => f.rmsAmplitude),
      crestFactor:     avg((f) => f.crestFactor),
      skewness:        avg((f) => f.skewness),
      kurtosis:        avg((f) => f.kurtosis),
      baselineM:       avg((f) => f.baselineM),
      normTof:         avg((f) => f.normTof),
      attenuationDb:   avg((f) => f.attenuationDb),
      meanWaveSpeed:   avg((f) => f.meanWaveSpeed),
      stdWaveSpeed:    avg((f) => f.stdWaveSpeed),
      meanDecayRate:   avg((f) => f.meanDecayRate),
      impactorNode:    iNode,
      sampleRateHz:    _kSampleRateHz,
    );

    // Use the async ONNX path when available; synchronous heuristic otherwise.
    final onnx = modelManager.onnxNdtModel;
    if (onnx != null) {
      return await onnx.predictAsync(avgFeatures);
    }
    return modelManager.ndtModel.predict(avgFeatures);
  }

  // Cache of raw normalised piezo waveforms, keyed by listener nodeId.
  // Populated when a TapData message arrives (firmware sends waveform as
  // 'piezo' int16 array in tap_data JSON). Cleared on each new tap cycle.
  final _cachedPiezoWaveforms = <int, List<double>>{};

  // =========================================================================
  // Legacy path — DetectionEvent / RawDetectionSample (sim + old firmware)
  // =========================================================================

  void _handleRawDetection(RawDetectionSample sample) {
    final kind         = kindFromFeatures(sample.features);
    final personResult = modelManager.personModel.predict(sample.features);
    _handleDetection(DetectionEvent(
      nodeId:      sample.nodeId,
      timestampMs: sample.timestampMs,
      kind:        kind,
      amplitude:   sample.features.peakAmplitude,
      confidence:  personResult.probability,
    ));
  }

  void _handleDetection(DetectionEvent event) {
    if (event.kind == EventKind.tapPulse) { return; }
    recentEvents.addFirst(event);
    while (recentEvents.length > 100) { recentEvents.removeLast(); }

    const windowMs = 400.0;
    final recent = recentEvents
        .where((e) => e.timestampMs >= event.timestampMs - windowMs)
        .toList();
    final clusters = clusterEvents(recent);
    if (clusters.isEmpty) { return; }

    // Quadrant selection on the cluster.
    final quadrant = selectTriangleFromCluster(
      cluster:  clusters.first,
      allNodes: nodes,
    );

    TdoaResult? result;
    if (quadrant != null) {
      activeQuadrant = quadrant;
      // Build filtered cluster with only the 3 selected nodes.
      final filtered = clusters.first
          .where((e) => quadrant.nodes.any((n) => n.id == e.nodeId))
          .toList();
      result = solveTdoa(
        cluster:       filtered,
        nodes:         nodes,
        grid:          grid,
        wavespeedMps:  wavespeedMps,
      );
    } else {
      result = solveTdoa(
        cluster:      clusters.first,
        nodes:        nodes,
        grid:         grid,
        wavespeedMps: wavespeedMps,
      );
    }

    if (result != null) {
      lastFix = result;
      applyTdoaResult(grid, result);
      fuseVoxelGrid(grid);
      _recomputeNavVector();
      final kindLabel = switch (clusters.first.first.kind) {
        EventKind.scream   => 'scream',
        EventKind.metallic => 'metallic',
        _                  => 'knock',
      };
      final qLabel = quadrant != null
          ? 'Q[${quadrant.nodes.map((n) => n.id).join(',')}]'
          : 'all';
      _log('$kindLabel $qLabel → '
          'conf ${(result.confidence * 100).toStringAsFixed(0)}%');
    }
  }

  // =========================================================================
  // FTM / MDS
  // =========================================================================

  void _handleFtmMeasurement(FtmMeasurement m) {
    final key = m.initiatorId < m.responderId
        ? (m.initiatorId, m.responderId)
        : (m.responderId, m.initiatorId);

    _ftmDistances.putIfAbsent(key, () => [])
        .add(ftmBurstDistance(FtmBurst(m.t1Ns, m.t2Ns, m.t3Ns, m.t4Ns)));

    if (nodes.length < 2) { return; }
    if (_ftmDistances.length < nodes.length - 1) { return; }

    final measurements = _ftmDistances.entries.map((e) {
      final avg = e.value.reduce((a, b) => a + b) / e.value.length;
      return NodeDistanceMeasurement(e.key.$1, e.key.$2, avg);
    }).toList();

    final coords = mdsCoordinates(measurements);
    if (coords == null) { return; }

    var updated = 0;
    for (final entry in coords.entries) {
      final node = nodes[entry.key];
      if (node != null) {
        node.position = entry.value;
        updated++;
      }
    }
    if (updated > 0) {
      _log('FTM/MDS updated $updated node positions.');
      _notify();
    }
  }

  // =========================================================================
  // RSSI rescuer trilateration
  // =========================================================================

  void _handleRescuerRssi(RescuerRssiSample sample) {
    _rescuerSamples[sample.nodeId] = sample;
    final cutoff = DateTime.now().subtract(const Duration(seconds: 4));
    _rescuerSamples.removeWhere((_, s) => s.receivedAt.isBefore(cutoff));
    if (_rescuerSamples.isEmpty || nodes.isEmpty) { return; }

    final xs = nodes.values.map((n) => n.position.x);
    final ys = nodes.values.map((n) => n.position.y);
    final zs = nodes.values.map((n) => n.position.z);
    final cx = xs.reduce((a, b) => a + b) / nodes.length;
    final cy = ys.reduce((a, b) => a + b) / nodes.length;
    final cz = zs.reduce((a, b) => a + b) / nodes.length;

    final fix = solveRescuerPosition(
      latestByNode:      _rescuerSamples,
      nodes:             nodes,
      searchOrigin:      Vec3(cx, cy, cz),
      searchExtent:      const Vec3(16, 16, 6),
      txPowerAt1mDbm:    rssiTxPowerAt1m,
      pathLossExponent:  rssiPathLossExponent,
    );
    if (fix != null) {
      rescuerFix = fix;
      _recomputeNavVector();
    }
  }

  // =========================================================================
  // Navigation vector
  // =========================================================================

  void _recomputeNavVector() {
    final fix    = lastFix;
    final rescuer = rescuerFix;
    if (fix == null || rescuer == null) { return; }
    navigationVector = _navSmoother.update(
      userPos:       rescuer.position,
      source:        fix.position,
      userHeadingRad: userHeadingRad,
    );
  }

  // =========================================================================
  // Helpers
  // =========================================================================

  Vec3 _gridCenter() => Vec3(
    grid.origin.x + grid.nx * grid.cellSize / 2,
    grid.origin.y + grid.ny * grid.cellSize / 2,
    grid.origin.z + grid.nz * grid.cellSize / 2,
  );

  void _log(String line) {
    logLines.addFirst(
        '${DateTime.now().toIso8601String().substring(11, 19)}  $line');
    while (logLines.length > _maxLog) { logLines.removeLast(); }
  }

  void _notify() {
    if (!_onChange.isClosed) { _onChange.add(null); }
  }

  void dispose() {
    _sub?.cancel();
    _statusSub?.cancel();
    _syncSub?.cancel();
    _source?.stop();
    _frameSynchronizer.dispose();
    modelManager.dispose();
    _onChange.close();
  }
}
