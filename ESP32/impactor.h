/**
 * impactor.h — SG90 servo + piezo tap-capture (Mode 1: active NDT)
 *
 * The piezoelectric transducer (TL072 buffered, GPIO 1) is the primary
 * sensor for both modes. In Mode 1 it serves two roles:
 *
 *   1. Interrupt trigger — detects the impact spike and captures T0 with
 *      microsecond precision. The ISR fires on RISING edge of the TL072
 *      output once the signal crosses the comparator threshold.
 *
 *   2. Waveform capture — immediately after T0, piezoCaptureTapWaveform()
 *      records PIEZO_TAP_SAMPLES (500) ADC samples at 10 kHz (50 ms window).
 *      This is the primary waveform sent in tap_data.
 *
 * The MPU-6050 Z-axis is captured in parallel as a supplemental structural
 * channel. It gives a lower-frequency (500 Hz), longer-window (300 ms) view
 * of the same event — useful for velocity/damping analysis of thick slabs.
 *
 * Pin assignments (from pins.h):
 *   GPIO 0 — SG90 servo PWM
 *   GPIO 1 — Piezo ADC (TL072 output, Zener-clamped to 3.3 V)
 *   GPIO 8 — MPU-6050 SDA  (supplemental)
 *   GPIO 9 — MPU-6050 SCL  (supplemental)
 *
 * tap_data JSON format (sent by both impactor and listener nodes):
 *   {
 *     "type":         "tap_data",
 *     "node":         <int>,        — this node's ID
 *     "tapper":       <int>,        — ID of the node that fired the servo
 *     "piezo_t0":     <uint32 µs>,  — hardware interrupt timestamp
 *     "piezo":        [<500 int16>],— 50 ms piezo waveform at 10 kHz
 *     "accel":        [<150 int16>] — 300 ms MPU-6050 Z at 500 Hz (impactor only)
 *   }
 *
 * Listener nodes omit "accel" (empty array) since their MPU sees almost no
 * signal at the distances involved — the piezo waveform is the useful data.
 */

#pragma once

#include <ESP32Servo.h>
#include <WebSocketsServer.h>
#include "pins.h"
#include "piezo_adc.h"
#include "mpu6050.h"

// ── ISR state ─────────────────────────────────────────────────────────────────
static volatile uint32_t _piezoT0Us     = 0;
static volatile bool     _piezoTriggered = false;

/**
 * Piezo interrupt service routine — fires on RISING edge of TL072 output.
 * Captures micros() at the moment of impact; subsequent triggers in the
 * same tap window are ignored (one T0 per cycle).
 * Placed in IRAM so it runs even during flash cache misses.
 */
void IRAM_ATTR _piezoISR() {
  if (!_piezoTriggered) {
    _piezoT0Us      = micros();
    _piezoTriggered = true;
  }
}

static Servo _tapperServo;

/**
 * Attach the servo to GPIO 0 and hold it at the idle position.
 * Call once from setup().
 */
void impactorSetup() {
  _tapperServo.attach(PIN_SERVO);
  _tapperServo.write(SERVO_IDLE_DEG);
  Serial.printf("[Impactor] Servo GPIO%d, piezo ADC GPIO%d\n",
                PIN_SERVO, PIN_PIEZO_ADC);
}

// ── Shared capture buffers (static to avoid stack pressure) ──────────────────
static int16_t _piezoBuf[PIEZO_TAP_SAMPLES];
static int16_t _accelBuf[MPU_SAMPLE_COUNT];

/**
 * Build and broadcast the tap_data JSON for this node.
 *
 * @param tapperId     ID of the node that physically fired the servo.
 * @param t0Us         Hardware µs timestamp of the piezo trigger (or sync).
 * @param includeAccel If true, appends the MPU-6050 accel array.
 *                     Impactor nodes include it; listeners skip it.
 */
static void _broadcastTapData(WebSocketsServer &ws,
                               uint8_t tapperId,
                               uint32_t t0Us,
                               bool includeAccel) {
  // Size estimate:
  //   header ~80 chars
  //   500 piezo samples × ~7 chars  = ~3500
  //   150 accel samples × ~7 chars  = ~1050 (impactor only)
  //   total impactor ~4630, listener ~3580
  String json;
  json.reserve(includeAccel ? 4800 : 3700);

  json  = "{\"type\":\"tap_data\",\"node\":";
  json += NODE_ID;
  json += ",\"tapper\":";
  json += tapperId;
  json += ",\"piezo_t0\":";
  json += t0Us;

  // Piezo waveform array
  json += ",\"piezo\":[";
  for (int i = 0; i < PIEZO_TAP_SAMPLES; i++) {
    json += _piezoBuf[i];
    if (i < PIEZO_TAP_SAMPLES - 1) { json += ','; }
  }
  json += "]";

  // MPU-6050 accel array (impactor only — listeners send empty array)
  json += ",\"accel\":[";
  if (includeAccel) {
    for (int i = 0; i < MPU_SAMPLE_COUNT; i++) {
      json += _accelBuf[i];
      if (i < MPU_SAMPLE_COUNT - 1) { json += ','; }
    }
  }
  json += "]}";

  ws.broadcastTXT(json);

  Serial.printf("[Tap] Sent: node=%d tapper=%d T0=%u µs piezo=%d accel=%d\n",
                NODE_ID, tapperId, t0Us,
                PIEZO_TAP_SAMPLES, includeAccel ? MPU_SAMPLE_COUNT : 0);
}

