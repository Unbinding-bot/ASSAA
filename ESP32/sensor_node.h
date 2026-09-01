/**
 * sensor_node.h — Sensor node role (Nodes 1–7)
 *
 * Sensor nodes have no WebSocket server and no SoftAP.
 * Their communication stack is:
 *
 *   ┌─────────────────────────────────────────────────────────────┐
 *   │  UPLINK  (sensor → gateway → phone)                         │
 *   │    tap_data, telemetry, ftm results  →  ESP-NOW unicast     │
 *   │                                         to gateway MAC      │
 *   │                                                             │
 *   │  DOWNLINK  (phone → gateway → sensor)                       │
 *   │    commands  ←  ESP-NOW broadcast from gateway              │
 *   │                                                             │
 *   │  PIEZO FRAMES  (sensor → phone, direct, high bandwidth)     │
 *   │    PiezoPacket  →  UDP broadcast 255.255.255.255:9000       │
 *   │    (no gateway involvement — phone receives directly)       │
 *   └─────────────────────────────────────────────────────────────┘
 *
 * ── Boot sequence ─────────────────────────────────────────────────────────────
 *
 *   1. Connect to gateway SoftAP as a Wi-Fi STA client.
 *      This locks the radio to ESPNOW_CHANNEL (6), which is mandatory
 *      before initialising ESP-NOW.
 *   2. Init ESP-NOW, register gateway MAC as unicast peer.
 *   3. Send "hello" broadcast so the gateway auto-registers our MAC.
 *   4. Wait for "gateway_mac" message to confirm two-way link.
 *
 * ── Gateway MAC discovery ─────────────────────────────────────────────────────
 *
 *   The gateway broadcasts {"type":"gateway_mac","mac":"XX:XX:..."} at boot.
 *   Sensor nodes parse this and store the gateway MAC for unicast uplink.
 *   Until the gateway MAC is known, sensors send to the broadcast address
 *   as a fallback — the gateway will still receive it and register the sensor.
 *
 * ── Command handling ──────────────────────────────────────────────────────────
 *
 *   Commands arrive from the gateway over ESP-NOW broadcast. The sensor
 *   node dispatches them the same way the old WebSocket handler did —
 *   SET_MODE_1/2, TRIGGER_TAP with dynamic impactor selection, start_ftm.
 *
 *   Tap sequences: executeTapSequence() / executeListenerCapture() from
 *   impactor.h. These block for 50–350 ms so they are deferred to loop()
 *   via the same pending-flag pattern used before.
 */

#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include "pins.h"
#include "esp_now_mesh.h"
#include "piezo_adc.h"
#include "mpu6050.h"
#include "impactor.h"

// ── Gateway MAC (filled once "gateway_mac" message arrives) ───────────────────
static uint8_t  _gwMacSensor[6]   = {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF};
static bool     _gwMacKnown       = false;

// ── Operating mode ────────────────────────────────────────────────────────────
enum SensorMode { SENSOR_MODE_2_PASSIVE, SENSOR_MODE_1_NDT };
static SensorMode _sensorMode = SENSOR_MODE_2_PASSIVE;

// ── Deferred tap flags (set in ESP-NOW callback, executed in loop) ─────────────
static volatile bool     _sensorTapPending      = false;
static volatile bool     _sensorListenPending   = false;
static volatile uint8_t  _sensorTapperId        = 0;
static volatile uint32_t _sensorListenSyncUs    = 0;

// ── Telemetry ─────────────────────────────────────────────────────────────────
#define SENSOR_TELEMETRY_MS  4000
static uint32_t _lastSensorTelemetryMs = 0;

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Parse a small integer from a JSON string without a JSON library. */
static int _sensorParseJsonInt(const String &json, const char *key) {
  const String search = String("\"") + key + "\"";
  const int ki = json.indexOf(search);
  if (ki < 0) { return -1; }
  const int ci = json.indexOf(':', ki + search.length());
  if (ci < 0) { return -1; }
  return json.substring(ci + 1).toInt();
}

