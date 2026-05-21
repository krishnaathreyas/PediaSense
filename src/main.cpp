/*
 * ============================================================
 *  PediaSense — ESP32 Edge Firmware
 *  AI + IoT Neonatal (12-24 mo) Monitoring System
 * ============================================================
 *  Hardware:
 *    MAX30102  – Heart Rate + SpO2        ← SIMULATED (see flag below)
 *    MPU6050   – Breathing Rate (chest motion)
 *    DHT22     – Skin Temperature
 *    INMP441   – On-demand cry audio (I2S)
 *
 *  BLE:
 *    Name        : ESP32_BLE
 *    Vitals JSON : every 3 s  {"hr":115,"spo2":98,"br":32,"skin_temp":36.7}
 *    Audio       : chunked on START_CRY_CAPTURE command
 * ============================================================
 */

// ─────────────────────────────────────────────────────────────
//  ██████████████████████████████████████████████████████████
//  SIMULATION CONTROL FLAG
//  Set to true  → synthetic HR + SpO2 (MAX30102 not required)
//  Set to false → real MAX30102 hardware readings
//  ██████████████████████████████████████████████████████████
// ─────────────────────────────────────────────────────────────
#define USE_SIMULATED_MAX30102 true

// ─────────────────────────────────────────────────────────────
//  INCLUDES
// ─────────────────────────────────────────────────────────────
#include <Arduino.h>
#include <Wire.h>
#include <math.h>

// BLE
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

// Sensors — always include headers; real sensor init is guarded by flag
#include "MAX30105.h"       // SparkFun MAX3010x library
#include "heartRate.h"      // SparkFun beat-detection helper
#include "spo2_algorithm.h" // SparkFun SpO2 algorithm
#include <DHT.h>
#include <MPU6050.h> // Electronic Cats / TDK MPU6050

// I2S (INMP441)
#include <driver/i2s.h>

// JSON
#include <ArduinoJson.h>

// ─────────────────────────────────────────────────────────────
//  PIN DEFINITIONS
// ─────────────────────────────────────────────────────────────
#define DHT_PIN 4 // DHT22 data pin
#define DHT_TYPE DHT22

// INMP441 I2S pins
#define I2S_WS_PIN 25  // Word-Select (LRCK)
#define I2S_SCK_PIN 26 // Serial Clock (BCLK)
#define I2S_SD_PIN 34  // Serial Data  (SD)  — input only GPIO

// MAX30102 & MPU6050 share I2C (SDA=21, SCL=22 by default on ESP32)

// ─────────────────────────────────────────────────────────────
//  BLE UUIDS
// ─────────────────────────────────────────────────────────────
#define BLE_DEVICE_NAME "ESP32_BLE"
#define SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define VITALS_CHAR_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define COMMAND_CHAR_UUID "c8d2f3a1-2b74-4f2e-bab1-3e9fc3e2e567"
#define AUDIO_CHAR_UUID "d1e2f3a4-5b6c-7d8e-9f0a-1b2c3d4e5f60"

// ─────────────────────────────────────────────────────────────
//  BLE COMMANDS
// ─────────────────────────────────────────────────────────────
#define CMD_START_CRY "START_CRY_CAPTURE"
#define CMD_STOP_CRY "STOP_CRY_CAPTURE"

// ─────────────────────────────────────────────────────────────
//  TIMING
// ─────────────────────────────────────────────────────────────
#define VITALS_INTERVAL_MS 3000UL
#define BR_WINDOW_MS 15000UL     // 15-second breathing estimation window
#define MAX30102_SAMPLE_RATE 100 // Hz – samples collected per second

// ─────────────────────────────────────────────────────────────
//  AUDIO CONSTANTS
// ─────────────────────────────────────────────────────────────
#define AUDIO_SAMPLE_RATE 16000
#define AUDIO_RECORD_SECONDS 5
#define AUDIO_TOTAL_SAMPLES (AUDIO_SAMPLE_RATE * AUDIO_RECORD_SECONDS)
#define AUDIO_BLE_CHUNK_BYTES 512 // bytes per BLE notification
#define I2S_PORT I2S_NUM_0
#define I2S_DMA_BUF_COUNT 8
#define I2S_DMA_BUF_LEN 1024

// ─────────────────────────────────────────────────────────────
//  MAX30102 BUFFER SIZE (SparkFun algorithm needs 100 samples)
// ─────────────────────────────────────────────────────────────
#define MAX30102_BUF_LEN 100

// ─────────────────────────────────────────────────────────────
//  BREATHING RATE CONSTANTS
// ─────────────────────────────────────────────────────────────
#define BR_ACCEL_HISTORY_LEN 300      // ~15 s at ~20 Hz MPU polling
#define BR_MA_WINDOW 10               // moving-average half-window
#define BR_MIN_PEAK_DISTANCE_MS 400   // >150 bpm impossible for breathing
#define BR_MAX_PEAK_DISTANCE_MS 6000  // <10 br/min = apnoea alert threshold
#define BR_PEAK_THRESHOLD_FACTOR 0.3f // adaptive: 30 % of amplitude

