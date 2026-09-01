/**
 * wifi_setup.h — Shared Wi-Fi utilities (FTM ranging + RSSI fallback)
 *
 * Wi-Fi initialisation is role-specific and lives elsewhere:
 *   Gateway  (IS_GATEWAY=1) → gatewaySetup()   in gateway.h
 *   Sensors  (IS_GATEWAY=0) → sensorNodeSetup() in sensor_node.h
 *
 * This file provides only the utilities both roles share:
 *   • wifiEnableFtmResponder() — let other nodes range to this one
 *   • ftmRequestDistance()     — initiate a ranging burst to a peer
 *   • rssiToDistanceM()        — log-distance fallback when FTM fails
 *
 * ── Channel contract ──────────────────────────────────────────────────────────
 *
 *   All ESP-NOW traffic and FTM bursts must use the same channel as the
 *   SoftAP. That channel is defined in esp_now_mesh.h as ESPNOW_CHANNEL (6).
 *
 *   Rule of thumb:
 *     1. Gateway:  start SoftAP first → channel locked → init ESP-NOW.
 *     2. Sensors:  associate to AP first → channel locked → init ESP-NOW.
 *   Never call esp_now_init() before the Wi-Fi channel is fixed.
 *
 * ── Network credentials (shared by gateway AP and sensor STA) ─────────────────
 */

#pragma once

#include <WiFi.h>
#include <esp_wifi.h>

// ── Network credentials ───────────────────────────────────────────────────────
#define WIFI_AP_SSID   "AcousticArray_AP"
#define WIFI_AP_PASS   "concrete_testing"

// ── FTM burst parameters ──────────────────────────────────────────────────────
#define FTM_FRAME_COUNT   16   // frames per burst (more = better averaging)
#define FTM_BURST_PERIOD   2   // inter-burst period (×100 ms = 200 ms)

// ── Internal FTM state (written by event callback, read by ftmRequestDistance)
static volatile bool  _ftmDone  = false;
static volatile float _ftmDistM = -1.0f;

static void _onFtmReport(arduino_event_id_t event,
                          arduino_event_info_t info) {
  if (event != ARDUINO_EVENT_WIFI_FTM_REPORT) { return; }
  const wifi_event_ftm_report_t *rep = &info.wifi_ftm_report;
  if (rep->status == FTM_STATUS_SUCCESS) {
    // rtt_est in picoseconds; c = 3×10⁸ m/s = 3×10⁻⁴ m/ps; one-way = rtt/2
    _ftmDistM = (rep->rtt_est * 3e-4f) / 2.0f;
  } else {
    _ftmDistM = -1.0f;
  }
  _ftmDone = true;
}

/**
 * Enable FTM responder mode so other nodes can range to this one.
 * Call once from setup() on every node (gateway and sensors).
 * Requires Wi-Fi to already be up.
 */
void wifiEnableFtmResponder() {
  // Register callback before enabling so the first burst is captured.
  WiFi.onEvent(_onFtmReport, ARDUINO_EVENT_WIFI_FTM_REPORT);

  if (esp_wifi_ftm_resp_enable() == ESP_OK) {
    Serial.println("[FTM] Responder enabled");
  } else {
    Serial.println("[FTM] Responder enable failed (may need ESP-IDF >= 5.0)");
  }
}

/**
 * Initiate an FTM ranging burst to a peer MAC address.
 *
 * @param peerMac    6-byte MAC of the FTM responder.
 * @param channel    Wi-Fi channel the responder is on (use ESPNOW_CHANNEL).
 * @param timeoutMs  Max milliseconds to wait for the report event.
 * @return Distance in metres, or -1.0 on failure / timeout.
 *
 * Blocks for up to timeoutMs. Do not call from an ISR or ESP-NOW callback.
 * For NAV-01 (100 bursts per pair), call this in a loop and average externally.
 */
float ftmRequestDistance(const uint8_t *peerMac,
                         uint8_t channel,
                         uint32_t timeoutMs = 3000) {
  _ftmDone  = false;
  _ftmDistM = -1.0f;

  wifi_ftm_initiator_cfg_t cfg = {};
  memcpy(cfg.resp_mac, peerMac, 6);
  cfg.channel      = channel;
  cfg.frm_count    = FTM_FRAME_COUNT;
  cfg.burst_period = FTM_BURST_PERIOD;

  if (esp_wifi_ftm_initiate_session(&cfg) != ESP_OK) {
    Serial.println("[FTM] Failed to initiate session");
    return -1.0f;
  }

  const uint32_t t0 = millis();
  while (!_ftmDone && (millis() - t0 < timeoutMs)) {
    delay(10);
  }

  if (!_ftmDone) {
    Serial.println("[FTM] Timeout");
    esp_wifi_ftm_end_session();
    return -1.0f;
  }

  return _ftmDistM;
}

/**
 * RSSI log-distance path-loss model — fallback when FTM is unavailable.
 * Matches rssi_localization.dart on the mobile side.
 *
 * d = 10 ^ ((txPowerAt1m - rssiDbm) / (10 * n))
 *
 * @param rssiDbm      Measured RSSI in dBm.
 * @param txPowerAt1m  Calibrated TX power at 1 m (dBm). Default: -40.
 * @param n            Path-loss exponent. Default: 3.0 (indoor / rubble).
 */
float rssiToDistanceM(float rssiDbm,
                      float txPowerAt1m = -40.0f,
                      float n           =   3.0f) {
  return powf(10.0f, (txPowerAt1m - rssiDbm) / (10.0f * n));
}
