/**
 * piezo_adc.h — 3-channel ADC1 piezo driver
 *
 * Implements the multi-channel sampling architecture from spec §1.2:
 *
 *   "Continuous round-robin DMA acquisition across ADC1 at ~30 kHz per
 *    channel (total aggregate rate ≈ 90 kHz)"
 *
 * Three TL072-buffered piezo channels are read in a tight round-robin loop:
 *
 *   Slot 0 (33 µs) → PIN_PIEZO_A (GPIO 1, ADC1_CH1) — Node A / trigger ch
 *   Slot 1 (33 µs) → PIN_PIEZO_B (GPIO 2, ADC1_CH2) — Node B
 *   Slot 2 (33 µs) → PIN_PIEZO_C (GPIO 3, ADC1_CH3) — Node C
 *   ─────────────────────────────────────────────────────────────────
 *   One revolution = 99 µs ≈ 10 kHz frame rate
 *
 * ── Mode 2: Passive acoustic triangulation ───────────────────────────────────
 *
 *   piezoStreamAllChannels() — call from loop().
 *
 *   Fills one PIEZO_FRAME_SAMPLES-deep buffer per channel in a single
 *   round-robin pass, then broadcasts three PiezoPackets over UDP
 *   (one per channel). The mobile app receives all three as AudioFrames
 *   with distinct nodeId values — one from the local node's three channels.
 *
 *   Wire format (each packet, matches mobile AudioFrame.fromBytes()):
 *     struct PiezoPacket {
 *       uint8_t  nodeId;               // 1 byte  — channel ID (see below)
 *       uint32_t timestampUS;          // 4 bytes — micros() at first sample
 *       int16_t  samples[100];         // 200 bytes
 *     };                               // total: 205 bytes
 *
 *   Channel → nodeId mapping:
 *     Channel A → nodeId = NODE_ID          (this device)
 *     Channel B → nodeId = NODE_ID + 8      (virtual, distinguishes channel)
 *     Channel C → nodeId = NODE_ID + 16     (virtual)
 *
 *   The virtual IDs let the mobile app treat each physical piezo as a
 *   separate "node" in its SyncedFrameSet and GCC-PHAT pipeline, which is
 *   exactly what you want for a single-device 3-sensor array.  When using
 *   separate ESP32 nodes (one piezo each), all three have distinct NODE_IDs
 *   and channel B/C are simply unused (channel A streams as NODE_ID).
 *
 * ── Mode 1: Active NDT waveform capture ───────────────────────────────────────
 *
 *   piezoCaptureTapWaveformAllChannels() — called by impactor.h.
 *
 *   Captures PIEZO_TAP_SAMPLES from every channel in the same round-robin
 *   interleaved fashion, giving time-aligned per-channel waveforms for the
 *   mobile NDT feature extractor. The primary interrupt fires on PIN_PIEZO_A;
 *   channels B and C capture passively from that same T0.
 *
 * ── ADC hardware notes ────────────────────────────────────────────────────────
 *
 *   ESP32-C3 ADC1 can switch channels by simply calling analogRead() on
 *   different GPIO pins — the underlying SAR ADC MUX selects the channel
 *   in hardware. No separate configuration call needed between channels.
 *   Channel switching overhead is folded into the analogRead() call time
 *   (~5–15 µs), which fits within the 33 µs slot budget.
 *
 *   Resolution: 12-bit (analogReadResolution(12))
 *   Attenuation: ADC_11db for full 0–3.3 V range
 *   All three channels share the same resolution and attenuation setting
 *   since analogSetAttenuation() applies globally to ADC1.
 */

#pragma once

#include <Arduino.h>
#include <WiFiUdp.h>
#include "pins.h"

// ── UDP socket ────────────────────────────────────────────────────────────────
static WiFiUDP _udpPiezo;

// ── Packet layout — matches mobile AudioFrame.fromBytes() ────────────────────
#pragma pack(push, 1)
struct PiezoPacket {
  uint8_t  nodeId;
  uint32_t timestampUS;
  int16_t  samples[PIEZO_FRAME_SAMPLES];  // 100 samples per packet
};
#pragma pack(pop)

// ── Channel pin table (ordered A, B, C) ──────────────────────────────────────
static const uint8_t _piezoPins[PIEZO_CHANNEL_COUNT] = PIEZO_PINS;

