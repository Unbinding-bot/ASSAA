/**
 * gateway.h — Node 0 gateway firmware role
 *
 * Node 0 is the bridge between the phone and the sensor mesh:
 *
 *   Phone  ←──WebSocket──→  Gateway  ←──ESP-NOW──→  Sensor nodes 1–7
 *
 * ── Responsibilities ──────────────────────────────────────────────────────────
 *
 *   PHONE → SENSORS  (downlink):
 *     The phone sends JSON commands over WebSocket to the gateway.
 *     The gateway broadcasts them to all sensor nodes over ESP-NOW.
 *     Commands: SET_MODE_1, SET_MODE_2, TRIGGER_TAP, start_ftm, ping
 *
 *   SENSORS → PHONE  (uplink):
 *     Sensor nodes send JSON messages to the gateway over ESP-NOW.
 *     The gateway forwards them verbatim to all connected WebSocket clients.
 *     Messages: tap_data, telemetry, ftm, detection, rescuer_rssi
 *
 *   AUTO-REGISTRATION:
 *     The first time the gateway receives an ESP-NOW message from a sensor,
 *     it registers that sensor's MAC address as a unicast peer. This means
 *     you don't need to hardcode MAC addresses — sensors self-announce.
 *
 *   UDP PIEZO FRAMES:
 *     Sensor nodes broadcast UDP piezo frames directly to the AP subnet
 *     (255.255.255.255:9000). The phone receives these directly — the
 *     gateway does NOT relay them to avoid a UDP→WebSocket bottleneck.
 *     This keeps the high-bandwidth path (10 kHz × 7 nodes) off the
 *     gateway's WebSocket entirely.
 *
 * ── MAC address exchange ──────────────────────────────────────────────────────
 *
 *   On boot, each sensor node sends a "hello" ESP-NOW message to the
 *   gateway broadcast MAC. The gateway's receive callback captures the
 *   sender's hardware MAC from the ESP-NOW header and registers it.
 *
 *   The gateway also broadcasts its own MAC in a "gateway_mac" message
 *   so sensors can unicast back to it (needed for tap_data since those
 *   are too large to broadcast reliably).
 *
 * ── WebSocket protocol ────────────────────────────────────────────────────────
 *
 *   The gateway's WebSocket server accepts the same protocol as described
 *   in gateway_service.dart — no changes needed on the Flutter side.
 */

#pragma once

#include <Arduino.h>
#include <WebSocketsServer.h>
#include "pins.h"
#include "esp_now_mesh.h"

// ── Gateway MAC storage (filled from WiFi.softAPmacAddress() at runtime) ─────
static uint8_t _gwMac[6] = {};

// ── Known sensor MAC table (indexed by NODE_ID 1–7) ──────────────────────────
static uint8_t _sensorMacs[8][6] = {};   // _sensorMacs[nodeId]
static bool    _sensorSeen[8]    = {};   // true once that node has checked in

// ── WebSocket server (phone connects here) ────────────────────────────────────
static WebSocketsServer _gwWs(WS_PORT);
static bool _phoneConnected = false;

// ── Forward declarations ──────────────────────────────────────────────────────
static void _gatewayOnEspNow(uint8_t srcId, const String &json);
static void _gatewayWsEvent(uint8_t clientNum, WStype_t type,
                             uint8_t *payload, size_t length);

// =============================================================================
// Initialisation
// =============================================================================

/**
 * Initialise all gateway subsystems.
 * Call from setup() when IS_GATEWAY == 1.
 *
 * Sequence:
 *   1. Start SoftAP (fixes the Wi-Fi channel — MUST be before espnowInit).
 *   2. Init ESP-NOW with uplink callback.
 *   3. Add broadcast peer so we can push to all sensors at once.
 *   4. Broadcast our MAC so sensors know where to send unicast replies.
 *   5. Start WebSocket server for the phone.
 */
