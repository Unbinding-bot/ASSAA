import 'dart:async';

/// Lifecycle of the underlying connection. Sim mode has no real
/// connection concerns and just reports `connected` once started; Live
/// mode (see esp32_connection.dart) reflects actual WebSocket/heartbeat
/// state, including automatic reconnect attempts.
enum ConnectionStatus { disconnected, connecting, connected, reconnecting, error }

/// Everything downstream (DSP, TDOA, tomography, UI) consumes this stream
/// and doesn't care whether it came from the simulator or a real gateway
/// WebSocket. Swapping Sim for Live is just swapping which DataSource
/// implementation feeds the same StreamController.
abstract class DataSource {
  Stream<Object> get messages; // emits SensorNode | DetectionEvent | TapCycle | RawDetectionSample | RescuerRssiSample
  Stream<ConnectionStatus> get status =>
      Stream.value(ConnectionStatus.connected); // default: sim doesn't need real status tracking
  Future<void> start();
  void stop();
}

/// ---------------------------------------------------------------------
/// LIVE PROTOCOL (for when the ESP32 gateway firmware exists)
/// ---------------------------------------------------------------------
/// The gateway is expected to expose a WebSocket at ws://<gateway-ip>/ws
/// and send newline-free JSON text frames, one message per frame:
///
///   {"type":"telemetry","node":2,"battery":87,"rssi":-52,
///    "x":1.2,"y":0.4,"z":-0.3,"role":"listener"}
///
///   {"type":"tap","tapper":3,"t0":123456}
///     -- announces a tap cycle firing; t0 is the gateway's local clock
///        in ms, used as the reference all subsequent arrival timestamps
///        in this cycle are relative to.
///
///   {"type":"arrival","node":5,"tapper":3,"ms":6.8}
///     -- listener node 5's measured travel time (ms) for the most
///        recent tap cycle from node 3.
///
///   {"type":"detection","node":4,"kind":"knock","ms":812.0,
///    "amplitude":0.71,"confidence":0.9}
///     -- a passive transient the FIRMWARE has already classified. Kept
///        for early bring-up before feature extraction exists onboard.
///
///   {"type":"detection_raw","node":4,"ms":812.0,"durationMs":95,
///    "lowBand":0.6,"midBand":0.1,"vocalBand":0.05,"centroidHz":80,
///    "zcr":12.5,"peakAmp":0.71}
///     -- PREFERRED: the firmware extracts cheap features (see
///        ml/feature_vector.dart) but leaves classification to the
///        phone's person-presence model, since that's the part meant to
///        improve over time without reflashing firmware.
///
///   {"type":"rescuer_rssi","node":6,"dbm":-58}
///     -- node 6 passively sniffed the phone's WiFi frames (promiscuous
///        mode, no association needed) at this signal strength. Several
///        nodes reporting this gives the app enough anchors to trilaterate
///        the rescuer's own position relative to the array -- the "you are
///        here" dot. This is the opposite direction of the usual RSSI
///        story (nodes measuring the phone, not the phone scanning for
///        nodes), which is what makes it work without any WiFi-scanning
///        permissions or platform plugin on the phone side.
///
///   {"type":"pong","t":123456}
///     -- reply to an app-level heartbeat ping (see below). Used only to
///        confirm the connection is still alive; never reaches the UI.
///
/// Deliberately NOT streaming raw waveforms over the mesh -- ESP-NOW
/// bandwidth through multi-hop rubble is tight, so feature extraction (or
/// full classification, in the fallback "detection" case) happens
/// onboard each node and only a small result is sent.
///
/// OUTGOING (phone -> gateway), sent as the same JSON-text-frame format:
///
///   {"type":"ping","t":123456}
///     -- app-level heartbeat, sent periodically by
///        services/esp32_connection.dart. Expects a "pong" back within a
///        timeout or the connection is considered dead and reconnected.
/// ---------------------------------------------------------------------