/** Parse a MAC string "XX:XX:XX:XX:XX:XX" into a 6-byte array. */
static bool _parseMac(const String &json, const char *key, uint8_t *out) {
  const String search = String("\"") + key + "\":\"";
  const int start = json.indexOf(search);
  if (start < 0) { return false; }
  const int valStart = start + search.length();
  const int valEnd   = json.indexOf('"', valStart);
  if (valEnd < 0) { return false; }
  const String mac = json.substring(valStart, valEnd);
  return sscanf(mac.c_str(), "%hhx:%hhx:%hhx:%hhx:%hhx:%hhx",
                &out[0], &out[1], &out[2],
                &out[3], &out[4], &out[5]) == 6;
}

// =============================================================================
// Send helpers
// =============================================================================

/**
 * Send a JSON message to the gateway.
 * Uses unicast if gateway MAC is known, broadcast otherwise.
 */
static void _sensorSendToGateway(const String &json) {
  if (_gwMacKnown) {
    espnowSend(_gwMacSensor, json, NODE_ID);
  } else {
    espnowBroadcast(json, NODE_ID);
  }
}

/**
 * Send a telemetry heartbeat to the gateway.
 */
static void _sensorSendTelemetry() {
  const int32_t rssi = WiFi.RSSI();
  String json;
  json.reserve(180);
  json  = "{\"type\":\"telemetry\",\"node\":"; json += NODE_ID;
  json += ",\"battery\":100";
  json += ",\"rssi\":";   json += rssi;
  json += ",\"x\":0,\"y\":0,\"z\":0";
  json += ",\"role\":\"listener\"";
  json += ",\"mode\":\"";
  json += (_sensorMode == SENSOR_MODE_1_NDT) ? "impactor" : "triangulation";
  json += "\",\"ftm\":true}";
  _sensorSendToGateway(json);
}

// =============================================================================
// ESP-NOW command dispatcher
// =============================================================================

