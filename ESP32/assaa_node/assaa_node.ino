/**
 * assaa_node.ino — ASSAA ESP32-C3 Super Mini node firmware
 *
 * One sketch flashed to every board. IS_GATEWAY selects the role:
 *
 *   IS_GATEWAY 1 → Node 0  (gateway: SoftAP + WebSocket + ESP-NOW relay)
 *   IS_GATEWAY 0 → Node N  (sensor:  STA + ESP-NOW + piezo ADC streaming)
 *
 * ── Network topology ──────────────────────────────────────────────────────────
 *
 *              ┌────────────────────────────────────────┐
 *   Phone      │  Wi-Fi STA  →  joins AcousticArray_AP  │
 *   (Flutter)  │  WebSocket  →  ws://192.168.4.1:81      │
 *              └─────────────────┬──────────────────────┘
 *                                │
 *                         ┌──────▼──────┐
 *                         │  Node 0      │  SoftAP (192.168.4.1)
 *                         │  GATEWAY     │  WebSocket server :81
 *                         │              │  ESP-NOW relay hub
 *                         └──────┬───────┘
 *                    ESP-NOW     │     ESP-NOW
 *              ┌─────────────────┼──────────────────┐
 *              │                 │                  │
 *        ┌─────▼────┐     ┌──────▼────┐     ┌──────▼────┐
 *        │  Node 1  │     │  Node 2   │     │  Node 3…7 │
 *        │  SENSOR  │     │  SENSOR   │     │  SENSOR   │
 *        └──────────┘     └───────────┘     └───────────┘
 *              │                 │                  │
 *              └─────────────────┴──────────────────┘
 *                    UDP :9000 (piezo frames, direct to phone)
 *
 * ── Data flows ────────────────────────────────────────────────────────────────
 *
 *   PIEZO FRAMES (Mode 2, high bandwidth):
 *     Sensor → UDP broadcast 255.255.255.255:9000 → phone directly.
 *     Gateway does NOT relay these (avoids bottleneck).
 *     Phone receives them as AudioFrame objects via UdpAudioReceiver.
 *
 *   COMMANDS (downlink):
 *     Phone → WebSocket → Gateway → ESP-NOW broadcast → all sensors.
 *
 *   TAP DATA / TELEMETRY / FTM (uplink):
 *     Sensor → ESP-NOW unicast → Gateway → WebSocket → phone.
 *
 * ── Hardware (all nodes identical) ───────────────────────────────────────────
 *
 *   GPIO  0  SG90 servo PWM
 *   GPIO  1  TL072 piezo output — PRIMARY SENSOR (ADC + interrupt)
 *   GPIO  8  MPU-6050 SDA (Mode 1 supplemental accel)
 *   GPIO  9  MPU-6050 SCL
 *   GPIO 10  Status LED
 *
 * ── How to flash ──────────────────────────────────────────────────────────────
 *
 *   Gateway (one board only):
 *     Set  IS_GATEWAY 1  and  NODE_ID 0  below, then Upload.
 *
 *   Sensor nodes (all other boards):
 *     Set  IS_GATEWAY 0  and  NODE_ID 1..7  below, then Upload.
 *
 * ── Arduino IDE setup ─────────────────────────────────────────────────────────
 *
 *   Board:    "ESP32C3 Dev Module"  (esp32 by Espressif Systems >= 2.0.14)
 *   Libraries: ESP32Servo, WebSockets (Markus Sattler)
 */

#include <Arduino.h>
#include <esp_wifi.h>

// ─────────────────────────────────────────────────────────────────────────────
//  CONFIGURE THESE TWO LINES BEFORE FLASHING EACH BOARD
// ─────────────────────────────────────────────────────────────────────────────
#define IS_GATEWAY  0   // 1 = gateway (Node 0), 0 = sensor node
#define NODE_ID     1   // 0 = gateway, 1-7 = sensor nodes
// ─────────────────────────────────────────────────────────────────────────────

