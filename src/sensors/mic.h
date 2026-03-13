#pragma once
#include <Arduino.h>

/**
 * @brief MEMS microphone module — INMP441
 *
 * Reads I2S audio frames, computes RMS and peak amplitude.
 * The raw samples are also written to a ring-buffer for use by
 * the cry-analysis module.
 *
 * Pins: SCK=GPIO26  WS=GPIO25  SD=GPIO34
 * L/R pin must be tied to GND (selects left channel).
 */

static const int MIC_BUF_SIZE = 512;   // ~32 ms at 16 kHz

struct MicData {
    float    rms;          // root-mean-square of latest window
    int32_t  peak;         // max absolute sample value
    bool     active;       // rms > MIC_ACTIVE_THRESHOLD
};

bool          mic_init();
void          mic_update();             // reads one DMA buffer (non-blocking via 0-ms timeout)
const MicData& mic_get();

// Ring-buffer of raw 24-bit samples (int32_t, sign-extended)
extern int32_t mic_buf[MIC_BUF_SIZE];
extern int     mic_buf_count;           // number of valid samples in mic_buf after last update
