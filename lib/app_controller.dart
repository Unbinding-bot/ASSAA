import 'dart:async';
import 'dart:collection';

import 'math3d.dart';
import 'models/event.dart';
import 'models/node.dart';
import 'models/voxel.dart';
import 'localization/fusion.dart';
import 'localization/tdoa_solver.dart';
import 'localization/tomography.dart';
import 'services/data_source.dart';
import 'services/gateway_service.dart';
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
  }

  final nodes = <int, SensorNode>{};
  late final VoxelGrid grid;

  final recentEvents = Queue<DetectionEvent>();
  final recentTapCycles = Queue<TapCycle>();
  final logLines = Queue<String>();
  static const _maxLog = 200;

  TdoaResult? lastFix;
  double wavespeedMps = 300.0; // live-tunable; rubble propagation speed
  ConnectionMode mode = ConnectionMode.none;

  DataSource? _source;
  StreamSubscription? _sub;

  final _onChange = StreamController<void>.broadcast();
  Stream<void> get onChange => _onChange.stream;

  Future<void> connectSim() async {
    await _swapSource(SimulationService());
    mode = ConnectionMode.sim;
    _log('Simulation started.');
    _notify();
  }

  Future<void> connectLive(Uri gatewayUri) async {
    await _swapSource(GatewayService(gatewayUri));
    mode = ConnectionMode.live;
    _log('Connecting to gateway at $gatewayUri ...');
    _notify();
  }

  Future<void> _swapSource(DataSource next) async {
    _sub?.cancel();
    _source?.stop();
    nodes.clear();
    grid.resetAll();
    recentEvents.clear();
    recentTapCycles.clear();
    lastFix = null;

    _source = next;
    _sub = next.messages.listen(_handleMessage, onError: (e) {
      _log('Data source error: $e');
      _notify();
    });
    await next.start();
  }

  void disconnect() {
    _sub?.cancel();
    _source?.stop();
    _source = null;
    mode = ConnectionMode.none;
    _log('Disconnected.');
    _notify();
  }

  void setWavespeed(double mps) {
    wavespeedMps = mps;
    _notify();
  }

  void _handleMessage(Object msg) {
    if (msg is SensorNode) {
      nodes[msg.id] = msg;
    } else if (msg is TapCycle) {
      _handleTapCycle(msg);
    } else if (msg is DetectionEvent) {
      _handleDetection(msg);
    }
    _notify();
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
    _log('Tap cycle from node ${cycle.tapperId}: '
        '${cycle.arrivalMs.length} arrivals.');
  }

  void _handleDetection(DetectionEvent event) {
    if (event.kind == EventKind.tapPulse) return; // exclude self-taps
    recentEvents.addFirst(event);
    while (recentEvents.length > 100) {
      recentEvents.removeLast();
    }

    // Re-cluster the recent window and try to solve the most recent
    // cluster. Cheap enough at this event rate and grid size.
    final windowMs = 400.0;
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
    _source?.stop();
    _onChange.close();
  }
}