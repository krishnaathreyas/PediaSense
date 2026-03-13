#pragma once
#include <stdint.h>
#include <stdbool.h>

/**
 * Risk Engine — weighted scoring on two pathways:
 *   respiratory_score  (0–100): breathing + SpO2 + apnea
 *   hydration_score    (0–100): skin temp + HR
 *
 * LBW flag (birth weight < 2.5 kg) tightens thresholds and inflates scores
 * to reflect higher clinical sensitivity requirement.
 */
struct RiskEngineData {
    uint8_t respiratory_score;  // 0 = fine, 100 = critical
    uint8_t hydration_score;    // 0 = fine, 100 = critical
    bool    lbw_active;         // low birth-weight mode on
};

void risk_engine_init(float birth_weight_kg);
void risk_engine_update();
const RiskEngineData& risk_engine_get();
