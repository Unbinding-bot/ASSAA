import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models/event.dart';

/// Matches the binary `AudioPacket` struct the ESP32-C3 firmware broadcasts
/// over UDP (firmware code §3.2, `streamAudioFrame()`):
///
///   struct AudioPacket {
///     uint8_t  nodeId;          // 1 byte
///     uint32_t timestampUS;     // 4 bytes, little-endian
///     int16_t  samples[128];    // 256 bytes, little-endian PCM
///   };                          // total: 261 bytes
///
/// Packets are broadcast to 255.255.255.255:9000 (UDP, port defined in
/// firmware). The receiver binds 0.0.0.0:9000 to catch all broadcasts on
/// whatever Wi-Fi interface the phone uses.

const _kPacketBytes = 261; // 1 + 4 + 128*2
const _kSamplesPerFrame = 128;
const _kUdpPort = 9000;

/// One received, decoded audio frame from a node.
class AudioFrame {
  final int nodeId;
  final int timestampUs; // hardware µs clock from the ESP32
  final List<double> samples; // normalised –1.0 … +1.0 (from int16)
  final DateTime receivedAt;

  AudioFrame({
    required this.nodeId,
    required this.timestampUs,
    required this.samples,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  static const double _kInt16Max = 32768.0;

  /// Parse raw UDP payload. Returns null if the packet is the wrong size
  /// or has an obviously invalid node ID (0xFF = broadcast, skip it).
  static AudioFrame? fromBytes(Uint8List bytes) {
    if (bytes.length < _kPacketBytes) return null;

    final bd = bytes.buffer.asByteData(bytes.offsetInBytes);
    final nodeId = bd.getUint8(0);
    if (nodeId == 0xFF) return null;

    final timestampUs = bd.getUint32(1, Endian.little);

    final samples = List<double>.filled(_kSamplesPerFrame, 0.0);
    for (var i = 0; i < _kSamplesPerFrame; i++) {
      final raw = bd.getInt16(5 + i * 2, Endian.little);
      samples[i] = raw / _kInt16Max;
    }

    return AudioFrame(
      nodeId: nodeId,
      timestampUs: timestampUs,
      samples: samples,
    );
  }
}

// =============================================================================
// Frame synchronizer
// =============================================================================

/// Accumulates incoming [AudioFrame]s from multiple nodes into a
/// time-aligned window [SyncedFrameSet], then emits each set once the
/// window closes so the DSP pipeline (IIR → GCC-PHAT → LM solver) can
/// run on truly simultaneous captures.
///
/// Alignment strategy:
///   - Frames are bucketed by their hardware timestamp, quantised to a
///     [windowUs] grid (default 16 ms, matching one 256-sample frame at
///     16 kHz).
///   - A window is flushed when it has been open longer than [flushAfterMs]
///     wall-clock time, regardless of how many nodes contributed — this
///     ensures the pipeline never stalls waiting for a dropped packet.
///   - Network jitter is compensated by referencing the hardware µs
///     timestamp rather than the reception wall-clock.

class SyncedFrameSet {
  /// nodeId → audio frame for this time window.
  final Map<int, AudioFrame> frames;

  /// Nominal hardware timestamp of this window's bucket (µs).
  final int windowTimestampUs;

  const SyncedFrameSet({
    required this.frames,
    required this.windowTimestampUs,
  });
}

class AudioFrameSynchronizer {
  AudioFrameSynchronizer({
    this.windowUs = 16000, // 16 ms — one 256-sample frame @ 16kHz
    this.flushAfterMs = 40, // wall-clock flush deadline
  });

  final int windowUs;
  final int flushAfterMs;

  // bucket key → { nodeId → frame }
  final _buckets = <int, Map<int, AudioFrame>>{};
  final _bucketArrival = <int, DateTime>{};

  final _controller = StreamController<SyncedFrameSet>.broadcast();
  Stream<SyncedFrameSet> get sets => _controller.stream;

  Timer? _flushTimer;

  void add(AudioFrame frame) {
    final bucket = (frame.timestampUs ~/ windowUs) * windowUs;
    _buckets.putIfAbsent(bucket, () => {});
    _bucketArrival.putIfAbsent(bucket, () => DateTime.now());
    _buckets[bucket]![frame.nodeId] = frame;

    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(Duration(milliseconds: flushAfterMs), _flushReady);
  }

  void _flushReady() {
    _flushTimer = null;
    final now = DateTime.now();
    final toFlush = <int>[];

    for (final bucket in _buckets.keys) {
      final age = now.difference(_bucketArrival[bucket]!).inMilliseconds;
      if (age >= flushAfterMs) toFlush.add(bucket);
    }

    for (final bucket in toFlush) {
      final frames = _buckets.remove(bucket)!;
      _bucketArrival.remove(bucket);
      if (frames.length >= 2) {
        // Need at least 2 nodes to compute a cross-correlation.
        _controller.add(SyncedFrameSet(
          frames: frames,
          windowTimestampUs: bucket,
        ));
      }
    }

    if (_buckets.isNotEmpty) _scheduleFlush();
  }

  void dispose() {
    _flushTimer?.cancel();
    _controller.close();
  }
}

// =============================================================================
// UDP receiver service
// =============================================================================

/// Binds to UDP port [_kUdpPort] and streams decoded [AudioFrame]s.
/// Works on Android/iOS (dart:io RawDatagramSocket) and desktop.
/// Will not work on web (no dart:io) — live mode is a field tool concern,
/// not a web concern, so that's fine.
class UdpAudioReceiver {
  UdpAudioReceiver({this.port = _kUdpPort});
  final int port;

  RawDatagramSocket? _socket;
  final _controller = StreamController<AudioFrame>.broadcast();
  Stream<AudioFrame> get frames => _controller.stream;

  bool _running = false;

  Future<void> start() async {
    if (_running) return;
    _running = true;

    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port,
        reuseAddress: true, reusePort: false);
    _socket!.broadcastEnabled = true;

    _socket!.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      final dg = _socket!.receive();
      if (dg == null) return;

      final frame = AudioFrame.fromBytes(dg.data);
      if (frame != null && !_controller.isClosed) {
        _controller.add(frame);
      }
    });
  }

  void stop() {
    _running = false;
    _socket?.close();
    _socket = null;
    if (!_controller.isClosed) _controller.close();
  }
}

