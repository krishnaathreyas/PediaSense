#include "ppg.h"
#include "MAX30105.h"
#include "heartRate.h"
#include "spo2_algorithm.h"
#include <Wire.h>

// ── SparkFun driver instance ─────────────────────────────────────
static MAX30105 sensor;

// ── HR — PBA rolling average (Example5_HeartRate pattern) ────────
static const byte RATE_SIZE = 4;
static byte rates[RATE_SIZE] = {0};
static byte rateSpot = 0;
static byte beatCount = 0; // how many valid beats we've accumulated
static long lastBeat = 0;
static bool prevFingerOn = false; // track finger on/off transitions

// ── SpO2 — Maxim algorithm buffers (Example8_SpO2 pattern) ───────
static const int SP_BUF = 100;
static uint32_t irBuf[SP_BUF];
static uint32_t redBuf[SP_BUF];
static int32_t spo2_raw = 0;
static int8_t spo2_valid_flag = 0;
static int32_t hr_sp = 0;
static int8_t hr_sp_valid = 0;

// ── IR ring-buffer (exposed for breathing module) ─────────────────
uint32_t ppg_ir_buf[PPG_IR_BUF_SIZE] = {0};
int ppg_ir_head = 0;

static PpgData data = {0, 0, false, false, 0, false};
static bool ok = false;

// SpO2 buffer fill state
static int sp_idx = 0;
static bool sp_ready = false;

bool ppg_init() {
  if (!sensor.begin(Wire, I2C_SPEED_FAST))
    return false;
  // Demo-tuned: higher LED drive and lower averaging for faster beat detection
  // lock ledBrightness=80, sampleAvg=1, ledMode=2(Red+IR), rate=100, pw=411,
  // adc=4096
  sensor.setup(80, 1, 2, 100, 411, 4096);
  sensor.setPulseAmplitudeRed(0x3F);
  sensor.setPulseAmplitudeIR(0x3F);
  sensor.setPulseAmplitudeGreen(0);
  ok = true;
  return true;
}

void ppg_update() {
  if (!ok)
    return;

  // Pull fresh samples from sensor FIFO into SparkFun internal buffer
  sensor.check();

  bool hadSample = false;
  while (sensor.available()) {
    hadSample = true;
    long ir = sensor.getIR();
    long red = sensor.getRed();
    sensor.nextSample();

    data.ir_raw = ir;
    data.finger_on = (ir > 7000);

    // Store in IR ring-buffer for breathing module
    ppg_ir_buf[ppg_ir_head] = (uint32_t)ir;
    ppg_ir_head = (ppg_ir_head + 1) % PPG_IR_BUF_SIZE;

    // ── HR via PBA algorithm ─────────────────────────────
    if (data.finger_on && checkForBeat(ir)) {
      long delta = millis() - lastBeat;
      lastBeat = millis();
      float bpm = 60.0f / (delta / 1000.0f);
      if (bpm > 20 && bpm < 255) {
        rates[rateSpot++] = (byte)bpm;
        rateSpot %= RATE_SIZE;
        if (beatCount < RATE_SIZE)
          beatCount++;
        // Only report HR after enough beats are collected
        if (beatCount >= 3) {
          int sum = 0;
          int n = 0;
          for (byte i = 0; i < RATE_SIZE; i++) {
            if (rates[i] > 0) {
              sum += rates[i];
              n++;
            }
          }
          if (n > 0) {
            data.hr = sum / n;
            data.hr_valid = (data.finger_on && data.hr >= 40 && data.hr <= 220);
          }
        }
      }
    }

    // ── SpO2 via Maxim algorithm ─────────────────────────
    irBuf[sp_idx] = (uint32_t)ir;
    redBuf[sp_idx] = (uint32_t)red;
    sp_idx++;
    if (sp_idx >= SP_BUF) {
      sp_idx = 0;
      sp_ready = true;
    }
  }

  if (!hadSample)
    return;

  // ── Detect finger removal → reset all state ──────────────
  if (!data.finger_on) {
    if (prevFingerOn) {
      // Finger just removed — clear HR rolling average
      for (byte i = 0; i < RATE_SIZE; i++)
        rates[i] = 0;
      rateSpot = 0;
      beatCount = 0;
      lastBeat = 0;
      // Clear SpO2 buffer so next read is fresh
      sp_idx = 0;
      sp_ready = false;
    }
    prevFingerOn = false;
    data.hr = 0;
    data.spo2 = 0;
    data.hr_valid = false;
    data.spo2_valid = false;
    return;
  }
  prevFingerOn = true;

  if (sp_ready) {
    sp_ready = false; // reset so we compute only on fresh buffers

    maxim_heart_rate_and_oxygen_saturation(irBuf, SP_BUF, redBuf, &spo2_raw,
                                           &spo2_valid_flag, &hr_sp,
                                           &hr_sp_valid);

    if (hr_sp_valid == 1 && hr_sp > 30 && hr_sp < 240) {
      data.hr = (uint8_t)hr_sp;
      data.hr_valid = true;
    }

    data.spo2 = (uint8_t)(spo2_raw > 0 ? spo2_raw : 0);
    data.spo2_valid =
        (spo2_valid_flag == 1 && data.spo2 >= 80 && data.spo2 <= 100);
  }
}

const PpgData &ppg_get() { return data; }