static void _sensorOnEspNow(uint8_t srcId, const String &json) {
  // Only accept messages from the gateway (srcId == 0) or broadcasts
  // (srcId set to 0 in gateway's espnowBroadcast calls).
  if (srcId != 0) { return; }

  // ── Gateway MAC announcement ──────────────────────────────────────────────
  if (json.indexOf("gateway_mac") >= 0) {
    if (_parseMac(json, "mac", _gwMacSensor)) {
      _gwMacKnown = true;
      // Register the gateway as a unicast peer now that we have its MAC.
      espnowAddPeer(_gwMacSensor, 0);
      Serial.printf("[Sensor] Gateway MAC registered: "
                    "%02X:%02X:%02X:%02X:%02X:%02X\n",
                    _gwMacSensor[0], _gwMacSensor[1], _gwMacSensor[2],
                    _gwMacSensor[3], _gwMacSensor[4], _gwMacSensor[5]);
    }
    return;
  }

  // ── Mode switches ──────────────────────────────────────────────────────────
  if (json.indexOf("SET_MODE_1") >= 0) {
    if (_sensorMode != SENSOR_MODE_1_NDT) {
      _sensorMode = SENSOR_MODE_1_NDT;
      digitalWrite(PIN_LED, HIGH);
      Serial.println("[Sensor] → Mode 1 (active NDT)");
    }
    return;
  }

  if (json.indexOf("SET_MODE_2") >= 0) {
    if (_sensorMode != SENSOR_MODE_2_PASSIVE) {
      _sensorMode = SENSOR_MODE_2_PASSIVE;
      digitalWrite(PIN_LED, LOW);
      Serial.println("[Sensor] → Mode 2 (passive streaming)");
    }
    return;
  }

  // ── Tap trigger ───────────────────────────────────────────────────────────
  // {"type":"TRIGGER_TAP","tapper":<id>}
  if (json.indexOf("TRIGGER_TAP") >= 0) {
    if (_sensorMode != SENSOR_MODE_1_NDT) {
      Serial.println("[Sensor] TRIGGER_TAP ignored — not in Mode 1");
      return;
    }

    const int tapperId = _sensorParseJsonInt(json, "tapper");

    if (tapperId < 0 || tapperId == NODE_ID) {
      // This node IS the impactor.
      // Flag it for loop() — executeTapSequence() blocks ~350 ms.
      _sensorTapperId   = (uint8_t)(tapperId < 0 ? NODE_ID : tapperId);
      _sensorTapPending = true;
      Serial.printf("[Sensor] This node (%d) is the impactor\n", NODE_ID);
    } else {
      // Another node taps — this node listens.
      // Capture sync timestamp NOW (in callback) for minimum latency.
      _sensorListenSyncUs  = micros();
      _sensorTapperId      = (uint8_t)tapperId;
      _sensorListenPending = true;
      Serial.printf("[Sensor] Node %d is impactor — queuing listener capture\n",
                    tapperId);
    }
    return;
  }

  // ── FTM request ───────────────────────────────────────────────────────────
  // {"type":"start_ftm","peer":"XX:XX:XX:XX:XX:XX","ch":6}
  if (json.indexOf("start_ftm") >= 0) {
    // Parse peer MAC.
    uint8_t peerMac[6];
    if (!_parseMac(json, "peer", peerMac)) {
      Serial.println("[Sensor] start_ftm: no peer MAC");
      return;
    }
    uint8_t channel = ESPNOW_CHANNEL;
    const int chIdx = json.indexOf("\"ch\"");
    if (chIdx >= 0) {
      channel = (uint8_t)json.substring(json.indexOf(':', chIdx) + 1).toInt();
    }

    char macStr[18];
    snprintf(macStr, sizeof(macStr), "%02X:%02X:%02X:%02X:%02X:%02X",
             peerMac[0], peerMac[1], peerMac[2],
             peerMac[3], peerMac[4], peerMac[5]);
    Serial.printf("[Sensor] FTM ranging to %s\n", macStr);

    const float distM = ftmRequestDistance(peerMac, channel);

    // Build reply and send to gateway.
    if (distM < 0) {
      _sensorSendToGateway(
          "{\"type\":\"ftm_error\",\"node\":" + String(NODE_ID) +
          ",\"reason\":\"ranging failed\"}");
      return;
    }

    const uint32_t refT1    = 100000000UL;
    const uint32_t oneWayNs = (uint32_t)(distM / 299792458.0f * 1e9f);
    const uint32_t t2 = refT1 + oneWayNs;
    const uint32_t t3 = t2 + 50000;
    const uint32_t t4 = t3 + oneWayNs;

    String reply;
    reply.reserve(160);
    reply  = "{\"type\":\"ftm\",\"initiator\":"; reply += NODE_ID;
    reply += ",\"responder\":";                  reply += (uint8_t)peerMac[5];
    reply += ",\"t1\":"; reply += refT1;
    reply += ",\"t2\":"; reply += t2;
    reply += ",\"t3\":"; reply += t3;
    reply += ",\"t4\":"; reply += t4;
    reply += ",\"dist_m\":"; reply += distM;
    reply += "}";
    _sensorSendToGateway(reply);
    Serial.printf("[Sensor] FTM result sent: %.3f m\n", distM);
    return;
  }
}

// =============================================================================
// Initialisation
// =============================================================================

/**
 * Initialise the sensor node networking stack.
 *
 * @param apSsid  SSID of the gateway SoftAP to connect to.
 * @param apPass  Password of the gateway SoftAP.
 *
 * Blocks until Wi-Fi association is complete (up to 10 s).
 * If the gateway AP is not found within the timeout, the node retries
 * indefinitely — in a rubble deployment you may power up nodes before
 * the gateway, so persistence is more useful than giving up.
 */
