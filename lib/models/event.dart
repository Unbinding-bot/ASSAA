import '../ml/feature_vector.dart';

// =============================================================================
// EventKind
// =============================================================================

/// What kind of transient a node reported.
/// `tapPulse` is the system's own active-mode impactor firing, which must
/// be excluded from passive localization.
enum EventKind { knock, scream, metallic, tapPulse, unknown }

// =============================================================================
// Passive-mode messages
// =============================================================================

class DetectionEvent {
  final int nodeId;
  final double timestampMs; // relative to the most recent T=0 sync broadcast
  final EventKind kind;
  final double amplitude; // 0-1 normalized
  final double confidence; // classifier confidence 0-1

  const DetectionEvent({
    required this.nodeId,
    required this.timestampMs,
    required this.kind,
    required this.amplitude,
    this.confidence = 1.0,
  });
}

/// A passive transient reported as raw extracted features rather than a
/// pre-classified kind. Preferred live protocol: firmware extracts cheap
/// features onboard but leaves classification to the phone's model.
class RawDetectionSample {
  final int nodeId;
  final double timestampMs;
  final SignalFeatures features;

  const RawDetectionSample({
    required this.nodeId,
    required this.timestampMs,
    required this.features,
  });
}

// =============================================================================
// Active-mode messages  (Mode 1 — MPU-6050 tap capture)
// =============================================================================

/// One active-mode tap cycle: the tapper fired, and some subset of
/// listener nodes reported a travel time back.
class TapCycle {
  final int tapperId;
  final Map<int, double> arrivalMs; // nodeId -> measured travel time (ms)
  final DateTime firedAt;

  const TapCycle({
    required this.tapperId,
    required this.arrivalMs,
    required this.firedAt,
  });
}

/// Raw MPU-6050 tap-capture data streamed from a single ESP32-C3 node
/// (firmware `TAP_DATA` WebSocket message, doc §3.1).
///
/// The gateway relays this JSON payload verbatim; AppController assembles
/// per-tapper [TapCycle]s by collating arrivals across nodes.
class TapData {
  /// Node that sent this accel frame (set by gateway from connection context).
  final int nodeId;

  /// Hardware µs timestamp of the piezo trigger interrupt on the sender.
  final int piezoT0Us;

  /// 150 raw Z-axis acceleration samples at 500 Hz (int16, ±2g full scale).
  final List<int> samplesZ;

  const TapData({
    required this.nodeId,
    required this.piezoT0Us,
    required this.samplesZ,
  });

  factory TapData.fromJson(int nodeId, Map<String, dynamic> json) {
    return TapData(
      nodeId: nodeId,
      piezoT0Us: (json['piezo_t0'] as num).toInt(),
      samplesZ: (json['samples'] as List).cast<int>(),
    );
  }

  /// Convert raw int16 samples to normalised doubles (±1.0, 16384 LSB/g).
  List<double> get normalisedSamples =>
      samplesZ.map((s) => s / 16384.0).toList();

  /// First-arrival time (ms after piezo trigger) using a 10%-of-peak
  /// threshold — matches AccelFrame.travelTimeMs() in udp_audio_receiver.dart.
  double? firstArrivalMs() {
    final norm = normalisedSamples;
    if (norm.isEmpty) return null;
    final peak = norm.map((v) => v.abs()).reduce((a, b) => a > b ? a : b);
    final thresh = peak * 0.10;
    const intervalUs = 2000; // 500 Hz → 2000 µs per sample
    for (var i = 0; i < norm.length; i++) {
      if (norm[i].abs() >= thresh) return (i * intervalUs) / 1000.0;
    }
    return null;
  }
}

// =============================================================================
// FTM calibration messages
// =============================================================================

/// One Wi-Fi FTM burst result relayed by the gateway.  The firmware runs
/// the FTM initiator role and sends the four timestamps back so the phone
/// can compute the distance (doc §5.1).
class FtmMeasurement {
  final int initiatorId; // node that initiated the FTM exchange
  final int responderId; // node that responded
  final int t1Ns; // frame departure  (initiator, ns)
  final int t2Ns; // frame arrival    (responder, ns)
  final int t3Ns; // ACK departure    (responder, ns)
  final int t4Ns; // ACK arrival      (initiator, ns)

  const FtmMeasurement({
    required this.initiatorId,
    required this.responderId,
    required this.t1Ns,
    required this.t2Ns,
    required this.t3Ns,
    required this.t4Ns,
  });

  factory FtmMeasurement.fromJson(Map<String, dynamic> json) {
    return FtmMeasurement(
      initiatorId: json['initiator'] as int,
      responderId: json['responder'] as int,
      t1Ns: (json['t1'] as num).toInt(),
      t2Ns: (json['t2'] as num).toInt(),
      t3Ns: (json['t3'] as num).toInt(),
      t4Ns: (json['t4'] as num).toInt(),
    );
  }
}

// =============================================================================
// Heartbeat / internal
// =============================================================================

/// Heartbeat reply from the gateway — confirms connection is alive.
/// Never reaches the UI.
class GatewayPong {
  const GatewayPong();
}