// Virtual nodeId offset per channel so mobile app treats each as a separate node.
static const uint8_t _channelNodeIdOffset[PIEZO_CHANNEL_COUNT] = { 0, 8, 16 };

// ── Per-channel sample buffers ─────────────────────────────────────────────────
// Static to avoid stack pressure during the time-critical sampling loop.
static int16_t _chBuf[PIEZO_CHANNEL_COUNT][PIEZO_FRAME_SAMPLES];
static int16_t _tapBuf[PIEZO_CHANNEL_COUNT][PIEZO_TAP_SAMPLES];

// =============================================================================
// Initialisation
// =============================================================================

/**
 * Configure ADC1 for 3-channel 12-bit acquisition.
 * Call once from setup().
 */
void piezoSetup() {
  analogReadResolution(12);         // 0–4095
  analogSetAttenuation(ADC_11db);   // full 0–3.3 V input range on all ADC1 ch

  for (int ch = 0; ch < PIEZO_CHANNEL_COUNT; ch++) {
    pinMode(_piezoPins[ch], INPUT);
  }

  Serial.printf("[Piezo] 3-ch ADC1  GPIO %d/%d/%d  %d Hz/ch  frame=%d samp\n",
                PIN_PIEZO_A, PIN_PIEZO_B, PIN_PIEZO_C,
                PIEZO_CHANNEL_RATE_HZ, PIEZO_FRAME_SAMPLES);
}

// =============================================================================
// Mode 2: Streaming
// =============================================================================

/**
 * Round-robin sample all three channels, then broadcast one PiezoPacket
 * per channel over UDP.
 *
 * Timing:
 *   Each sample slot = PIEZO_CHANNEL_INTERVAL_US (33 µs).
 *   One frame of PIEZO_FRAME_SAMPLES per channel requires
 *   PIEZO_FRAME_SAMPLES × PIEZO_ROUND_ROBIN_US ≈ 9.9 ms total.
 *
 * Structure of the inner loop (one "revolution"):
 *   t=0:  read ch A  → _chBuf[0][i], busy-wait to 33 µs
 *   t=33: read ch B  → _chBuf[1][i], busy-wait to 33 µs
 *   t=66: read ch C  → _chBuf[2][i], busy-wait to 33 µs
 *   t=99: next revolution (i++)
 *
 * Call from loop() in Mode 2. WebSocket.loop() runs between frames
 * so command latency is at most ~10 ms.
 */
void piezoStreamAllChannels() {
  const uint32_t frameStartUs = micros();

  // ── Round-robin sample loop ───────────────────────────────────────────────
  for (int i = 0; i < PIEZO_FRAME_SAMPLES; i++) {
    for (int ch = 0; ch < PIEZO_CHANNEL_COUNT; ch++) {
      const uint32_t slotStart = micros();

      const int raw      = analogRead(_piezoPins[ch]);
      _chBuf[ch][i] = (int16_t)((raw - PIEZO_ADC_MIDPOINT) * PIEZO_ADC_SCALE);

      // Busy-wait for the rest of the 33 µs slot.
      while ((micros() - slotStart) < PIEZO_CHANNEL_INTERVAL_US) { /* spin */ }
    }
  }

  // ── Broadcast one packet per channel ─────────────────────────────────────
  static PiezoPacket pkt;
  pkt.timestampUS = frameStartUs;  // same T0 for all three packets in this frame

  for (int ch = 0; ch < PIEZO_CHANNEL_COUNT; ch++) {
    pkt.nodeId = (uint8_t)(NODE_ID + _channelNodeIdOffset[ch]);
    memcpy(pkt.samples, _chBuf[ch], sizeof(_chBuf[ch]));

    _udpPiezo.beginPacket(UDP_BCAST_ADDR, UDP_AUDIO_PORT);
    _udpPiezo.write(reinterpret_cast<const uint8_t*>(&pkt), sizeof(pkt));
    _udpPiezo.endPacket();
  }
}

/**
 * Single-channel streaming fallback for nodes that only have one piezo.
 * Behaves identically to the old single-channel piezoStreamFrame().
 */