// ─────────────────────────────────────────────────────────────
//  HEART RATE VALIDATION
// ─────────────────────────────────────────────────────────────
#define HR_MIN_VALID 60
#define HR_MAX_VALID 220
#define SPO2_MIN_VALID 80

// ─────────────────────────────────────────────────────────────
//  SENSOR OBJECTS
// ─────────────────────────────────────────────────────────────
#if !USE_SIMULATED_MAX30102
MAX30105 particleSensor;
#endif

MPU6050 mpu;
DHT dht(DHT_PIN, DHT_TYPE);

// ─────────────────────────────────────────────────────────────
//  BLE OBJECTS
// ─────────────────────────────────────────────────────────────
BLEServer *pServer = nullptr;
BLECharacteristic *pVitalsChar = nullptr;
BLECharacteristic *pCommandChar = nullptr;
BLECharacteristic *pAudioChar = nullptr;
bool bleConnected = false;
bool bleWasConnected = false;

// ─────────────────────────────────────────────────────────────
//  MAX30102 STATE  (used by both real and simulated paths)
// ─────────────────────────────────────────────────────────────
#if !USE_SIMULATED_MAX30102
uint32_t irBuffer[MAX30102_BUF_LEN];
uint32_t redBuffer[MAX30102_BUF_LEN];
int32_t spo2Value = 0;
int8_t spo2Valid = 0;
int32_t heartRateValue = 0;
int8_t heartRateValid = 0;
bool sensorContact = false;
unsigned long lastMax30102Fill = 0;
#endif

// Smoothed outputs — written by either path, consumed by sendVitalsBLE()
float smoothedHR = 0.0f;
float smoothedSpO2 = 0.0f;

// ─────────────────────────────────────────────────────────────
//  ██  SIMULATION STATE  ██
//  All variables in this block are only used when
//  USE_SIMULATED_MAX30102 == true.
//  To restore real hardware: flip the flag above.
// ─────────────────────────────────────────────────────────────
#if USE_SIMULATED_MAX30102

// ── Target "resting" centre-points ──────────────────────────
#define SIM_HR_BASE 130.0f  // bpm  — mid neonatal resting HR
#define SIM_SPO2_BASE 97.0f // %    — healthy neonatal SpO2

// ── Sinusoidal drift parameters ─────────────────────────────
//    HR drifts on a slow ~90-second cycle ±8 bpm
//    SpO2 drifts on a slower ~120-second cycle ±1.5 %
#define SIM_HR_AMP 8.0f          // bpm  peak-to-peak half-amplitude
#define SIM_SPO2_AMP 1.5f        // %    peak-to-peak half-amplitude
#define SIM_HR_PERIOD_S 90.0f    // seconds per full HR cycle
#define SIM_SPO2_PERIOD_S 120.0f // seconds per full SpO2 cycle

// ── Low-frequency noise parameters ──────────────────────────
//    A second, faster sinusoid at a non-harmonic frequency
//    mimics breath-to-breath and autonomic HRV without
//    introducing true randomness (deterministic, reproducible).
#define SIM_HR_NOISE_AMP 3.0f       // bpm
#define SIM_HR_NOISE_PERIOD_S 17.0f // ~17-second secondary cycle (non-harmonic)
#define SIM_SPO2_NOISE_AMP 0.5f     // %
#define SIM_SPO2_NOISE_PERIOD_S 23.0f // ~23-second secondary cycle

// ── Hard physiological clamps ────────────────────────────────
#define SIM_HR_MIN 110.0f
#define SIM_HR_MAX 160.0f
#define SIM_SPO2_MIN 94.0f
#define SIM_SPO2_MAX 100.0f

// Update interval — matches the real sensor's 250 ms update cadence
#define SIM_UPDATE_INTERVAL_MS 250UL
static unsigned long lastSimUpdate = 0;

// Phase offsets so HR and SpO2 cycles are independent at boot
#define SIM_HR_PHASE_OFFSET 0.0f
#define SIM_SPO2_PHASE_OFFSET 1.2f // radians

// ── Public function prototypes for simulated path ────────────
void setupSimulatedMAX30102();
void updateSimulatedMAX30102();

#endif // USE_SIMULATED_MAX30102
// ─────────────────────────────────────────────────────────────
//  END SIMULATION STATE BLOCK
// ─────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────
//  MPU6050 / BREATHING STATE
// ─────────────────────────────────────────────────────────────
struct AccelSample {
  float value;
  unsigned long timestamp;
};
AccelSample brHistory[BR_ACCEL_HISTORY_LEN];
uint16_t brHistIdx = 0;
uint16_t brHistCount = 0;
float smoothedBR = 0.0f;
unsigned long lastMpuRead = 0;

