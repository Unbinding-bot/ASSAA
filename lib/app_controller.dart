import 'dart:async';
import 'dart:collection';

import 'dsp/transient_detector.dart';
import 'math3d.dart';
import 'ml/material_model.dart';
import 'ml/model_manager.dart';
import 'models/event.dart';
import 'models/node.dart';
import 'models/rescuer.dart';
import 'models/voxel.dart';
import 'localization/fusion.dart';
import 'localization/rssi_localization.dart';
import 'localization/tdoa_solver.dart';
import 'localization/tomography.dart';
import 'services/data_source.dart';
import 'services/esp32_connection.dart';
import 'services/simulation_service.dart';

enum ConnectionMode { none, sim, live }

/// Owns the node table, voxel grid, and event log, and runs the
/// localization pipeline every time a new message arrives from whichever
/// DataSource is active. This is the one place Sim and Live modes
/// actually converge -- everything below `_handleMessage` doesn't know
/// or care which one is running.
class AppController {
  AppController() {
    grid = VoxelGrid(
      nx: 10,
      ny: 10,
      nz: 5,
      origin: const Vec3(-5, -5, -2.5),
      cellSize: 1.0,
    );
    // Fire-and-forget: tries to load trained TFLite models, falls back to
    // heuristics if they're not there yet (expected until the NIP
    // collaboration produces real ones). Logged either way.
    // ignore: unawaited_futures
    modelManager.initialize().then((_) {
      _log('Person model: ${modelManager.personModelIsTrained ? "trained" : "heuristic"}. '
          'Material model: ${modelManager.materialModelIsTrained ? "trained" : "heuristic"}.');
      _notify();
    });
  }

  final modelManager = ModelManager();
  ConnectionStatus connectionStatus = ConnectionStatus.disconnected;

  final nodes = <int, SensorNode>{};
  late final VoxelGrid grid;

  final recentEvents = Queue<DetectionEvent>();
  final recentTapCycles = Queue<TapCycle>();
  final logLines = Queue<String>();
  static const _maxLog = 200;

  TdoaResult? lastFix;
  RescuerFix? rescuerFix;
  final _rescuerSamples = <int, RescuerRssiSample>{}; // latest per node
  double wavespeedMps = 300.0; // live-tunable; rubble propagation speed
  double rssiTxPowerAt1m = -40.0; // live-tunable RF calibration
  double rssiPathLossExponent = 3.0; // live-tunable RF calibration
  ConnectionMode mode = ConnectionMode.none;

  DataSource? _source;
  StreamSubscription? _sub;
  StreamSubscription? _statusSub;

  final _onChange = StreamController<void>.broadcast();
  Stream<void> get onChange => _onChange.stream;

  Future<void> connectSim() async {
    await _swapSource(SimulationService());
    mode = ConnectionMode.sim;
    _log('Simulation started.');
    _notify();
  }

  Future<void> connectLive(Uri gatewayUri) async {
    await _swapSource(Esp32GatewayConnection(gatewayUri));
    mode = ConnectionMode.live;
    _log('Connecting to gateway at $gatewayUri ...');
    _notify();
  }

  Future<void> _swapSource(DataSource next) async {
    _sub?.cancel();
    _statusSub?.cancel();
    _source?.stop();
    nodes.clear();
    grid.resetAll();
    recentEvents.clear();
    recentTapCycles.clear();
    lastFix = null;
    rescuerFix = null;
    _rescuerSamples.clear();
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
    await next.start();
  }

  void disconnect() {
    _sub?.cancel();
    _statusSub?.cancel();
    _source?.stop();
    _source = null;
    mode = ConnectionMode.none;
    connectionStatus = ConnectionStatus.disconnected;
    _log('Disconnected.');
    _notify();
  }

  void setWavespeed(double mps) {
    wavespeedMps = mps;
    _notify();
  }

  void setRssiCalibration({double? txPowerAt1m, double? pathLossExponent}) {
    if (txPowerAt1m != null) rssiTxPowerAt1m = txPowerAt1m;
    if (pathLossExponent != null) rssiPathLossExponent = pathLossExponent;
    _notify();
  }

  void _handleMessage(Object msg) {
    if (msg is SensorNode) {
      nodes[msg.id] = msg;
    } else if (msg is TapCycle) {
      _handleTapCycle(msg);
    } else if (msg is RawDetectionSample) {
      _handleRawDetection(msg);
    } else if (msg is DetectionEvent) {
      _handleDetection(msg);
    } else if (msg is RescuerRssiSample) {
      _handleRescuerRssi(msg);
    }
    _notify();
  }

  /// Runs the person-presence model on firmware-extracted features (the
  /// preferred live path) or simulator-synthesized ones, then hands the
  /// result into the same detection pipeline a pre-classified "detection"
  /// message would use.
  void _handleRawDetection(RawDetectionSample sample) {
    final kind = kindFromFeatures(sample.features);
    final personResult = modelManager.personModel.predict(sample.features);
    _handleDetection(DetectionEvent(
      nodeId: sample.nodeId,
      timestampMs: sample.timestampMs,
      kind: kind,
      amplitude: sample.features.peakAmplitude,
      confidence: personResult.probability,
    ));
  }