#include "pins.h"
#include "wifi_setup.h"
#include "esp_now_mesh.h"
#include "piezo_adc.h"
#include "mpu6050.h"
#include "impactor.h"

#if IS_GATEWAY
  #include "gateway.h"
#else
  #include "sensor_node.h"
#endif

// ── LED blink state (Mode 2 activity, sensor nodes only) ─────────────────────
static uint32_t _lastBlinkMs = 0;
static bool     _ledState    = false;

// =============================================================================
// setup()
// =============================================================================

void setup() {
  Serial.begin(115200);
  delay(200);

  Serial.printf("\n╔══════════════════════════════════════╗\n");
  Serial.printf("║  ASSAA Node %d  %s  ║\n",
                NODE_ID, IS_GATEWAY ? "[ GATEWAY ]           " : "[ SENSOR  ]           ");
  Serial.printf("╚══════════════════════════════════════╝\n");

  // ── GPIO init ──────────────────────────────────────────────────────────────
  pinMode(PIN_LED, OUTPUT);
  digitalWrite(PIN_LED, LOW);
  pinMode(PIN_PIEZO_ADC, INPUT);

  // ── Shared peripheral init ─────────────────────────────────────────────────
  piezoSetup();    // ADC resolution + attenuation
  mpuSetup();      // MPU-6050 wake + ±2g range
  impactorSetup(); // servo attach + idle position

#if IS_GATEWAY
  // ── Gateway role ───────────────────────────────────────────────────────────
  // gatewaySetup() starts the SoftAP (which locks the Wi-Fi channel),
  // then inits ESP-NOW, broadcasts the gateway MAC, and starts WebSocket.
  gatewaySetup(WIFI_AP_SSID, WIFI_AP_PASS, ESPNOW_CHANNEL);
  gatewayRegisterRawRecvCb();  // install MAC-capturing recv callback
  wifiEnableFtmResponder();    // gateway can also be an FTM responder

  Serial.println("[ASSAA] Gateway ready — waiting for phone and sensor nodes");

  // Solid LED = gateway up.
  digitalWrite(PIN_LED, HIGH);

#else
  // ── Sensor role ────────────────────────────────────────────────────────────
  // sensorNodeSetup() connects to the gateway AP (blocking), then inits
  // ESP-NOW and sends the hello broadcast for MAC auto-registration.
  sensorNodeSetup(WIFI_AP_SSID, WIFI_AP_PASS);

  Serial.printf("[ASSAA] Sensor node %d ready\n", NODE_ID);

#endif

  // ── Boot confirmation blink ────────────────────────────────────────────────
  for (int i = 0; i < 3; i++) {
    digitalWrite(PIN_LED, HIGH); delay(80);
    digitalWrite(PIN_LED, LOW);  delay(80);
  }

#if IS_GATEWAY
  // Restore solid LED after blink.
  digitalWrite(PIN_LED, HIGH);
#endif
}

// =============================================================================
// loop()
// =============================================================================

void loop() {
#if IS_GATEWAY
  // ── Gateway loop ───────────────────────────────────────────────────────────
  // gatewayLoop() services the WebSocket stack (phone ↔ gateway comms).
  // ESP-NOW receive callbacks are dispatched by the Wi-Fi event task
  // automatically — no explicit poll needed.
  gatewayLoop();

  // Blink LED once per second to show the gateway is alive and serving.
  // (Overrides the solid LED set in setup — a heartbeat blink is more useful
  // in the field than a static indicator.)
  const uint32_t now = millis();
  if (now - _lastBlinkMs >= 1000) {
    _lastBlinkMs = now;
    _ledState = !_ledState;
    digitalWrite(PIN_LED, _ledState ? HIGH : LOW);
  }

#else
  // ── Sensor node loop ───────────────────────────────────────────────────────
  // sensorNodeLoop() handles:
  //   • Deferred tap captures (impactor and listener)
  //   • piezoStreamFrame() in Mode 2 (10 ms blocking ADC poll + UDP send)
  //   • Telemetry heartbeat every 4 s via ESP-NOW
  sensorNodeLoop();

#endif
}