void sensorNodeSetup(const char *apSsid, const char *apPass) {
  // ── 1. Connect to gateway AP (STA mode) ───────────────────────────────────
  // WIFI_STA only — no local AP on sensor nodes.
  WiFi.mode(WIFI_STA);
  WiFi.begin(apSsid, apPass);

  Serial.printf("[Sensor %d] Connecting to gateway AP '%s'", NODE_ID, apSsid);

  uint32_t t0 = millis();
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print('.');
    digitalWrite(PIN_LED, !digitalRead(PIN_LED));  // blink while connecting

    // After 10 s, retry the connection (handles gateway not yet up).
    if (millis() - t0 > 10000) {
      Serial.println("\n[Sensor] Retrying Wi-Fi...");
      WiFi.disconnect();
      delay(1000);
      WiFi.begin(apSsid, apPass);
      t0 = millis();
    }
  }

  digitalWrite(PIN_LED, LOW);
  Serial.printf("\n[Sensor %d] Wi-Fi connected  IP=%s  RSSI=%d dBm\n",
                NODE_ID,
                WiFi.localIP().toString().c_str(),
                WiFi.RSSI());

  // Lock to the AP's channel explicitly (should already be set by association,
  // but being explicit prevents any post-connect channel drift).
  esp_wifi_set_channel(ESPNOW_CHANNEL, WIFI_SECOND_CHAN_NONE);

  // ── 2. ESP-NOW ─────────────────────────────────────────────────────────────
  espnowInit(_sensorOnEspNow);
  espnowAddBroadcastPeer();  // needed to receive gateway broadcasts

  // ── 3. Hello broadcast — lets gateway auto-register this node's MAC ────────
  delay(200);  // let ESP-NOW stack settle
  String hello;
  hello.reserve(80);
  hello  = "{\"type\":\"hello\",\"node\":"; hello += NODE_ID;
  hello += ",\"mode\":\"triangulation\"}";
  espnowBroadcast(hello, NODE_ID);
  Serial.printf("[Sensor %d] Hello sent\n", NODE_ID);

  // ── 4. FTM responder ──────────────────────────────────────────────────────
  wifiEnableFtmResponder();

  Serial.printf("[Sensor %d] Ready  UDP=%d  ESP-NOW ch=%d\n",
                NODE_ID, UDP_AUDIO_PORT, ESPNOW_CHANNEL);
}

// =============================================================================
// Main loop tick — call every loop() iteration
// =============================================================================

void sensorNodeLoop() {
  // ── Deferred impactor tap ─────────────────────────────────────────────────
  if (_sensorTapPending) {
    _sensorTapPending = false;
    // executeTapSequence sends tap_data directly — but we need it to go via
    // ESP-NOW to the gateway instead of WebSocket. We capture the JSON and
    // relay it. impactor.h's _broadcastTapData calls ws.broadcastTXT, so
    // here we use a dummy WebSocketsServer* = nullptr and instead handle
    // the send ourselves via a custom tap capture.
    _sensorExecuteImpactorTap();
  }

  // ── Deferred listener capture ─────────────────────────────────────────────
  if (_sensorListenPending) {
    _sensorListenPending = false;
    _sensorExecuteListenerTap(_sensorTapperId, _sensorListenSyncUs);
  }

  // ── Mode 2: stream piezo frames over UDP (direct to phone) ────────────────
  if (_sensorMode == SENSOR_MODE_2_PASSIVE) {
    // piezoStreamAllChannels() samples all 3 ADC1 channels (GPIO 1/2/3) in
    // round-robin at ~30 kHz/channel and broadcasts 3 PiezoPackets per frame.
    // Falls back to single-channel piezoStreamFrame() on single-piezo nodes.
#if PIEZO_CHANNEL_COUNT >= 3
    piezoStreamAllChannels();
#else
    piezoStreamFrame();
#endif
  }

  // ── Mode 1 idle ───────────────────────────────────────────────────────────
  if (_sensorMode == SENSOR_MODE_1_NDT) {
    delay(1);  // yield without burning CPU
  }

  // ── Telemetry ─────────────────────────────────────────────────────────────
  const uint32_t now = millis();
  if (now - _lastSensorTelemetryMs >= SENSOR_TELEMETRY_MS) {
    _lastSensorTelemetryMs = now;
    _sensorSendTelemetry();
  }
}

// =============================================================================
// Tap capture implementations (ESP-NOW uplink instead of WebSocket)
// =============================================================================

// Shared capture buffers.
static int16_t _sPiezoBuf[PIEZO_TAP_SAMPLES];
static int16_t _sAccelBuf[MPU_SAMPLE_COUNT];

/**
 * Build tap_data JSON and send to gateway over ESP-NOW.
 * Same JSON schema as impactor.h's _broadcastTapData, just different transport.
 */
