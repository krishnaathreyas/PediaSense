/**
 * PediaSense — ESP32 Firmware
 * ───────────────────────────────────────────────────────────────────────
 * Sensor layer   : PPG (MAX30102), IMU (MPU6050), Temp (MLX90614), Mic
 * (INMP441) Processing     : Breathing rate, Apnea detection, Cry detection
 * Fusion         : Risk engine (respiratory + hydration scores), Classifier
 * Comms          : BLE GATT server with 4 notify characteristics
 *
 * Pin assignment (ESP32 WROOM-32):
 *   I2C  SDA = GPIO21 | SCL = GPIO22
 *   I2S  SCK = GPIO26 | WS  = GPIO25 | SD = GPIO34
 *
 * Set BIRTH_WEIGHT_KG to the baby's actual birth weight (kg).
 * Values below 2.5 kg enable Low-Birth-Weight (LBW) mode which
 * tightens all clinical thresholds.
 * ───────────────────────────────────────────────────────────────────────
 */

#include <Arduino.h>
#include <Wire.h>

// Sensors
#include "sensors/imu.h"
#include "sensors/mic.h"
#include "sensors/ppg.h"
#include "sensors/temp.h"

// Processing
#include "processing/apnea.h"
#include "processing/breathing.h"
#include "processing/cry.h"

// Fusion
#include "fusion/classifier.h"
#include "fusion/risk_engine.h"

// Comms
#include "comms/ble_server.h"

// ── Configuration
// ─────────────────────────────────────────────────────────────
static const float BIRTH_WEIGHT_KG = 3.2f; // <-- set per patient
static const int LOOP_PERIOD_MS =
    20; // ~50 Hz main loop (drains PPG FIFO in time)
static const bool ENABLE_TEMP_SENSOR = true;
static const bool ENABLE_MIC_SENSOR = true;
static const bool ENABLE_ADVANCED_PROCESSING = false;

// ── Serial debug helpers
// ──────────────────────────────────────────────────────
static void print_status() {
  const PpgData &ppg = ppg_get();
  const ImuData &imu = imu_get();
  const TempData &tmp = temp_get();
  const MicData &mic = mic_get();

  // Real-only output: no fallback/synthetic values.
  const float shown_temp = tmp.valid ? tmp.skin_c : -999.0f;
  Serial.printf(
      "HR=%d bpm | SpO2=%d%% | MIC_RMS=%.0f MIC_PEAK=%ld MIC_ACTIVE=%d | "
      "GYRO=%.1f,%.1f,%.1f dps | TEMP=%.1fC\n",
      ppg.hr, ppg.spo2, mic.rms, (long)mic.peak, mic.active ? 1 : 0, imu.gx,
      imu.gy, imu.gz, shown_temp);
}

// ── Setup
// ─────────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(400);
  Serial.println("\n[PediaSense] Starting up...");

  // I2C bus — max speed 400 kHz (individual drivers override if needed)
  Serial.println("[BOOT] I2C begin");
  Wire.begin(21, 22);
  Wire.setClock(400000);
  Serial.println("[BOOT] I2C ready");

  // Sensors
  Serial.println("[BOOT] PPG init...");
  if (!ppg_init())
    Serial.println("[WARN] PPG init failed");
  Serial.println("[BOOT] PPG done");

  Serial.println("[BOOT] IMU init...");
  if (!imu_init())
    Serial.println("[WARN] IMU init failed");
  Serial.println("[BOOT] IMU done");

  if (ENABLE_TEMP_SENSOR) {
    Serial.println("[BOOT] TEMP init...");
    if (!temp_init())
      Serial.println("[WARN] TEMP init failed");
    Serial.println("[BOOT] TEMP done");
  }
  if (ENABLE_MIC_SENSOR) {
    Serial.println("[BOOT] MIC init...");
    mic_init();
    Serial.println("[BOOT] MIC done");
  }

  // Processing
  Serial.println("[BOOT] Processing init...");
  breathing_init();
  if (ENABLE_ADVANCED_PROCESSING) {
    apnea_init();
    cry_init();
  }
  Serial.println("[BOOT] Processing ready");

  // Fusion
  if (ENABLE_ADVANCED_PROCESSING) {
    Serial.println("[BOOT] Fusion init...");
    risk_engine_init(BIRTH_WEIGHT_KG);
    classifier_init();
    Serial.println("[BOOT] Fusion ready");
  }

  // Comms
  Serial.println("[BOOT] BLE init...");
  ble_server_init("PediaSense");
  Serial.println("[BOOT] BLE ready");

  Serial.println("[PediaSense] Ready.");
}

// ── Loop
// ──────────────────────────────────────────────────────────────────────
void loop() {
  static unsigned long prev_ms = 0;
  unsigned long now = millis();
  if (now - prev_ms < (unsigned long)LOOP_PERIOD_MS)
    return;
  prev_ms = now;

  // 1 — Read sensors
  ppg_update();
  imu_update();
  if (ENABLE_TEMP_SENSOR)
    temp_update();
  if (ENABLE_MIC_SENSOR)
    mic_update();

  // 2 — Process signals
  breathing_update();
  if (ENABLE_ADVANCED_PROCESSING) {
    apnea_update();
    cry_update();
  }

  // 3 — Fuse & classify
  if (ENABLE_ADVANCED_PROCESSING) {
    risk_engine_update();
    classifier_update();
  }

  // 4 — Transmit over BLE
  ble_server_notify();

  // 5 — Debug print every 2 seconds
  static unsigned long debug_ms = 0;
  if (now - debug_ms >= 2000) {
    debug_ms = now;
    print_status();
  }
}
