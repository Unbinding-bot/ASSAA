/**
 * pins.h — ESP32-C3 Super Mini hardware pin assignments
 *
 * Spec §2.1 "3-Node Sensor Array": three independent piezo channels are
 * routed to ADC1 pins GPIO 1, 2, 3 so all three can be sampled without
 * interfering with the Wi-Fi radio (ADC2 is blocked when Wi-Fi is active;
 * ADC1 is always available).
 *
 *  ┌──────────────────────────────────────────────────────────────────────┐
 *  │  Component              │ Module Pin  │ ESP32-C3 GPIO │ ADC channel  │
 *  ├──────────────────────────────────────────────────────────────────────┤
 *  │  SG90 Servo             │ PWM Signal  │  GPIO  0      │ —  PWM Out   │
 *  │  TL072 Ch A (Node A)    │ Analog Out  │  GPIO  1      │ ADC1_CH1     │
 *  │  TL072 Ch B (Node B)    │ Analog Out  │  GPIO  2      │ ADC1_CH2     │
 *  │  TL072 Ch C (Node C)    │ Analog Out  │  GPIO  3      │ ADC1_CH3     │
 *  │  MPU-6050               │ SDA         │  GPIO  8      │ I²C Data     │
 *  │  MPU-6050               │ SCL         │  GPIO  9      │ I²C Clock    │
 *  │  Status LED             │ Anode       │  GPIO 10      │ Digital Out  │
 *  └──────────────────────────────────────────────────────────────────────┘
 *
 *  ── Why ADC1 for all three channels ─────────────────────────────────────
 *
 *    The ESP32-C3 has two ADC units:
 *      ADC1 — always available, shared with GPIO 0–4 (some overlap with
 *              special functions; GPIO 1–3 are safe in normal operation).
 *      ADC2 — DISABLED when Wi-Fi is active.  Do not use for audio.
 *
 *    By routing all three piezo channels to ADC1 (GPIO 1, 2, 3), the
 *    firmware can interleave samples from all three channels in a
 *    round-robin loop with no radio interference.
 *
 *  ── Multi-channel sampling rate ─────────────────────────────────────────
 *
 *    Target: ~30 kHz per channel (spec §1.2: "~30 kHz per channel,
 *    aggregate ~90 kHz").
 *
 *    In a round-robin loop each channel is sampled every
 *    PIEZO_CHANNEL_INTERVAL_US = 33 µs (≈ 30.3 kHz per channel).
 *    analogRead() on ESP32-C3 takes ~5–15 µs, so the inter-sample
 *    busy-wait is typically 18–28 µs — well within one cycle.
 *
 *    The aggregate sample rate across all three channels is
 *    ~90 kHz — within the ADC1's ~100 kHz practical ceiling.
 *
 *  ── Piezo signal chain (each channel identical) ──────────────────────────
 *
 *    Piezo disc
 *      ├── 1 MΩ to GND          (bias / load resistor)
 *      └──→ TL072 non-inverting input (pin 3)
 *              ├── DC bias: R-divider to ~1.65 V  (keeps signal mid-rail)
 *              └──→ TL072 output (pin 1)
 *                      ├── 3.3 V Zener to GND     ← MANDATORY
 *                      └──→ GPIO 1 / 2 / 3
 *
 *    NEVER connect raw piezo to any GPIO.  50 V+ spikes will destroy the
 *    ESP32 instantly without the Zener clamp.
 *
 *  ── Power rails ──────────────────────────────────────────────────────────
 *
 *    5 V input  → SG90 servo + LDO input
 *    3.3 V LDO  → TL072 × 3 (one per channel), MPU-6050
 *    100 nF ceramic decoupling cap per TL072 supply pin to GND.
 *    Separate LDO outputs for servo and analog rail recommended to
 *    prevent PWM switching noise from coupling into the ADC inputs.
 */

#pragma once

// ── Servo ─────────────────────────────────────────────────────────────────────
#define PIN_SERVO                0   // SG90 PWM signal (GPIO 0)

// ── Piezo channels — all on ADC1 (Wi-Fi safe) ────────────────────────────────
#define PIN_PIEZO_A              1   // TL072 Ch A → ADC1_CH1 (primary / trigger)
#define PIN_PIEZO_B              2   // TL072 Ch B → ADC1_CH2
#define PIN_PIEZO_C              3   // TL072 Ch C → ADC1_CH3

