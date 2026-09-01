/**
 * esp_now_mesh.h — ESP-NOW peer-to-peer mesh layer
 *
 * Provides the communication backbone between sensor nodes (1–7) and the
 * gateway node (0). All nodes use the same code; role is determined by
 * IS_GATEWAY at compile time.
 *
 * ── Channel constraint ────────────────────────────────────────────────────────
 *
 *   The ESP32-C3 has one radio shared between Wi-Fi and ESP-NOW.
 *   ESP-NOW frames are sent on whatever channel the Wi-Fi interface is
 *   currently on. Rules:
 *
 *     Gateway (Node 0):  SoftAP fixes the channel → ESPNOW_CHANNEL (6).
 *                        ESP-NOW automatically uses the AP's channel.
 *
 *     Sensor nodes:      Must connect to the gateway AP FIRST so the STA
 *                        interface locks to the same channel, THEN init
 *                        ESP-NOW. If you init ESP-NOW before associating,
 *                        the channel may not match and frames will be lost.
 *
 *   All peer registrations use ESPNOW_CHANNEL. This is enforced in
 *   espnowAddPeer().
 *
 * ── Message framing ───────────────────────────────────────────────────────────
 *
 *   ESP-NOW payload limit: 250 bytes.
 *
 *   For short messages (telemetry, commands, FTM results) we send a single
 *   EspNowPacket with the JSON payload directly embedded.
 *
 *   For large messages (tap_data with 500 piezo samples ≈ 3–5 KB) we use
 *   a simple chunked framing:
 *
 *     EspNowPacket {
 *       type:       MSG_CHUNK
 *       msgId:      unique ID for this logical message (wrapping uint8)
 *       chunkIdx:   0-based chunk index
 *       totalChunks: total number of chunks
 *       payloadLen: bytes of data in this chunk (≤ ESPNOW_CHUNK_BYTES)
 *       payload[]:  raw bytes (substring of the full JSON)
 *     }
 *
 *   The receiver reassembles chunks into a String buffer, then dispatches
 *   the complete message when totalChunks have arrived.
 *
 *   Small messages use MSG_JSON directly (single packet, no chunking).
 *
 * ── Broadcast vs unicast ──────────────────────────────────────────────────────
 *
 *   espnowBroadcast()  — sends to the ESP-NOW broadcast MAC (ff:ff:ff:ff:ff:ff).
 *                        Used by the gateway to push commands to all sensors.
 *
 *   espnowSend()       — sends to a specific peer MAC.
 *                        Used by sensors to send data up to the gateway.
 *
 *   For broadcast to work, add the broadcast MAC as a peer with
 *   espnowAddBroadcastPeer() — the ESP-NOW stack requires it.
 */

#pragma once

#include <Arduino.h>
#include <esp_now.h>
#include <WiFi.h>

// ── Constants ─────────────────────────────────────────────────────────────────

#define ESPNOW_CHANNEL        6      // Must match SoftAP channel in wifi_setup.h
#define ESPNOW_CHUNK_BYTES  220      // bytes of JSON per chunk (250 - 30 header)
#define ESPNOW_MAX_CHUNKS    32      // max chunks per reassembled message

// ── Message types ─────────────────────────────────────────────────────────────
#define MSG_JSON    0x01   // complete JSON in one packet (≤ 220 bytes)
#define MSG_CHUNK   0x02   // one chunk of a multi-packet message

// ── Packet layout (must fit in 250 bytes) ─────────────────────────────────────
#pragma pack(push, 1)
struct EspNowPacket {
  uint8_t  type;           // MSG_JSON or MSG_CHUNK
  uint8_t  srcId;          // sender's NODE_ID
  uint8_t  msgId;          // wrapping message ID (for chunk reassembly)
  uint8_t  chunkIdx;       // 0-based (0 for MSG_JSON)
  uint8_t  totalChunks;    // 1 for MSG_JSON
  uint8_t  payloadLen;     // bytes used in payload[]
  uint8_t  payload[220];   // JSON text (null terminator not required)
};
#pragma pack(pop)