// =============================================================================
// AccelFrame  (Mode 1: MPU-6050 tap-capture data, doc §3.1)
// =============================================================================

/// Binary layout of a Mode-1 `TAP_DATA` WebSocket JSON message decoded
/// into a typed Dart object.  The firmware sends JSON (not binary) for
/// tap data, so this is a JSON-parsed value object, not a byte decoder.
class AccelFrame {
  final int nodeId;
  final int piezoT0Us; // hardware trigger timestamp
  final List<int> rawSamplesZ; // 150 × int16 Z-axis acceleration

  const AccelFrame({
    required this.nodeId,
    required this.piezoT0Us,
    required this.rawSamplesZ,
  });

  factory AccelFrame.fromJson(int nodeId, Map<String, dynamic> json) {
    final samples = (json['samples'] as List).cast<int>();
    return AccelFrame(
      nodeId: nodeId,
      piezoT0Us: (json['piezo_t0'] as num).toInt(),
      rawSamplesZ: samples,
    );
  }

  /// Convert to normalised doubles (±1.0 range, same as AudioFrame)
  /// using the MPU-6050's ±2g sensitivity: 16384 LSB/g.
  List<double> get normalised =>
      rawSamplesZ.map((s) => s / 16384.0).toList();

  /// Infer a TapCycle arrival time for tomography: the moment the
  /// first significant Z deflection arrives, relative to [piezoT0Us].
  /// Uses a threshold of 10% of the peak deflection so small pre-trigger
  /// noise doesn't skew the reading.
  double? travelTimeMs() {
    final samples = normalised;
    if (samples.isEmpty) return null;
    final peak = samples.map((v) => v.abs()).reduce((a, b) => a > b ? a : b);
    final threshold = peak * 0.10;

    const sampleIntervalUs = 2000; // 500 Hz → 2 ms per sample
    for (var i = 0; i < samples.length; i++) {
      if (samples[i].abs() >= threshold) {
        final arrivalUs = i * sampleIntervalUs;
        return arrivalUs / 1000.0; // µs → ms
      }
    }
    return null;
  }

  /// Synthesise a [TapCycle] entry for the tomography pipeline.
  /// [tapperId] is the node that actuated the servo.
  TapCycle toTapCycle(int tapperId) {
    final ms = travelTimeMs();
    return TapCycle(
      tapperId: tapperId,
      arrivalMs: ms != null ? {nodeId: ms} : {},
      firedAt: DateTime.now(),
    );
  }
}