// =============================================================================
// Impactor tap sequence
// =============================================================================

/**
 * Execute a full tap cycle on this node (this node IS the impactor):
 *
 *   1. Arm piezo interrupt on GPIO 1.
 *   2. Drive servo to strike angle (GPIO 0).
 *   3. Wait for piezo trigger interrupt (T0), or timeout.
 *   4. Capture 50 ms piezo waveform at 10 kHz starting at T0.
 *   5. Capture 300 ms MPU-6050 Z-axis at 500 Hz starting at T0.
 *      (Steps 4 and 5 run sequentially — piezo first since it's time-critical.)
 *   6. Reset servo.
 *   7. Broadcast tap_data JSON.
 *
 * @param ws       WebSocketsServer to broadcast on.
 * @param tapperId This node's ID (defaults to NODE_ID).
 */
void executeTapSequence(WebSocketsServer &ws, uint8_t tapperId = NODE_ID) {
  // ── 1. Arm interrupt ──────────────────────────────────────────────────────
  _piezoT0Us      = 0;
  _piezoTriggered = false;
  attachInterrupt(digitalPinToInterrupt(PIN_PIEZO_ADC), _piezoISR, RISING);

  // ── 2. Strike ─────────────────────────────────────────────────────────────
  _tapperServo.write(SERVO_STRIKE_DEG);
  const uint32_t strikeUs = micros();

  // ── 3. Wait for piezo trigger ─────────────────────────────────────────────
  while (!_piezoTriggered &&
         (micros() - strikeUs) < SERVO_STRIKE_TIMEOUT_US) { /* spin */ }
  detachInterrupt(digitalPinToInterrupt(PIN_PIEZO_ADC));

  if (!_piezoTriggered) {
    _piezoT0Us = strikeUs;  // fallback: use servo-fire time as T0
    Serial.println("[Impactor] Piezo trigger timeout — using servo T0");
  }

  // ── 4. Capture piezo waveform — all 3 channels if wired ─────────────────
#if PIEZO_CHANNEL_COUNT >= 3
  piezoCaptureTapWaveformAllChannels(_piezoT0Us);
  memcpy(_piezoBuf, piezoTapBuffer(0), PIEZO_TAP_SAMPLES * sizeof(int16_t));
#else
  piezoCaptureTapWaveform(_piezoBuf, _piezoT0Us);
#endif

  // ── 5. Capture MPU-6050 Z-axis (300 ms @ 500 Hz) ─────────────────────────
  // Starts slightly after the piezo capture finishes (~50 ms post-impact),
  // which is fine — MPU captures the slower structural ringing, not the
  // initial impact spike. Passing _piezoT0Us so the mobile app can align
  // both time series against the same T0 reference.
  mpuCaptureSamples(_accelBuf, _piezoT0Us);

  // ── 6. Reset servo ────────────────────────────────────────────────────────
  _tapperServo.write(SERVO_IDLE_DEG);

  // ── 7. Broadcast ──────────────────────────────────────────────────────────
  _broadcastTapData(ws, tapperId, _piezoT0Us, /*includeAccel=*/true);

  digitalWrite(PIN_LED, HIGH); delay(50); digitalWrite(PIN_LED, LOW);
}

// =============================================================================
// Listener tap capture
// =============================================================================

/**
 * Capture piezo + (skip) accel for a tap fired by another node.
 *
 * Called from loop() when _listenerTapPending is set (set in the WS event
 * handler on receipt of TRIGGER_TAP with a different tapper ID).
 *
 * The listener uses the WebSocket message arrival timestamp as T0 — there's
 * no local servo or interrupt. WS delivery jitter over the local AP is
 * typically < 2 ms, which introduces < 0.7 m error in TDOA at 340 m/s.
 *
 * Only the piezo waveform is captured (MPU-6050 won't see anything useful
 * at a listener node metres away from the strike). The "accel" field is
 * sent as an empty array so the JSON schema stays consistent.
 *
 * @param tapperId  ID of the node that fired the actual servo.
 * @param syncUs    micros() captured at WS message arrival — our T0.
 */
void executeListenerCapture(WebSocketsServer &ws,
                             uint8_t tapperId,
                             uint32_t syncUs) {
  // Quick blink to show this node is recording as a listener.
  for (int i = 0; i < 3; i++) {
    digitalWrite(PIN_LED, HIGH); delay(30);
    digitalWrite(PIN_LED, LOW);  delay(30);
  }

  // Capture piezo waveform starting from syncUs.
#if PIEZO_CHANNEL_COUNT >= 3
  piezoCaptureTapWaveformAllChannels(syncUs);
  memcpy(_piezoBuf, piezoTapBuffer(0), PIEZO_TAP_SAMPLES * sizeof(int16_t));
#else
  piezoCaptureTapWaveform(_piezoBuf, syncUs);
#endif

  // _accelBuf is left at zeros from last use — empty array in JSON.
  _broadcastTapData(ws, tapperId, syncUs, /*includeAccel=*/false);
}
