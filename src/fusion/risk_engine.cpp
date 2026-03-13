#include "risk_engine.h"
#include "../sensors/ppg.h"
#include "../sensors/imu.h"
#include "../sensors/temp.h"
#include "../processing/breathing.h"
#include "../processing/apnea.h"
#include "../processing/cry.h"

// ── LBW thresholds (tighter) vs normal ───────────────────────────────────────
//  Breathing rate normal range
static float BR_LOW_NORM  = 30.0f,  BR_HIGH_NORM  = 60.0f;
static float BR_LOW_LBW   = 32.0f,  BR_HIGH_LBW   = 55.0f;

//  SpO2 concern threshold
static const float SPO2_CONCERN_NORM = 93.0f;
static const float SPO2_CONCERN_LBW  = 95.0f;

//  Skin temp normal range
static const float TEMP_LOW_NORM  = 36.0f, TEMP_HIGH_NORM  = 37.8f;
static const float TEMP_LOW_LBW   = 36.5f, TEMP_HIGH_LBW   = 37.5f;

//  HR normal range
static const float HR_LOW_NORM  = 100.0f, HR_HIGH_NORM  = 160.0f;
static const float HR_LOW_LBW   = 110.0f, HR_HIGH_LBW   = 155.0f;

// ── Helper: map a value to a 0–100 penalty ───────────────────────────────────
// penalty = 0 when inside [lo, hi]; rises to 100 when outside by `full_dev`
static float range_penalty(float v, float lo, float hi, float full_dev) {
    if (v < lo) {
        float d = lo - v;
        return min(100.0f, (d / full_dev) * 100.0f);
    }
    if (v > hi) {
        float d = v - hi;
        return min(100.0f, (d / full_dev) * 100.0f);
    }
    return 0.0f;
}

static RiskEngineData result = {0, 0, false};
static bool lbw = false;

void risk_engine_init(float birth_weight_kg) {
    lbw = (birth_weight_kg > 0.1f && birth_weight_kg < 2.5f);
    result.lbw_active = lbw;
}

void risk_engine_update() {
    const PpgData&     ppg  = ppg_get();
    const BreathData&  br   = breathing_get();
    const ApneaData&   ap   = apnea_get();
    const TempData&    tmp  = temp_get();
    const CryData&     cry  = cry_get();

    // ── Active threshold selection ────────────────────────────────────────────
    float br_lo  = lbw ? BR_LOW_LBW  : BR_LOW_NORM;
    float br_hi  = lbw ? BR_HIGH_LBW : BR_HIGH_NORM;
    float spo2_t = lbw ? SPO2_CONCERN_LBW : SPO2_CONCERN_NORM;
    float t_lo   = lbw ? TEMP_LOW_LBW  : TEMP_LOW_NORM;
    float t_hi   = lbw ? TEMP_HIGH_LBW : TEMP_HIGH_NORM;
    float hr_lo  = lbw ? HR_LOW_LBW    : HR_LOW_NORM;
    float hr_hi  = lbw ? HR_HIGH_LBW   : HR_HIGH_NORM;

    // ── RESPIRATORY SCORE (0–100) ─────────────────────────────────────────────
    float resp = 0.0f;

    // Breathing rate deviation (weight 30)
    if (br.valid) {
        float br_pen = range_penalty(br.rate_bpm, br_lo, br_hi, 20.0f);
        resp += 0.30f * br_pen;

        // Irregular breathing bonus (weight 15)
        if (!br.regular) resp += 15.0f * (1.0f - br.regularity);
    } else {
        resp += 10.0f;  // no data = small default penalty
    }

    // SpO2 deficit (weight 40)
    if (ppg.spo2_valid) {
        float spo2_def = spo2_t - (float)ppg.spo2;
        if (spo2_def > 0.0f) resp += min(40.0f, spo2_def * 4.0f);
    }

    // Apnea bonus (weight +25 per event, capped at 100)
    if (ap.apnea_now) {
        resp += 30.0f;
        float pause_s = ap.pause_ms / 1000.0f;
        resp += min(20.0f, (pause_s - 15.0f) * 2.0f);  // extra for longer pauses
    }
    if (ap.event_count_1h >= 1) resp += min(15.0f, (float)ap.event_count_1h * 5.0f);

    if (lbw) resp = min(100.0f, resp * 1.20f);  // +20% sensitivity for LBW
    result.respiratory_score = (uint8_t)min(100.0f, resp);

    // ── HYDRATION SCORE (0–100) ───────────────────────────────────────────────
    float hydr = 0.0f;

    // Skin temperature (weight 50)
    if (tmp.valid) {
        float t_pen = range_penalty(tmp.skin_c, t_lo, t_hi, 2.0f);
        hydr += 0.50f * t_pen;
    } else {
        hydr += 10.0f;
    }

    // Heart rate (weight 30)
    if (ppg.hr_valid) {
        float hr_pen = range_penalty((float)ppg.hr, hr_lo, hr_hi, 40.0f);
        hydr += 0.30f * hr_pen;
    }

    // Persistent crying adds stress indicator (weight up to 20)
    if (cry.persistent) hydr += 15.0f;
    else if (cry.crying) hydr += (float)cry.cries_per_5min * 3.0f;

    if (lbw) hydr = min(100.0f, hydr * 1.15f);
    result.hydration_score = (uint8_t)min(100.0f, hydr);
}

const RiskEngineData& risk_engine_get() { return result; }
