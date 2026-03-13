#pragma once
#include <Arduino.h>

/**
 * @brief PPG sensor module — MAX30102
 *
 * Provides HR (beats per minute) via SparkFun PBA algorithm and
 * SpO2 (%) via red/IR ratio.  Raw IR samples are also exposed so
 * the breathing-rate module can track the respiratory component of
 * the PPG waveform.
 *
 * Pins: I2C  SDA=GPIO21  SCL=GPIO22  (shared bus)
 */

// ─── Shared IR ring-buffer for breathing-rate module ─────────────
static const int PPG_IR_BUF_SIZE = 100;   // ~1 second at 100 sps

struct PpgData {
    uint8_t  hr;          // beats per minute  (0 = no finger / invalid)
    uint8_t  spo2;        // percent           (0 = invalid)
    bool     hr_valid;
    bool     spo2_valid;
    long     ir_raw;      // latest raw IR value
    bool     finger_on;   // IR > 50 000 → finger present
};

bool ppg_init();
void ppg_update();                    // call every loop tick (non-blocking)
const PpgData& ppg_get();
// Ring-buffer of recent IR values written by ppg_update():
extern uint32_t ppg_ir_buf[PPG_IR_BUF_SIZE];
extern int      ppg_ir_head;          // index of newest sample