  void _handleTapCycle(TapCycle cycle) {
    recentTapCycles.addFirst(cycle);
    while (recentTapCycles.length > 30) {
      recentTapCycles.removeLast();
    }
    backProjectTapCycle(
      cycle: cycle,
      nodes: nodes,
      grid: grid,
      baselineWavespeedMps: wavespeedMps,
    );
    fuseVoxelGrid(grid);
    _classifyMaterials(cycle);
    _log('Tap cycle from node ${cycle.tapperId}: '
        '${cycle.arrivalMs.length} arrivals.');
  }

  /// Runs the material model on each tapper->listener path from this
  /// cycle. Mirrors the expected/residual travel-time calculation in
  /// tomography.dart's backProjectTapCycle deliberately kept separate --
  /// this is a diagnostic/logging concern, not the numeric localization
  /// pipeline, so the two stay decoupled even though the math overlaps.
  void _classifyMaterials(TapCycle cycle) {
    final tapper = nodes[cycle.tapperId];
    if (tapper == null) return;

    cycle.arrivalMs.forEach((listenerId, measuredMs) {
      final listener = nodes[listenerId];
      if (listener == null) return;
      final distM = tapper.position.distanceTo(listener.position);
      if (distM < 0.05) return;

      final expectedMs = (distM / wavespeedMps) * 1000;
      final features = TapFeatures(
        travelTimeMs: measuredMs,
        expectedTravelTimeMs: expectedMs,
        residualMs: measuredMs - expectedMs,
      );
      final result = modelManager.materialModel.predict(features);

      // Only worth surfacing when it's not just "solid concrete, move on".
      if (result.predicted != MaterialType.concrete && result.confidence > 0.4) {
        _log('Node ${cycle.tapperId}->$listenerId path -> '
            '${result.predicted.name} (${(result.confidence * 100).toStringAsFixed(0)}%)');
      }
    });
  }

  void _handleDetection(DetectionEvent event) {
    if (event.kind == EventKind.tapPulse) return; // exclude self-taps
    recentEvents.addFirst(event);
    while (recentEvents.length > 100) {
      recentEvents.removeLast();
    }

    // Re-cluster the recent window and try to solve the most recent
    // cluster. Cheap enough at this event rate and grid size.
    const windowMs = 400.0;
    final recent = recentEvents
        .where((e) => e.timestampMs >= event.timestampMs - windowMs)
        .toList();
    final clusters = clusterEvents(recent);
    if (clusters.isEmpty) return;

    final cluster = clusters.first;
    final result = solveTdoa(
      cluster: cluster,
      nodes: nodes,
      grid: grid,
      wavespeedMps: wavespeedMps,
    );
    if (result != null) {
      lastFix = result;
      applyTdoaResult(grid, result);
      fuseVoxelGrid(grid);
      final kindLabel = cluster.first.kind == EventKind.scream ? 'scream' : 'knock';
      _log('$kindLabel cluster (${cluster.length} nodes) -> '
          'confidence ${(result.confidence * 100).toStringAsFixed(0)}%');
    }
  }

  void _handleRescuerRssi(RescuerRssiSample sample) {
    _rescuerSamples[sample.nodeId] = sample;

    // Drop stale readings so a fix doesn't linger on nodes that stopped
    // hearing the phone a while ago (rescuer moved on).
    final cutoff = DateTime.now().subtract(const Duration(seconds: 4));
    _rescuerSamples.removeWhere((_, s) => s.receivedAt.isBefore(cutoff));
    if (_rescuerSamples.isEmpty) return;

    // Search box centered on the node array's own bounding region, with
    // enough margin that a rescuer standing just outside the array still
    // resolves instead of getting clipped to the grid edge.
    if (nodes.isEmpty) return;
    final xs = nodes.values.map((n) => n.position.x);
    final ys = nodes.values.map((n) => n.position.y);
    final zs = nodes.values.map((n) => n.position.z);
    final cx = (xs.reduce((a, b) => a + b)) / nodes.length;
    final cy = (ys.reduce((a, b) => a + b)) / nodes.length;
    final cz = (zs.reduce((a, b) => a + b)) / nodes.length;

    final fix = solveRescuerPosition(
      latestByNode: _rescuerSamples,
      nodes: nodes,
      searchOrigin: Vec3(cx, cy, cz),
      searchExtent: const Vec3(16, 16, 6),
      txPowerAt1mDbm: rssiTxPowerAt1m,
      pathLossExponent: rssiPathLossExponent,
    );
    if (fix != null) {
      rescuerFix = fix;
    }
  }

  void _log(String line) {
    logLines.addFirst('${DateTime.now().toIso8601String().substring(11, 19)}  $line');
    while (logLines.length > _maxLog) {
      logLines.removeLast();
    }
  }

  void _notify() {
    if (!_onChange.isClosed) _onChange.add(null);
  }

  void dispose() {
    _sub?.cancel();
    _statusSub?.cancel();
    _source?.stop();
    modelManager.dispose();
    _onChange.close();
  }
}