void piezoStreamFrame() {
  static PiezoPacket pkt;
  pkt.nodeId      = NODE_ID;
  pkt.timestampUS = micros();

  for (int i = 0; i < PIEZO_FRAME_SAMPLES; i++) {
    const uint32_t t0 = micros();
    const int raw     = analogRead(PIN_PIEZO_A);
    pkt.samples[i]    = (int16_t)((raw - PIEZO_ADC_MIDPOINT) * PIEZO_ADC_SCALE);
    while ((micros() - t0) < PIEZO_CHANNEL_INTERVAL_US) { /* spin */ }
  }

  _udpPiezo.beginPacket(UDP_BCAST_ADDR, UDP_AUDIO_PORT);
  _udpPiezo.write(reinterpret_cast<const uint8_t*>(&pkt), sizeof(pkt));
  _udpPiezo.endPacket();
}

// =============================================================================
// Mode 1: Tap waveform capture
// =============================================================================

/**
 * Capture PIEZO_TAP_SAMPLES from all three channels simultaneously using
 * the same round-robin interleaving as the streaming loop.
 *
 * The interrupt always fires on PIN_PIEZO_A (primary trigger channel).
 * Channels B and C begin recording from the same T0 timestamp so the
 * mobile NDT feature extractor receives time-aligned per-channel waveforms.
 *
 * @param startUs  micros() timestamp of the piezo interrupt (T0).
 *
 * Output arrays: _tapBuf[0] = ch A, _tapBuf[1] = ch B, _tapBuf[2] = ch C.
 * Access via piezoTapBuffer(ch) after this call.
 *
 * Blocks for PIEZO_TAP_SAMPLES × PIEZO_ROUND_ROBIN_US ≈ 16.5 ms.
 */
void piezoCaptureTapWaveformAllChannels(uint32_t startUs) {
  // Spin-wait until T0 is reached (handles early call before the interrupt
  // timestamp, which can happen if scheduling beats the ISR by a few µs).
  while (micros() < startUs) { /* spin */ }

  for (int i = 0; i < PIEZO_TAP_SAMPLES; i++) {
    for (int ch = 0; ch < PIEZO_CHANNEL_COUNT; ch++) {
      const uint32_t slotStart = micros();

      const int raw       = analogRead(_piezoPins[ch]);
      _tapBuf[ch][i] = (int16_t)((raw - PIEZO_ADC_MIDPOINT) * PIEZO_ADC_SCALE);

      while ((micros() - slotStart) < PIEZO_CHANNEL_INTERVAL_US) { /* spin */ }
    }
  }
}

/**
 * Single-channel tap capture fallback (backward-compatible with impactor.h).
 * Captures only from PIN_PIEZO_A into the provided buffer.
 */
void piezoCaptureTapWaveform(int16_t *buf, uint32_t startUs) {
  while (micros() < startUs) { /* spin */ }

  for (int i = 0; i < PIEZO_TAP_SAMPLES; i++) {
    const uint32_t t0 = micros();
    const int raw     = analogRead(PIN_PIEZO_A);
    buf[i] = (int16_t)((raw - PIEZO_ADC_MIDPOINT) * PIEZO_ADC_SCALE);
    while ((micros() - t0) < PIEZO_CHANNEL_INTERVAL_US) { /* spin */ }
  }
}

/**
 * Access the tap capture buffer for a specific channel after
 * piezoCaptureTapWaveformAllChannels() has been called.
 *
 * @param ch  Channel index: 0=A, 1=B, 2=C.
 * @return    Pointer to PIEZO_TAP_SAMPLES int16 samples.
 */
const int16_t* piezoTapBuffer(int ch) {
  if (ch < 0 || ch >= PIEZO_CHANNEL_COUNT) { return nullptr; }
  return _tapBuf[ch];
}

// =============================================================================
// Utilities
// =============================================================================

/**
 * Read a single raw 12-bit ADC value from the specified channel.
 * Used by the interrupt-based trigger check.
 */
inline int piezoReadRaw(int ch = 0) {
  return analogRead(_piezoPins[ch < PIEZO_CHANNEL_COUNT ? ch : 0]);
}

/**
 * Convert a raw ADC count to millivolts (approximate).
 */
inline float piezoRawToMv(int raw) {
  return raw * (3300.0f / 4095.0f);
}

/**
 * Returns the virtual nodeId for a given channel, used to stamp UDP packets.
 */
inline uint8_t piezoChannelNodeId(int ch) {
  return (uint8_t)(NODE_ID + _channelNodeIdOffset[ch < PIEZO_CHANNEL_COUNT ? ch : 0]);
}
