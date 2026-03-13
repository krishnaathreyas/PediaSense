#pragma once
#include <Arduino.h>

/**
 * @brief Cry analysis module
 *
 * Processes mic data to detect infant crying.
 * Applies a 1st-order IIR high-pass filter to isolate the cry
 * frequency band (~300–3000 Hz) from ambient and breathing noise,
 * then tracks cry strength and pattern (onset/duration/frequency).
 *
 * Used for: Cry Analysis (Strength & Pattern) feature block.
 */

struct CryData {
    bool     crying;          // currently detecting a cry
    uint8_t  strength;        // 0–100 (normalised cry intensity)
    uint8_t  cries_per_5min;  // cry events in the last 5 minutes
    bool     persistent;      // cries_per_5min >= 3
};

void          cry_init();
void          cry_update();
const CryData& cry_get();