static_assert(sizeof(EspNowPacket) <= 250,
              "EspNowPacket exceeds ESP-NOW 250-byte limit");

// ── Callback types ────────────────────────────────────────────────────────────

/** Called when a complete message (single or reassembled) has arrived. */
typedef void (*EspNowMessageCallback)(uint8_t srcId, const String &json);

// ── Internal state ────────────────────────────────────────────────────────────

static EspNowMessageCallback _espnowOnMessage = nullptr;

// Reassembly buffer — one slot per sender (up to 8 nodes).
struct _ReassemblySlot {
  uint8_t  msgId      = 0xFF;   // 0xFF = empty
  uint8_t  totalChunks = 0;
  uint8_t  received    = 0;
  char     buf[ESPNOW_CHUNK_BYTES * ESPNOW_MAX_CHUNKS + 1] = {};
};
static _ReassemblySlot _slots[8];  // indexed by srcId (0–7)

static uint8_t _txMsgId = 0;  // wrapping outbound message counter

// Broadcast MAC address constant
static const uint8_t ESPNOW_BROADCAST_MAC[6] = {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF};

// ── Receive callback (registered with ESP-NOW stack) ─────────────────────────

static void _espnowOnRecv(const uint8_t *mac,
                          const uint8_t *data, int len) {
  if (len < (int)sizeof(EspNowPacket)) { return; }
  const EspNowPacket *pkt = reinterpret_cast<const EspNowPacket*>(data);

  if (pkt->srcId > 7) { return; }  // sanity check
  const uint8_t sid = pkt->srcId;

  if (pkt->type == MSG_JSON) {
    // Single-packet message — dispatch immediately.
    if (_espnowOnMessage && pkt->payloadLen > 0) {
      const String json = String(reinterpret_cast<const char*>(pkt->payload),
                                 pkt->payloadLen);
      _espnowOnMessage(sid, json);
    }
    return;
  }

  if (pkt->type == MSG_CHUNK) {
    _ReassemblySlot &slot = _slots[sid];

    // New message or stale slot from a different msgId — reset.
    if (slot.msgId != pkt->msgId) {
      memset(slot.buf, 0, sizeof(slot.buf));
      slot.msgId       = pkt->msgId;
      slot.totalChunks = pkt->totalChunks;
      slot.received    = 0;
    }

    // Copy chunk data into the right position in the buffer.
    const uint32_t offset = (uint32_t)pkt->chunkIdx * ESPNOW_CHUNK_BYTES;
    if (offset + pkt->payloadLen > sizeof(slot.buf) - 1) { return; }
    memcpy(slot.buf + offset, pkt->payload, pkt->payloadLen);
    slot.received++;

    // All chunks received — dispatch the complete message.
    if (slot.received >= slot.totalChunks && _espnowOnMessage) {
      const String json = String(slot.buf);
      _espnowOnMessage(sid, json);
      slot.msgId = 0xFF;  // mark slot empty
    }
  }
}

// ── Send callback (optional — logs delivery failures) ────────────────────────

