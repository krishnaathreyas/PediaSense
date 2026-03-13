#pragma once
#include <Arduino.h>

/**
 * @brief Apnea detection module
 *
 * An apnea event is flagged when ALL of:
 *   • No breath detected for > APNEA_PAUSE_MS (default 15 s)
 *   • SpO2 drops ≥ 3 % below baseline  (or is unavailable, relaxed)
 *   • IMU motion magnitude is below STILL_THRESHOLD
 *
 * Following AHA neonatal apnea monitoring guidelines.
 */

struct ApneaData {
    bool    apnea_now;          // true = currently in an apnea event
    uint16_t pause_ms;          // ms since last detected breath
    uint8_t  event_count_1h;    // apnea events in the last 60 minutes
};

void             apnea_init();
void             apnea_update();
const ApneaData& apnea_get();
