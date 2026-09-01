/**
 * mpu6050.h — GY-521 / MPU-6050 accelerometer driver (Mode 1: active NDT)
 *
 * Provides:
 *   - mpuSetup()     — wake the sensor and configure ±2g, 400 kHz I²C
 *   - mpuReadAccelZ() — read one raw Z-axis sample (int16, ±2g = ±32768)
 *   - mpuCaptureSamples() — capture MPU_SAMPLE_COUNT samples at 500 Hz
 *
 * Pin assignments (from pins.h):
 *   GPIO 8  — SDA (I²C data)
 *   GPIO 9  — SCL (I²C clock, 400 kHz)
 *   MPU-6050 I²C address: 0x68 (AD0 pulled LOW)
 *
 * Register map references (MPU-6050 datasheet):
 *   0x6B — PWR_MGMT_1  : set 0x00 to wake from sleep
 *   0x1C — ACCEL_CONFIG : bits [4:3] select full-scale range
 *                         0x00 = ±2g (16384 LSB/g) — best resolution
 *   0x3D — ACCEL_ZOUT_H : high byte of Z-axis output (low byte = 0x3E)
 */

#pragma once

#include <Wire.h>
#include "pins.h"

// ── MPU-6050 register addresses ───────────────────────────────────────────────
#define MPU_REG_PWR_MGMT_1    0x6B
#define MPU_REG_ACCEL_CONFIG  0x1C
#define MPU_REG_ACCEL_ZOUT_H  0x3D

// ── Full-scale range setting ──────────────────────────────────────────────────
// ACCEL_FS_SEL bits [4:3] in ACCEL_CONFIG:
//   0x00 = ±2g  (16384 LSB/g)  ← used here for maximum resolution
//   0x08 = ±4g  (8192  LSB/g)
//   0x10 = ±8g  (4096  LSB/g)
//   0x18 = ±16g (2048  LSB/g)
#define MPU_ACCEL_FS_2G       0x00

/**
 * Initialise the MPU-6050.
 * - Starts Wire on GPIO 8 (SDA) / GPIO 9 (SCL) at 400 kHz.
 * - Wakes the chip from its default sleep state.
 * - Sets full-scale range to ±2g for maximum sensitivity.
 * Call once from setup().
 */
void mpuSetup() {
  Wire.begin(PIN_MPU_SDA, PIN_MPU_SCL, I2C_FREQ_HZ);

  // Wake from sleep (PWR_MGMT_1 = 0x00 clears SLEEP bit).
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(MPU_REG_PWR_MGMT_1);
  Wire.write(0x00);
  Wire.endTransmission(true);

  // Configure ±2g full-scale range.
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(MPU_REG_ACCEL_CONFIG);
  Wire.write(MPU_ACCEL_FS_2G);
  Wire.endTransmission(true);

  Serial.printf("[MPU] Init OK — addr=0x%02X, SDA=GPIO%d, SCL=GPIO%d, "
                "I2C=%d Hz, range=±2g\n",
                MPU6050_ADDR, PIN_MPU_SDA, PIN_MPU_SCL, I2C_FREQ_HZ);
}

/**
 * Read a single Z-axis acceleration sample.
 * @return Raw int16 value (-32768 … +32767).
 *         Divide by 16384.0f to get g-force.
 */
int16_t mpuReadAccelZ() {
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(MPU_REG_ACCEL_ZOUT_H);     // auto-increments to 0x3E
  Wire.endTransmission(false);           // repeated start

  Wire.requestFrom((uint8_t)MPU6050_ADDR, (size_t)2, true);
  if (Wire.available() < 2) { return 0; }

  const int16_t hi = Wire.read();
  const int16_t lo = Wire.read();
  return (int16_t)((hi << 8) | lo);
}

/**
 * Capture MPU_SAMPLE_COUNT Z-axis samples at 500 Hz (2 ms interval)
 * into the provided buffer.
 *
 * @param buf     Output array, must be at least MPU_SAMPLE_COUNT elements.
 * @param refUs   Hardware µs timestamp of the start of capture (from micros()).
 *                Pass the piezo trigger timestamp if available so the travel-
 *                time calculation in the mobile app can reference the same T0.
 *
 * Blocks for ~300 ms (150 samples × 2 ms). Do not call from an ISR.
 */
void mpuCaptureSamples(int16_t *buf, uint32_t refUs) {
  for (int i = 0; i < MPU_SAMPLE_COUNT; i++) {
    const uint32_t t0 = micros();
    buf[i] = mpuReadAccelZ();
    // Busy-wait to maintain 500 Hz — Wire.requestFrom is fast enough
    // that the remainder is typically 1.5–1.9 ms.
    while ((micros() - t0) < MPU_SAMPLE_DELAY_US) { /* spin */ }
  }
}