static void _espnowOnSent(const uint8_t *mac, esp_now_send_status_t status) {
  if (status != ESP_NOW_SEND_SUCCESS) {
    Serial.printf("[ESP-NOW] Send failed to %02X:%02X:%02X:%02X:%02X:%02X\n",
                  mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
  }
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Initialise ESP-NOW and register callbacks.
 * Call AFTER Wi-Fi is set up (channel must be established first).
 *
 * @param onMessage  Callback invoked with (srcNodeId, jsonString) whenever
 *                   a complete message arrives.
 */
void espnowInit(EspNowMessageCallback onMessage) {
  _espnowOnMessage = onMessage;

  if (esp_now_init() != ESP_OK) {
    Serial.println("[ESP-NOW] Init FAILED");
    return;
  }

  esp_now_register_recv_cb(_espnowOnRecv);
  esp_now_register_send_cb(_espnowOnSent);

  Serial.printf("[ESP-NOW] Init OK, channel %d\n", ESPNOW_CHANNEL);
}

/**
 * Register a unicast peer by MAC address.
 * Must be called before espnowSend() to that peer.
 *
 * @param mac  6-byte MAC address of the peer.
 * @param id   Human-readable node ID (for log messages only).
 */
void espnowAddPeer(const uint8_t *mac, uint8_t id = 0xFF) {
  if (esp_now_is_peer_exist(mac)) { return; }

  esp_now_peer_info_t peer = {};
  memcpy(peer.peer_addr, mac, 6);
  peer.channel  = ESPNOW_CHANNEL;
  peer.encrypt  = false;

  if (esp_now_add_peer(&peer) == ESP_OK) {
    Serial.printf("[ESP-NOW] Added peer node %d  %02X:%02X:%02X:%02X:%02X:%02X\n",
                  id, mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
  } else {
    Serial.printf("[ESP-NOW] Failed to add peer node %d\n", id);
  }
}

/**
 * Add the broadcast MAC as a peer so espnowBroadcast() works.
 * Call once from setup().
 */
void espnowAddBroadcastPeer() {
  espnowAddPeer(ESPNOW_BROADCAST_MAC, 0xFF);
}

/**
 * Send a JSON string to a specific peer, chunking automatically if needed.
 *
 * @param mac   Destination MAC address (must have been added with espnowAddPeer).
 * @param json  JSON string to send.
 * @param srcId This node's ID, embedded in each packet header.
 */
void espnowSend(const uint8_t *mac, const String &json, uint8_t srcId) {
  const uint16_t totalLen = json.length();
  const uint8_t  totalChunks =
      (uint8_t)((totalLen + ESPNOW_CHUNK_BYTES - 1) / ESPNOW_CHUNK_BYTES);
  const uint8_t  msgId = _txMsgId++;

  EspNowPacket pkt;
  pkt.srcId       = srcId;
  pkt.msgId       = msgId;
  pkt.totalChunks = totalChunks;

  if (totalChunks == 1) {
    // Fits in one packet — use MSG_JSON for efficiency.
    pkt.type       = MSG_JSON;
    pkt.chunkIdx   = 0;
    pkt.payloadLen = (uint8_t)totalLen;
    memcpy(pkt.payload, json.c_str(), totalLen);
    esp_now_send(mac, reinterpret_cast<uint8_t*>(&pkt), sizeof(pkt));
  } else {
    // Multi-chunk send.
    pkt.type = MSG_CHUNK;
    for (uint8_t i = 0; i < totalChunks; i++) {
      const uint16_t offset = i * ESPNOW_CHUNK_BYTES;
      const uint8_t  chunkLen =
          (uint8_t)min((uint16_t)ESPNOW_CHUNK_BYTES, (uint16_t)(totalLen - offset));

      pkt.chunkIdx   = i;
      pkt.payloadLen = chunkLen;
      memcpy(pkt.payload, json.c_str() + offset, chunkLen);
      esp_now_send(mac, reinterpret_cast<uint8_t*>(&pkt), sizeof(pkt));

      // Small yield between chunks so the Wi-Fi stack can breathe.
      // 5 ms is well within the ESP-NOW retransmit window.
      delay(5);
    }
  }
}

/**
 * Broadcast a JSON string to all ESP-NOW peers simultaneously.
 * Used by the gateway to push commands to all sensor nodes at once.
 *
 * @param json   JSON string to broadcast.
 * @param srcId  This node's ID.
 */
void espnowBroadcast(const String &json, uint8_t srcId) {
  espnowSend(ESPNOW_BROADCAST_MAC, json, srcId);
}

/**
 * Store a sensor node's MAC address so the gateway can unicast to it later.
 * Sensor nodes call this is NOT needed — they always send to the gateway MAC.
 * The gateway calls this automatically when it receives the first ESP-NOW
 * message from a new sensor (see gateway.h).
 *
 * @param mac  MAC of the newly seen sensor node.
 * @param id   Sensor node's NODE_ID.
 */
void espnowRegisterSensor(const uint8_t *mac, uint8_t id) {
  espnowAddPeer(mac, id);
}