void gatewaySetup(const char *ssid, const char *pass, uint8_t channel) {
  // ── 1. SoftAP ──────────────────────────────────────────────────────────────
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(ssid, pass, channel, /*hidden=*/0, /*max_conn=*/8);

  // Lock the STA interface to the same channel so ESP-NOW uses it too.
  esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE);

  WiFi.softAPmacAddress(_gwMac);
  Serial.printf("[GW] SoftAP up  SSID=%s  IP=%s  MAC=%02X:%02X:%02X:%02X:%02X:%02X\n",
                ssid,
                WiFi.softAPIP().toString().c_str(),
                _gwMac[0], _gwMac[1], _gwMac[2],
                _gwMac[3], _gwMac[4], _gwMac[5]);

  // ── 2. ESP-NOW ─────────────────────────────────────────────────────────────
  espnowInit(_gatewayOnEspNow);

  // ── 3. Broadcast peer ──────────────────────────────────────────────────────
  espnowAddBroadcastPeer();

  // ── 4. Announce our MAC so sensors can unicast back ────────────────────────
  // Sent as a broadcast immediately after ESP-NOW is up.
  // Sensors will receive this and store _gwMac for their uplink sends.
  // Small delay lets ESP-NOW stack settle first.
  delay(100);
  String announce = "{\"type\":\"gateway_mac\",\"mac\":\"";
  char macStr[18];
  snprintf(macStr, sizeof(macStr), "%02X:%02X:%02X:%02X:%02X:%02X",
           _gwMac[0], _gwMac[1], _gwMac[2],
           _gwMac[3], _gwMac[4], _gwMac[5]);
  announce += macStr;
  announce += "\",\"node\":0}";
  espnowBroadcast(announce, 0);
  Serial.printf("[GW] MAC announced: %s\n", macStr);

  // ── 5. WebSocket ───────────────────────────────────────────────────────────
  _gwWs.begin();
  _gwWs.onEvent(_gatewayWsEvent);
  Serial.printf("[GW] WebSocket server on port %d\n", WS_PORT);
}

// =============================================================================
// Main loop tick — call every loop() iteration
// =============================================================================

void gatewayLoop() {
  _gwWs.loop();
}

// =============================================================================
// Phone → Sensors  (downlink relay)
// =============================================================================

/**
 * Forward a command received from the phone to all sensor nodes via
 * ESP-NOW broadcast.
 *
 * The gateway does NOT act on the command itself — it has no servo, no
 * piezo ADC, no MPU. It is a pure relay for all sensor commands.
 */
static void _relayToSensors(const String &json) {
  espnowBroadcast(json, 0);
  Serial.printf("[GW→Sensors] %s\n", json.substring(0, 80).c_str());
}

// =============================================================================
// Sensors → Phone  (uplink relay)
// =============================================================================

/**
 * Forward a message received from a sensor node to the phone via WebSocket.
 *
 * Called from the ESP-NOW receive callback. Runs in the Arduino loop context
 * (ESP-NOW callbacks are dispatched via the event loop, not a raw ISR), so
 * it's safe to call WebSocketsServer::broadcastTXT here.
 */
static void _relayToPhone(const String &json) {
  if (_phoneConnected) {
    _gwWs.broadcastTXT(json);
    Serial.printf("[Sensor→GW→Phone] %s\n", json.substring(0, 60).c_str());
  }
}

// =============================================================================
// ESP-NOW receive callback (sensor → gateway)
// =============================================================================

static void _gatewayOnEspNow(uint8_t srcId, const String &json) {
  // Auto-register new sensors: store their NODE_ID for routing.
  // The actual MAC is captured by the ESP-NOW stack and passed to
  // espnowRegisterSensor() via the raw recv callback — see below.
  // Here we just forward the payload to the phone.
  _relayToPhone(json);
}

/**
 * Raw ESP-NOW receive shim for the gateway — captures sender MAC for
 * auto-registration before handing off to the mesh layer's reassembler.
 *
 * This is registered INSTEAD of the mesh layer's _espnowOnRecv when
 * running as gateway. It extracts the srcId from the packet, registers
 * the MAC if new, then calls the mesh reassembler manually.
 *
 * Call gatewayRegisterRawRecvCb() from gatewaySetup() to install this.
 */