// ─────────────────────────────────────────────────────────────
//  DHT STATE
// ─────────────────────────────────────────────────────────────
float smoothedTemp = 37.0f;

// ─────────────────────────────────────────────────────────────
//  AUDIO STATE
// ─────────────────────────────────────────────────────────────
volatile bool cryCapture = false;
volatile bool stopCryRequest = false;
bool i2sInitialised = false;

// ─────────────────────────────────────────────────────────────
//  TIMING
// ─────────────────────────────────────────────────────────────
unsigned long lastVitalsTime = 0;

// ─────────────────────────────────────────────────────────────
//  FORWARD DECLARATIONS
// ─────────────────────────────────────────────────────────────
void setupBLE();
void setupMPU6050();
void setupDHT();

#if USE_SIMULATED_MAX30102
void setupSimulatedMAX30102();
void updateSimulatedMAX30102();
#else
void setupMAX30102();
void updateMAX30102();
#endif

void updateMPU6050();
void updateDHT();

float estimateBreathingRate();
float computeMovingAverage(float *arr, uint16_t len, uint16_t windowSize);
int detectPeaks(float *signal, uint16_t len, unsigned long *timestamps,
                uint16_t *peakIndices, uint16_t maxPeaks,
                float adaptiveThreshold);

void sendVitalsBLE();
void handleCryCapture();

void startI2SMic();
void stopI2SMic();
void streamAudioBLE();

String buildVitalsJSON(float hr, float spo2, float br, float temp);

// ─────────────────────────────────────────────────────────────
//  BLE CALLBACKS
// ─────────────────────────────────────────────────────────────
class PediaSenseServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *pSvr) override {
    bleConnected = true;
    Serial.println("[BLE] Client connected.");
    // BLEDevice::stopAdvertising();
  }
  void onDisconnect(BLEServer *pSvr) override {
    bleConnected = false;
    bleWasConnected = true;
    cryCapture = false;
    Serial.println("[BLE] Client disconnected.");
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pChar) override {
    String value = pChar->getValue();
    if (value.isEmpty())
      return;

    String cmd = String(value.c_str());
    cmd.trim();

    Serial.print("[CMD] Received: ");
    Serial.println(cmd);

    if (cmd == CMD_START_CRY) {
      if (!cryCapture) {
        cryCapture = true;
        stopCryRequest = false;
        Serial.println("[CMD] Cry capture STARTED.");
      }
    } else if (cmd == CMD_STOP_CRY) {
      if (cryCapture) {
        stopCryRequest = true;
        Serial.println("[CMD] Cry capture STOP requested.");
      }
    } else {
      Serial.println("[CMD] Unknown command ignored.");
    }
  }
};

// ─────────────────────────────────────────────────────────────
//  SETUP
// ─────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("\n[PediaSense] Booting...");

#if USE_SIMULATED_MAX30102
  Serial.println(
      "[PediaSense] MAX30102 mode: SIMULATED (synthetic neonatal vitals)");
#else
  Serial.println("[PediaSense] MAX30102 mode: REAL HARDWARE");
#endif

  Wire.begin();
  Wire.setClock(400000); // 400 kHz I2C

  setupDHT();

#if USE_SIMULATED_MAX30102
  setupSimulatedMAX30102();
#else
  setupMAX30102();
#endif

  setupMPU6050();
  setupBLE();

  memset(brHistory, 0, sizeof(brHistory));

  lastVitalsTime = millis();
  lastMpuRead = millis();

  Serial.println("[PediaSense] Ready.");
}

// ─────────────────────────────────────────────────────────────
//  MAIN LOOP
// ─────────────────────────────────────────────────────────────
void loop() {
  // ── BLE reconnect ──────────────────────────────────────────
  if (bleWasConnected && !bleConnected) {
    delay(300);
    pServer->startAdvertising();
    Serial.println("[BLE] Restarted advertising.");
    bleWasConnected = false;
  }

  // ── Continuous sensor / simulation updates ─────────────────
#if USE_SIMULATED_MAX30102
  updateSimulatedMAX30102();
#else
  updateMAX30102();
#endif

  updateMPU6050();
  updateDHT();

  // ── Periodic vitals transmission ───────────────────────────
  unsigned long now = millis();
  if (now - lastVitalsTime >= VITALS_INTERVAL_MS) {
    lastVitalsTime = now;
    if (bleConnected) {
      sendVitalsBLE();
    }
  }

  // ── On-demand cry capture ───────────────────────────────────
  if (cryCapture) {
    handleCryCapture();
    cryCapture = false;
  }

  yield();
}

