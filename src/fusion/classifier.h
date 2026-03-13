#pragma once
#include <stdint.h>
#include <stdbool.h>

/**
 * Three-level risk classification based on risk engine scores.
 *
 * NORMAL  — respiratory < 40 AND hydration < 40
 * AMBER   — either score 40–70, or 2+ persistent amber readings
 * RED     — either score > 70, OR active apnea, OR SpO2 < 90
 *
 * Signal persistence: level must hold for 3 consecutive readings before
 * escalating, but de-escalation towards NORMAL requires 5 consecutive
 * clean readings (prevents flapping).
 */

enum RiskLevel : uint8_t {
    RISK_NORMAL = 0,
    RISK_AMBER  = 1,
    RISK_RED    = 2
};

struct ClassifierData {
    RiskLevel level;
    uint8_t   respiratory_score;
    uint8_t   hydration_score;
    uint8_t   flags;          // bit 0=apnea, bit 1=spo2_low, bit 2=cry_persistent, bit 3=lbw
};

void classifier_init();
void classifier_update();
const ClassifierData& classifier_get();