// Total number of active piezo channels.
#define PIEZO_CHANNEL_COUNT      3

// ADC1 channel numbers corresponding to each GPIO (for esp_adc_cal_* API).
#define ADC1_CH_A    ADC1_CHANNEL_1   // GPIO 1
#define ADC1_CH_B    ADC1_CHANNEL_2   // GPIO 2
#define ADC1_CH_C    ADC1_CHANNEL_3   // GPIO 3

// Convenience array — iterate with: for (int i = 0; i < PIEZO_CHANNEL_COUNT; i++)
#define PIEZO_PINS  { PIN_PIEZO_A, PIN_PIEZO_B, PIN_PIEZO_C }

// ── MPU-6050 accelerometer (supplemental, Mode 1 only) ───────────────────────
#define PIN_MPU_SDA              8   // I²C data  (GPIO 8, 400 kHz)
#define PIN_MPU_SCL              9   // I²C clock (GPIO 9, 400 kHz)

// ── Status LED ────────────────────────────────────────────────────────────────
#define PIN_LED                 10   // Active-HIGH (GPIO 10)

// ── MPU-6050 I²C config ───────────────────────────────────────────────────────
#define MPU6050_ADDR          0x68   // AD0 pulled LOW → default address
#define I2C_FREQ_HZ         400000   // 400 kHz fast mode

// =============================================================================
// ADC sampling parameters
// =============================================================================

// ── Per-channel sample rate (spec §1.2) ──────────────────────────────────────
// 30 kHz per channel × 3 channels = 90 kHz aggregate.
// Each channel gets a time slot of 1/30000 s ≈ 33 µs.
#define PIEZO_CHANNEL_RATE_HZ    30000   // per-channel sample rate
#define PIEZO_CHANNEL_INTERVAL_US   33   // 1 / 30000 Hz ≈ 33 µs per channel slot

// Round-robin cycle time: all 3 channels in one revolution.
// Each revolution = 3 × 33 µs = 99 µs ≈ 100 µs (≈ 10 kHz frame rate).
// The mobile app receives one frame of PIEZO_FRAME_SAMPLES per channel per
// UDP packet, so each node emits 3 packets per frame interval.
#define PIEZO_ROUND_ROBIN_US    (PIEZO_CHANNEL_COUNT * PIEZO_CHANNEL_INTERVAL_US)

// ── Frame parameters ──────────────────────────────────────────────────────────
// One UDP packet = 100 samples × 1 channel = 10 ms @ 10 kHz effective rate
// (each channel's 30 kHz samples are decimated 3× in the round-robin loop,
//  giving a per-channel effective rate of 30 kHz when each channel is
//  captured every PIEZO_CHANNEL_INTERVAL_US).
//
// Mobile app frame size matches: PIEZO_FRAME_SAMPLES = 100 samples/packet.
#define PIEZO_FRAME_SAMPLES       100   // samples per channel per UDP packet

// ── ADC scaling ───────────────────────────────────────────────────────────────
// 12-bit → centred int16: (raw - midpoint) × scale → ±(midpoint × scale)
#define PIEZO_ADC_MIDPOINT       2048   // DC bias target (half of 4095)
#define PIEZO_ADC_SCALE             8   // stretches 12-bit to ~16-bit range

// ── UDP stream ────────────────────────────────────────────────────────────────
#define UDP_AUDIO_PORT           9000   // mobile app listens on this port
#define UDP_BCAST_ADDR    "255.255.255.255"

// ── WebSocket ─────────────────────────────────────────────────────────────────
#define WS_PORT                    81

// =============================================================================
// Mode 1 — Active NDT tap capture
// =============================================================================

// Post-impact piezo waveform capture window per channel (spec §5.1).
// 500 samples × 33 µs/sample ≈ 16.5 ms per channel.
// The interrupt always fires on PIN_PIEZO_A (primary channel / trigger).
#define PIEZO_TAP_SAMPLES         500   // per channel

// MPU-6050 supplemental Z-axis capture.
#define MPU_SAMPLE_COUNT          150   // 300 ms @ 500 Hz
#define MPU_SAMPLE_DELAY_US      2000   // 2 ms inter-sample → 500 Hz

// ── Servo positions ───────────────────────────────────────────────────────────
#define SERVO_IDLE_DEG              0
#define SERVO_STRIKE_DEG           45
#define SERVO_STRIKE_TIMEOUT_US 100000  // 100 ms max wait for piezo trigger
