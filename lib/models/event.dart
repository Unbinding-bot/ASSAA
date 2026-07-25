/// What kind of transient a node reported.
///
/// NOTE: we no longer classify a continuous breathing/heartbeat band.
/// Detections are now purely transient: a knock (deliberate, rhythmic,
/// low-frequency impulse) or a scream (longer, higher-frequency, human
/// vocal energy). `tapPulse` is the system's own active-mode impactor
/// firing, which must be excluded from passive localization.
enum EventKind { knock, scream, tapPulse, unknown }

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