static void _gatewayRawRecv(const uint8_t *mac,
                             const uint8_t *data, int len) {
  if (len < 2) { return; }
  const uint8_t srcId = data[1];  // EspNowPacket.srcId is byte index 1

  if (srcId > 0 && srcId <= 7 && !_sensorSeen[srcId]) {
    _sensorSeen[srcId] = true;
    memcpy(_sensorMacs[srcId], mac, 6);
    espnowRegisterSensor(mac, srcId);
    Serial.printf("[GW] Registered sensor node %d  %02X:%02X:%02X:%02X:%02X:%02X\n",
                  srcId, mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
  }

  // Re-invoke the mesh layer's receive handler directly.
  // We can't call the static _espnowOnRecv from here since it's in
  // esp_now_mesh.h's translation unit, so we duplicate the minimal
  // dispatch logic needed.
  if (len < (int)sizeof(EspNowPacket)) { return; }
  const EspNowPacket *pkt = reinterpret_cast<const EspNowPacket*>(data);
  if (pkt->srcId > 7) { return; }

  if (pkt->type == MSG_JSON && _espnowOnMessage) {
    const String json = String(reinterpret_cast<const char*>(pkt->payload),
                               pkt->payloadLen);
    _espnowOnMessage(pkt->srcId, json);
  } else if (pkt->type == MSG_CHUNK) {
    // Delegate to the mesh reassembler's slot logic.
    // We call the global recv callback that was already set up by espnowInit.
    // Since esp_now_register_recv_cb only allows one callback, we handle
    // reassembly here inline for the gateway role.
    _ReassemblySlot &slot = _slots[pkt->srcId];
    if (slot.msgId != pkt->msgId) {
      memset(slot.buf, 0, sizeof(slot.buf));
      slot.msgId       = pkt->msgId;
      slot.totalChunks = pkt->totalChunks;
      slot.received    = 0;
    }
    const uint32_t offset = (uint32_t)pkt->chunkIdx * ESPNOW_CHUNK_BYTES;
    if (offset + pkt->payloadLen < sizeof(slot.buf)) {
      memcpy(slot.buf + offset, pkt->payload, pkt->payloadLen);
      slot.received++;
      if (slot.received >= slot.totalChunks && _espnowOnMessage) {
        _espnowOnMessage(pkt->srcId, String(slot.buf));
        slot.msgId = 0xFF;
      }
    }
  }
}

/**
 * Replace the default mesh recv callback with the gateway's MAC-capturing
 * version. Must be called AFTER espnowInit().
 */
void gatewayRegisterRawRecvCb() {
  esp_now_register_recv_cb(_gatewayRawRecv);
}

// =============================================================================
// WebSocket event handler (phone → gateway)
// =============================================================================

static void _gatewayWsEvent(uint8_t clientNum, WStype_t type,
                             uint8_t *payload, size_t length) {
  switch (type) {
    case WStype_CONNECTED:
      _phoneConnected = true;
      Serial.printf("[GW] Phone connected (client %d)\n", clientNum);
      // Send a gateway_ready message so the phone knows the mesh is up.
      {
        String ready = "{\"type\":\"gateway_ready\",\"node\":0,\"sensors_seen\":";
        uint8_t cnt = 0;
        for (int i = 1; i <= 7; i++) { if (_sensorSeen[i]) { cnt++; } }
        ready += cnt;
        ready += "}";
        _gwWs.sendTXT(clientNum, ready);
      }
      break;

    case WStype_DISCONNECTED:
      _phoneConnected = false;
      Serial.println("[GW] Phone disconnected");
      break;

    case WStype_TEXT:
      {
        const String msg = String(reinterpret_cast<const char*>(payload));

        // Handle ping locally — don't relay to sensors.
        if (msg.indexOf("\"ping\"") >= 0) {
          String pong = "{\"type\":\"pong\",\"t\":";
          pong += millis();
          pong += "}";
          _gwWs.sendTXT(clientNum, pong);
          return;
        }

        // Everything else goes to the sensor mesh.
        _relayToSensors(msg);
      }
      break;

    default:
      break;
  }
}

// =============================================================================
// Helpers for the main sketch
// =============================================================================

/** True if at least one WebSocket client (phone) is connected. */
bool gatewayPhoneConnected() {
  return _phoneConnected;
}

/** Number of sensor nodes that have checked in via ESP-NOW. */
uint8_t gatewaySensorCount() {
  uint8_t n = 0;
  for (int i = 1; i <= 7; i++) { if (_sensorSeen[i]) { n++; } }
  return n;
}

/** Send a direct unicast message to one sensor node (by NODE_ID). */
void gatewaySendToSensor(uint8_t nodeId, const String &json) {
  if (nodeId < 1 || nodeId > 7 || !_sensorSeen[nodeId]) { return; }
  espnowSend(_sensorMacs[nodeId], json, 0);
}