// ═════════════════════════════════════════════════════════════
//  ██  SIMULATED MAX30102 IMPLEMENTATION  ██
//
//  Algorithm:
//    value = BASE
//          + AMP        * sin(2π * t / PERIOD        + PHASE)   ← slow drift
//          + NOISE_AMP  * sin(2π * t / NOISE_PERIOD  + PHASE)   ← HRV-like
//          noise
//
//  Both sinusoids are deterministic and phase-continuous.
//  No rand() calls → perfectly smooth, no sudden jumps.
//  The non-harmonic periods ensure the combined waveform never
//  exactly repeats within a clinical monitoring session.
//
//  TO RESTORE REAL SENSOR: set USE_SIMULATED_MAX30102 false.
//  The real setupMAX30102() / updateMAX30102() below are fully
//  preserved and will compile / run without any other changes.
// ═════════════════════════════════════════════════════════════
#if USE_SIMULATED_MAX30102

void setupSimulatedMAX30102() {
  // Seed smoothed values at physiological centre-points so the
  // first BLE notification is already a valid neonatal reading.
  smoothedHR = SIM_HR_BASE;
  smoothedSpO2 = SIM_SPO2_BASE;
  lastSimUpdate = millis();
  Serial.println("[SIM-MAX30102] Synthetic vitals initialised.");
  Serial.printf("[SIM-MAX30102] HR  centre=%.0f bpm  drift±%.0f bpm\n",
                SIM_HR_BASE, SIM_HR_AMP);
  Serial.printf("[SIM-MAX30102] SpO2 centre=%.1f%%  drift±%.1f%%\n",
                SIM_SPO2_BASE, SIM_SPO2_AMP);
}

void updateSimulatedMAX30102() {
  if (millis() - lastSimUpdate < SIM_UPDATE_INTERVAL_MS)
    return;
  lastSimUpdate = millis();

  // Time in seconds since boot (floating point for smooth sinusoids)
  float t = (float)millis() / 1000.0f;

  // ── Simulated Heart Rate ────────────────────────────────────
  float hrRaw =
      SIM_HR_BASE +
      SIM_HR_AMP * sinf(TWO_PI * t / SIM_HR_PERIOD_S + SIM_HR_PHASE_OFFSET) +
      SIM_HR_NOISE_AMP * sinf(TWO_PI * t / SIM_HR_NOISE_PERIOD_S + 0.7f);

  hrRaw = constrain(hrRaw, SIM_HR_MIN, SIM_HR_MAX);

  // Light EMA to match real sensor smoothing behaviour (α = 0.2)
  if (smoothedHR < HR_MIN_VALID) {
    smoothedHR = hrRaw; // cold-start
  } else {
    smoothedHR = 0.8f * smoothedHR + 0.2f * hrRaw;
  }

  // ── Simulated SpO2 ──────────────────────────────────────────
  float spo2Raw =
      SIM_SPO2_BASE +
      SIM_SPO2_AMP *
          sinf(TWO_PI * t / SIM_SPO2_PERIOD_S + SIM_SPO2_PHASE_OFFSET) +
      SIM_SPO2_NOISE_AMP * sinf(TWO_PI * t / SIM_SPO2_NOISE_PERIOD_S + 1.9f);

  spo2Raw = constrain(spo2Raw, SIM_SPO2_MIN, SIM_SPO2_MAX);

  // SpO2 EMA (α = 0.1 — slower, matching real sensor smoothing)
  if (smoothedSpO2 < SPO2_MIN_VALID) {
    smoothedSpO2 = spo2Raw;
  } else {
    smoothedSpO2 = 0.9f * smoothedSpO2 + 0.1f * spo2Raw;
  }
}

#endif // USE_SIMULATED_MAX30102
// ─────────────────────────────────────────────────────────────
//  END SIMULATED MAX30102 IMPLEMENTATION
// ─────────────────────────────────────────────────────────────

// ═════════════════════════════════════════════════════════════
//  REAL MAX30102 IMPLEMENTATION
//  Compiled only when USE_SIMULATED_MAX30102 == false.
//  No changes from original production code.
// ═════════════════════════════════════════════════════════════
#if !USE_SIMULATED_MAX30102

