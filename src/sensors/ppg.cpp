#include "ppg.h"
#include <Wire.h>
#include "MAX30105.h"
#include "heartRate.h"
#include "spo2_algorithm.h"

// ── SparkFun driver instance ─────────────────────────────────────
static MAX30105 sensor;

// ── HR — PBA rolling average (Example5_HeartRate pattern) ────────
static const byte RATE_SIZE = 4;
static byte   rates[RATE_SIZE] = {0};
static byte   rateSpot = 0;
static long   lastBeat = 0;

// ── SpO2 — Maxim algorithm buffers (Example8_SpO2 pattern) ───────
static const int SP_BUF = 100;
static uint32_t irBuf[SP_BUF];
static uint32_t redBuf[SP_BUF];
static int32_t  spo2_raw = 0;
static int8_t   spo2_valid_flag = 0;
static int32_t  hr_sp = 0;
static int8_t   hr_sp_valid = 0;

// ── IR ring-buffer (exposed for breathing module) ─────────────────
uint32_t ppg_ir_buf[PPG_IR_BUF_SIZE] = {0};
int      ppg_ir_head = 0;

static PpgData data = {0, 0, false, false, 0, false};
static bool    ok   = false;

// SpO2 buffer fill state
static int sp_idx = 0;
static bool sp_ready = false;

bool ppg_init() {
    if (!sensor.begin(Wire, I2C_SPEED_FAST)) return false;
    // ledBrightness=60, sampleAvg=4, ledMode=2(Red+IR), rate=100, pw=411, adc=4096
    sensor.setup(60, 4, 2, 100, 411, 4096);
    sensor.setPulseAmplitudeRed(0x0A);
    sensor.setPulseAmplitudeIR(0x1F);
    sensor.setPulseAmplitudeGreen(0);
    ok = true;
    return true;
}

void ppg_update() {
    if (!ok) return;

    long ir = sensor.getIR();
    long red = sensor.getRed();

    data.ir_raw   = ir;
    data.finger_on = (ir > 50000);

    // Store in IR ring-buffer for breathing module
    ppg_ir_buf[ppg_ir_head] = (uint32_t)ir;
    ppg_ir_head = (ppg_ir_head + 1) % PPG_IR_BUF_SIZE;

    // ── HR via PBA algorithm ─────────────────────────────────
    if (checkForBeat(ir)) {
        long delta = millis() - lastBeat;
        lastBeat = millis();
        float bpm = 60.0f / (delta / 1000.0f);
        if (bpm > 20 && bpm < 255) {
            rates[rateSpot++] = (byte)bpm;
            rateSpot %= RATE_SIZE;
            int sum = 0;
            for (byte i = 0; i < RATE_SIZE; i++) sum += rates[i];
            data.hr       = sum / RATE_SIZE;
            data.hr_valid = (data.finger_on && data.hr >= 60 && data.hr <= 200);
        }
    }

    // ── SpO2 via Maxim algorithm ─────────────────────────────
    irBuf[sp_idx]  = (uint32_t)ir;
    redBuf[sp_idx] = (uint32_t)red;
    sp_idx++;
    if (sp_idx >= SP_BUF) {
        sp_idx = 0;
        sp_ready = true;
    }
    if (sp_ready) {
        maxim_heart_rate_and_oxygen_saturation(
            irBuf, SP_BUF, redBuf,
            &spo2_raw, &spo2_valid_flag,
            &hr_sp, &hr_sp_valid);
        data.spo2       = (uint8_t)(spo2_raw > 0 ? spo2_raw : 0);
        data.spo2_valid = (spo2_valid_flag == 1 && data.spo2 >= 80 && data.spo2 <= 100);
    }
}

const PpgData& ppg_get() { return data; }