static void _sensorSendTapData(uint8_t tapperId, uint32_t t0Us,
                                bool includeAccel) {
  // Build the full JSON string then chunk it via espnowSend.
  // Estimated size: 500 piezo × 7 chars + 150 accel × 7 chars + 80 header
  //               = ~4680 impactor, ~3580 listener
  // espnowSend() handles chunking automatically.
  String json;
  json.reserve(includeAccel ? 4800 : 3700);

  json  = "{\"type\":\"tap_data\",\"node\":"; json += NODE_ID;
  json += ",\"tapper\":";   json += tapperId;
  json += ",\"piezo_t0\":"; json += t0Us;
  json += ",\"piezo\":[";
  for (int i = 0; i < PIEZO_TAP_SAMPLES; i++) {
    json += _sPiezoBuf[i];
    if (i < PIEZO_TAP_SAMPLES - 1) { json += ','; }
  }
  json += "],\"accel\":[";
  if (includeAccel) {
    for (int i = 0; i < MPU_SAMPLE_COUNT; i++) {
      json += _sAccelBuf[i];
      if (i < MPU_SAMPLE_COUNT - 1) { json += ','; }
    }
  }
  json += "]}";

  _sensorSendToGateway(json);
  Serial.printf("[Sensor] tap_data sent (%u bytes) tapper=%d T0=%u\n",
                json.length(), tapperId, t0Us);
}

/**
 * Impactor tap sequence — this sensor fires the servo.
 */
static void _sensorExecuteImpactorTap() {
  // Arm interrupt, fire servo, wait for piezo trigger.
  extern volatile uint32_t _piezoT0Us;
  extern volatile bool     _piezoTriggered;

  _piezoT0Us      = 0;
  _piezoTriggered = false;
  attachInterrupt(digitalPinToInterrupt(PIN_PIEZO_ADC), _piezoISR, RISING);

  extern Servo _tapperServo;
  _tapperServo.write(SERVO_STRIKE_DEG);
  const uint32_t strikeUs = micros();

  while (!_piezoTriggered &&
         (micros() - strikeUs) < SERVO_STRIKE_TIMEOUT_US) { /* spin */ }
  detachInterrupt(digitalPinToInterrupt(PIN_PIEZO_ADC));

  if (!_piezoTriggered) {
    _piezoT0Us = strikeUs;
    Serial.println("[Sensor] Piezo timeout — using servo T0");
  }
  _tapperServo.write(SERVO_IDLE_DEG);

  // Capture piezo waveform — all 3 channels if available.
#if PIEZO_CHANNEL_COUNT >= 3
  piezoCaptureTapWaveformAllChannels(_piezoT0Us);
  memcpy(_sPiezoBuf, piezoTapBuffer(0), PIEZO_TAP_SAMPLES * sizeof(int16_t));
#else
  piezoCaptureTapWaveform(_sPiezoBuf, _piezoT0Us);
#endif
  // Capture MPU-6050 (supplemental).
  mpuCaptureSamples(_sAccelBuf, _piezoT0Us);

  // Blink LED.
  digitalWrite(PIN_LED, HIGH); delay(50); digitalWrite(PIN_LED, LOW);

  // Send via ESP-NOW.
  _sensorSendTapData(NODE_ID, _piezoT0Us, /*includeAccel=*/true);
}

/**
 * Listener capture — another node fired the servo, this node records.
 */
static void _sensorExecuteListenerTap(uint8_t tapperId, uint32_t syncUs) {
  // Quick blink.
  for (int i = 0; i < 3; i++) {
    digitalWrite(PIN_LED, HIGH); delay(30);
    digitalWrite(PIN_LED, LOW);  delay(30);
  }

  // Capture piezo waveform starting from syncUs.
#if PIEZO_CHANNEL_COUNT >= 3
  piezoCaptureTapWaveformAllChannels(syncUs);
  memcpy(_sPiezoBuf, piezoTapBuffer(0), PIEZO_TAP_SAMPLES * sizeof(int16_t));
#else
  piezoCaptureTapWaveform(_sPiezoBuf, syncUs);
#endif
  // accel buf stays zeroed — listeners don't capture MPU.  // accel buf stays zeroed — listeners don't capture MPU.
  memset(_sAccelBuf, 0, sizeof(_sAccelBuf));

  _sensorSendTapData(tapperId, syncUs, /*includeAccel=*/false);
}