void setupMAX30102() {
  if (!particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("[MAX30102] ERROR: Sensor not found! Check wiring.");
    return;
  }

  particleSensor.setup(60,  // LED brightness
                       4,   // sampleAverage
                       2,   // ledMode: Red + IR
                       400, // sampleRate
                       411, // pulseWidth
                       4096 // adcRange
  );

  particleSensor.setPulseAmplitudeRed(0x1F);
  particleSensor.setPulseAmplitudeIR(0x1F);
  particleSensor.setPulseAmplitudeGreen(0);

  Serial.println("[MAX30102] Initialised.");

  for (int i = 0; i < MAX30102_BUF_LEN; i++) {
    while (!particleSensor.available())
      particleSensor.check();
    redBuffer[i] = particleSensor.getRed();
    irBuffer[i] = particleSensor.getIR();
    particleSensor.nextSample();
  }

  maxim_heart_rate_and_oxygen_saturation(irBuffer, MAX30102_BUF_LEN, redBuffer,
                                         &spo2Value, &spo2Valid,
                                         &heartRateValue, &heartRateValid);

  smoothedHR = heartRateValid ? (float)heartRateValue : 0.0f;
  smoothedSpO2 = spo2Valid ? (float)spo2Value : 0.0f;

  lastMax30102Fill = millis();
  Serial.println("[MAX30102] Buffer primed.");
}

void updateMAX30102() {
  const uint8_t SHIFT_AMOUNT = 25;

  if (millis() - lastMax30102Fill < 250)
    return;
  lastMax30102Fill = millis();

  for (uint8_t i = SHIFT_AMOUNT; i < MAX30102_BUF_LEN; i++) {
    redBuffer[i - SHIFT_AMOUNT] = redBuffer[i];
    irBuffer[i - SHIFT_AMOUNT] = irBuffer[i];
  }

  for (uint8_t i = MAX30102_BUF_LEN - SHIFT_AMOUNT; i < MAX30102_BUF_LEN; i++) {
    while (!particleSensor.available()) {
      particleSensor.check();
      yield();
    }
    redBuffer[i] = particleSensor.getRed();
    irBuffer[i] = particleSensor.getIR();
    particleSensor.nextSample();
  }

  uint32_t irAvg = 0;
  for (int i = 0; i < MAX30102_BUF_LEN; i++)
    irAvg += irBuffer[i];
  irAvg /= MAX30102_BUF_LEN;
  sensorContact = (irAvg > 50000);

  if (!sensorContact) {
    smoothedHR = 0.0f;
    smoothedSpO2 = 0.0f;
    return;
  }

  maxim_heart_rate_and_oxygen_saturation(irBuffer, MAX30102_BUF_LEN, redBuffer,
                                         &spo2Value, &spo2Valid,
                                         &heartRateValue, &heartRateValid);

  if (heartRateValid && heartRateValue >= HR_MIN_VALID &&
      heartRateValue <= HR_MAX_VALID) {
    if (smoothedHR < HR_MIN_VALID) {
      smoothedHR = (float)heartRateValue;
    } else {
      smoothedHR = 0.8f * smoothedHR + 0.2f * (float)heartRateValue;
    }
  }

  if (spo2Valid && spo2Value >= SPO2_MIN_VALID && spo2Value <= 100) {
    if (smoothedSpO2 < SPO2_MIN_VALID) {
      smoothedSpO2 = (float)spo2Value;
    } else {
      smoothedSpO2 = 0.9f * smoothedSpO2 + 0.1f * (float)spo2Value;
    }
  }
}

