#pragma once
#include <Arduino.h>

/**
 * @brief Breathing rate & regularity module
 *
 * Extracts respiratory rate from the PPG IR waveform (the slow
 * ~0.3–1 Hz modulation of the PPG signal caused by breathing)
 * and cross-validates with IMU chest-motion peaks.
 *
 * Normal neonatal range: 30–60 breaths per minute.
 */

struct BreathData {
    uint8_t rate_bpm;       // breaths per minute (0 = unknown)
    bool    regular;        // true if inter-breath intervals are consistent
    float   regularity;     // 0.0–1.0  (1 = perfectly regular)
    bool    valid;
};

void            breathing_init();
void            breathing_update();   // call every ~200 ms
const BreathData& breathing_get();