#endif // !USE_SIMULATED_MAX30102
// ─────────────────────────────────────────────────────────────
//  END REAL MAX30102 IMPLEMENTATION
// ─────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────
//  BLE SETUP
// ─────────────────────────────────────────────────────────────
void setupBLE() {
  BLEDevice::init(BLE_DEVICE_NAME);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new PediaSenseServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  pVitalsChar = pService->createCharacteristic(
      VITALS_CHAR_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  pVitalsChar->addDescriptor(new BLE2902());

  pCommandChar = pService->createCharacteristic(
      COMMAND_CHAR_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  pCommandChar->setCallbacks(new CommandCallbacks());

  pAudioChar = pService->createCharacteristic(
      AUDIO_CHAR_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  pAudioChar->addDescriptor(new BLE2902());

  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("[BLE] Server started, advertising as " BLE_DEVICE_NAME);
}

// ─────────────────────────────────────────────────────────────
//  MPU6050 SETUP  (unchanged)
// ─────────────────────────────────────────────────────────────
void setupMPU6050() {
  mpu.initialize();
  if (!mpu.testConnection()) {
    Serial.println("[MPU6050] ERROR: Connection test failed.");
    return;
  }
  mpu.setDLPFMode(MPU6050_DLPF_BW_10);
  mpu.setFullScaleAccelRange(MPU6050_ACCEL_FS_2);
  mpu.setFullScaleGyroRange(MPU6050_GYRO_FS_250);
  Serial.println("[MPU6050] Initialised.");
}

// ─────────────────────────────────────────────────────────────
//  DHT SETUP  (unchanged)
// ─────────────────────────────────────────────────────────────
void setupDHT() {
  dht.begin();
  delay(500);
  float t = dht.readTemperature();
  if (!isnan(t))
    smoothedTemp = t;
  Serial.println("[DHT22] Initialised.");
}

// ─────────────────────────────────────────────────────────────
//  MPU6050 NON-BLOCKING UPDATE  (unchanged)
// ─────────────────────────────────────────────────────────────
void updateMPU6050() {
  if (millis() - lastMpuRead < 50)
    return;
  lastMpuRead = millis();

  int16_t ax, ay, az, gx, gy, gz;
  mpu.getMotion6(&ax, &ay, &az, &gx, &gy, &gz);

  float axG = ax / 16384.0f;
  float ayG = ay / 16384.0f;
  float azG = az / 16384.0f;
  float mag = sqrtf(axG * axG + ayG * ayG + azG * azG);

  brHistory[brHistIdx].value = mag;
  brHistory[brHistIdx].timestamp = millis();
  brHistIdx = (brHistIdx + 1) % BR_ACCEL_HISTORY_LEN;
  if (brHistCount < BR_ACCEL_HISTORY_LEN)
    brHistCount++;
}

// ─────────────────────────────────────────────────────────────
//  DHT NON-BLOCKING UPDATE  (unchanged)
// ─────────────────────────────────────────────────────────────
static unsigned long lastDhtRead = 0;
void updateDHT() {
  if (millis() - lastDhtRead < 2100)
    return;
  lastDhtRead = millis();

  float t = dht.readTemperature();
  if (!isnan(t) && t > 20.0f && t < 45.0f) {
    smoothedTemp = 0.85f * smoothedTemp + 0.15f * t;
  }
}

// ─────────────────────────────────────────────────────────────
//  BREATHING RATE ESTIMATION  (unchanged)
// ─────────────────────────────────────────────────────────────
float estimateBreathingRate() {
  if (brHistCount < 60) {
    return (smoothedBR > 0.0f) ? smoothedBR : 30.0f;
  }

  uint16_t n = min((uint16_t)brHistCount, (uint16_t)BR_ACCEL_HISTORY_LEN);
  float *signal = (float *)malloc(n * sizeof(float));
  unsigned long *timestamps =
      (unsigned long *)malloc(n * sizeof(unsigned long));

  if (!signal || !timestamps) {
    free(signal);
    free(timestamps);
    return (smoothedBR > 0.0f) ? smoothedBR : 30.0f;
  }

  uint16_t startIdx = (brHistCount < BR_ACCEL_HISTORY_LEN) ? 0 : brHistIdx;

  for (uint16_t i = 0; i < n; i++) {
    uint16_t idx = (startIdx + i) % BR_ACCEL_HISTORY_LEN;
    signal[i] = brHistory[idx].value;
    timestamps[i] = brHistory[idx].timestamp;
  }

  float *smoothed = (float *)malloc(n * sizeof(float));
  if (!smoothed) {
    free(signal);
    free(timestamps);
    return smoothedBR;
  }

  for (uint16_t i = 0; i < n; i++) {
    float sum = 0;
    uint16_t cnt = 0;
    int16_t start = (int16_t)i - BR_MA_WINDOW;
    int16_t end = (int16_t)i + BR_MA_WINDOW;
    if (start < 0)
      start = 0;
    if (end >= n)
      end = n - 1;
    for (int16_t j = start; j <= end; j++) {
      sum += signal[j];
      cnt++;
    }
    smoothed[i] = sum / cnt;
  }

  float *detrended = (float *)malloc(n * sizeof(float));
  if (!detrended) {
    free(signal);
    free(timestamps);
    free(smoothed);
    return smoothedBR;
  }

  float sigMin = 1e9f, sigMax = -1e9f;
  for (uint16_t i = 0; i < n; i++) {
    detrended[i] = signal[i] - smoothed[i];
    if (detrended[i] < sigMin)
      sigMin = detrended[i];
    if (detrended[i] > sigMax)
      sigMax = detrended[i];
  }

  float amplitude = sigMax - sigMin;
  if (amplitude < 0.005f) {
    free(signal);
    free(timestamps);
    free(smoothed);
    free(detrended);
    return (smoothedBR > 0.0f) ? smoothedBR : 30.0f;
  }

  float adaptiveThreshold = sigMin + amplitude * BR_PEAK_THRESHOLD_FACTOR;

  uint16_t *peakIndices = (uint16_t *)malloc(n * sizeof(uint16_t));
  if (!peakIndices) {
    free(signal);
    free(timestamps);
    free(smoothed);
    free(detrended);
    return smoothedBR;
  }

  uint16_t numPeaks =
      detectPeaks(detrended, n, timestamps, peakIndices, n, adaptiveThreshold);

  float computedBR = 0.0f;

  if (numPeaks >= 2) {
    uint32_t totalInterval = 0;
    uint8_t validIntervals = 0;

    for (uint16_t i = 1; i < numPeaks; i++) {
      unsigned long dt =
          timestamps[peakIndices[i]] - timestamps[peakIndices[i - 1]];
      if (dt >= BR_MIN_PEAK_DISTANCE_MS && dt <= BR_MAX_PEAK_DISTANCE_MS) {
        totalInterval += dt;
        validIntervals++;
      }
    }

    if (validIntervals > 0) {
      float avgIntervalMs = (float)totalInterval / validIntervals;
      float avgIntervalSec = avgIntervalMs / 1000.0f;
      computedBR = 60.0f / avgIntervalSec;
      computedBR = constrain(computedBR, 20.0f, 80.0f);
    }
  }

  free(signal);
  free(timestamps);
  free(smoothed);
  free(detrended);
  free(peakIndices);

  if (computedBR > 0.0f) {
    if (smoothedBR < 1.0f) {
      smoothedBR = computedBR;
    } else {
      smoothedBR = 0.7f * smoothedBR + 0.3f * computedBR;
    }
  }

  return (smoothedBR > 0.0f) ? smoothedBR : 30.0f;
}

// ─────────────────────────────────────────────────────────────
//  PEAK DETECTION  (unchanged)
// ─────────────────────────────────────────────────────────────
int detectPeaks(float *signal, uint16_t len, unsigned long *timestamps,
                uint16_t *peakIndices, uint16_t maxPeaks, float threshold) {
  uint16_t count = 0;
  unsigned long lastPeakTime = 0;

  for (uint16_t i = 1; i < len - 1; i++) {
    if (signal[i] <= threshold)
      continue;
    if (signal[i] <= signal[i - 1])
      continue;
    if (signal[i] < signal[i + 1])
      continue;

    unsigned long peakTime = timestamps[i];
    if (lastPeakTime > 0) {
      unsigned long dt = peakTime - lastPeakTime;
      if (dt < BR_MIN_PEAK_DISTANCE_MS)
        continue;
    }

    peakIndices[count++] = i;
    lastPeakTime = peakTime;
    if (count >= maxPeaks)
      break;
  }
  return count;
}

// ─────────────────────────────────────────────────────────────
//  SEND VITALS VIA BLE  (unchanged)
// ─────────────────────────────────────────────────────────────
void sendVitalsBLE() {
  float br = estimateBreathingRate();
  float hr = (smoothedHR > 0) ? roundf(smoothedHR) : 0;
  float spo2 = (smoothedSpO2 > 0) ? roundf(smoothedSpO2) : 0;
  float temp = roundf(smoothedTemp * 10.0f) / 10.0f;

  String json = buildVitalsJSON(hr, spo2, br, temp);

  Serial.print("[VITALS] ");
  Serial.println(json);

  pVitalsChar->setValue(json.c_str());
  pVitalsChar->notify();
}

// ─────────────────────────────────────────────────────────────
//  BUILD VITALS JSON  (unchanged)
// ─────────────────────────────────────────────────────────────
String buildVitalsJSON(float hr, float spo2, float br, float temp) {
  StaticJsonDocument<128> doc;
  doc["hr"] = (int)hr;
  doc["spo2"] = (int)spo2;
  doc["br"] = (int)roundf(br);
  doc["skin_temp"] = serialized(String(temp, 1));

  String output;
  serializeJson(doc, output);
  return output;
}

// ─────────────────────────────────────────────────────────────
//  CRY CAPTURE HANDLER  (unchanged)
// ─────────────────────────────────────────────────────────────
void handleCryCapture() {
  if (!bleConnected)
    return;
  Serial.println("[AUDIO] Starting 5-second cry capture...");
  startI2SMic();
  streamAudioBLE();
  stopI2SMic();
  cryCapture = false;
  stopCryRequest = false;
  Serial.println("[AUDIO] Cry capture complete.");
}

// ─────────────────────────────────────────────────────────────
//  I2S MICROPHONE  (unchanged)
// ─────────────────────────────────────────────────────────────
void startI2SMic() {
  if (i2sInitialised)
    return;

  i2s_config_t i2sConfig = {.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
                            .sample_rate = AUDIO_SAMPLE_RATE,
                            .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
                            .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
                            .communication_format = I2S_COMM_FORMAT_STAND_I2S,
                            .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
                            .dma_buf_count = I2S_DMA_BUF_COUNT,
                            .dma_buf_len = I2S_DMA_BUF_LEN,
                            .use_apll = true,
                            .tx_desc_auto_clear = false,
                            .fixed_mclk = 0};

  i2s_pin_config_t pinConfig = {.bck_io_num = I2S_SCK_PIN,
                                .ws_io_num = I2S_WS_PIN,
                                .data_out_num = I2S_PIN_NO_CHANGE,
                                .data_in_num = I2S_SD_PIN};

  esp_err_t err;
  err = i2s_driver_install(I2S_PORT, &i2sConfig, 0, NULL);
  if (err != ESP_OK) {
    Serial.printf("[I2S] Driver install failed: %d\n", err);
    return;
  }

  err = i2s_set_pin(I2S_PORT, &pinConfig);
  if (err != ESP_OK) {
    Serial.printf("[I2S] Pin config failed: %d\n", err);
    i2s_driver_uninstall(I2S_PORT);
    return;
  }

  i2s_zero_dma_buffer(I2S_PORT);
  i2sInitialised = true;
  Serial.println("[I2S] INMP441 ready.");
}

void stopI2SMic() {
  if (!i2sInitialised)
    return;
  i2s_driver_uninstall(I2S_PORT);
  i2sInitialised = false;
}

// ─────────────────────────────────────────────────────────────
//  AUDIO BLE STREAMING  (unchanged)
// ─────────────────────────────────────────────────────────────
void streamAudioBLE() {
  const char *startMarker = "AUDIO_START";
  pAudioChar->setValue((uint8_t *)startMarker, strlen(startMarker));
  pAudioChar->notify();
  delay(20);

  const uint16_t DMA_SAMPLES = I2S_DMA_BUF_LEN;
  int32_t *dmaBuffer = (int32_t *)malloc(DMA_SAMPLES * sizeof(int32_t));
  uint8_t *chunkBuf = (uint8_t *)malloc(AUDIO_BLE_CHUNK_BYTES + 8);

  if (!dmaBuffer || !chunkBuf) {
    Serial.println("[AUDIO] Memory allocation failed.");
    const char *endMarker = "AUDIO_END";
    pAudioChar->setValue((uint8_t *)endMarker, strlen(endMarker));
    pAudioChar->notify();
    free(dmaBuffer);
    free(chunkBuf);
    return;
  }

  const uint16_t PCM16_PER_CHUNK = AUDIO_BLE_CHUNK_BYTES / 2;

  uint16_t pcmStageLen = 0;
  int16_t *pcmStage = (int16_t *)malloc(PCM16_PER_CHUNK * sizeof(int16_t));

  if (!pcmStage) {
    Serial.println("[AUDIO] Stage buffer alloc failed.");
    free(dmaBuffer);
    free(chunkBuf);
    const char *endMarker = "AUDIO_END";
    pAudioChar->setValue((uint8_t *)endMarker, strlen(endMarker));
    pAudioChar->notify();
    return;
  }

  uint32_t totalSamplesRecorded = 0;
  size_t bytesRead = 0;

  while (totalSamplesRecorded < AUDIO_TOTAL_SAMPLES && !stopCryRequest) {
    if (!bleConnected)
      break;
    yield();

    esp_err_t res =
        i2s_read(I2S_PORT, (void *)dmaBuffer, DMA_SAMPLES * sizeof(int32_t),
                 &bytesRead, pdMS_TO_TICKS(200));

    if (res != ESP_OK || bytesRead == 0)
      continue;

    uint16_t samplesRead = bytesRead / sizeof(int32_t);

    for (uint16_t s = 0;
         s < samplesRead && totalSamplesRecorded < AUDIO_TOTAL_SAMPLES; s++) {
      int16_t pcm16 = (int16_t)(dmaBuffer[s] >> 16);
      pcmStage[pcmStageLen++] = pcm16;
      totalSamplesRecorded++;

      if (pcmStageLen == PCM16_PER_CHUNK) {
        const char *header = "AUDIO_CHUNK:";
        uint8_t hdrLen = strlen(header);
        uint16_t dataLen = PCM16_PER_CHUNK * sizeof(int16_t);

        memcpy(chunkBuf, header, hdrLen);
        memcpy(chunkBuf + hdrLen, (uint8_t *)pcmStage, dataLen);

        pAudioChar->setValue(chunkBuf, hdrLen + dataLen);
        pAudioChar->notify();
        delay(10);
        pcmStageLen = 0;
      }
    }
  }

  if (pcmStageLen > 0 && bleConnected) {
    const char *header = "AUDIO_CHUNK:";
    uint8_t hdrLen = strlen(header);
    uint16_t dataLen = pcmStageLen * sizeof(int16_t);

    memcpy(chunkBuf, header, hdrLen);
    memcpy(chunkBuf + hdrLen, (uint8_t *)pcmStage, dataLen);

    pAudioChar->setValue(chunkBuf, hdrLen + dataLen);
    pAudioChar->notify();
    delay(10);
  }

  free(dmaBuffer);
  free(chunkBuf);
  free(pcmStage);

  const char *endMarker = "AUDIO_END";
  pAudioChar->setValue((uint8_t *)endMarker, strlen(endMarker));
  pAudioChar->notify();

  Serial.printf("[AUDIO] Streamed %u samples (%.1f s).\n", totalSamplesRecorded,
                (float)totalSamplesRecorded / AUDIO_SAMPLE_RATE);
}