#include "classifier.h"
#include "risk_engine.h"
#include "../sensors/ppg.h"
#include "../processing/apnea.h"
#include "../processing/cry.h"

#define ESCALATE_COUNT   3   // readings to hold before escalating
#define DEESCALATE_COUNT 5   // readings to hold before de-escalating

static ClassifierData result = {RISK_NORMAL, 0, 0, 0};

static RiskLevel pending_level = RISK_NORMAL;
static int       pending_count = 0;

static const float SPO2_RED_THRESH = 90.0f;

void classifier_init() {
    result = {RISK_NORMAL, 0, 0, 0};
    pending_level = RISK_NORMAL;
    pending_count = 0;
}

static RiskLevel raw_classify(const RiskEngineData& re,
                              const ApneaData&      ap,
                              const PpgData&        ppg,
                              const CryData&        cry) {
    // Hard RED conditions
    if (ap.apnea_now)                                        return RISK_RED;
    if (ppg.spo2_valid && (float)ppg.spo2 < SPO2_RED_THRESH) return RISK_RED;
    if (re.respiratory_score > 70 || re.hydration_score > 70) return RISK_RED;

    // AMBER
    if (re.respiratory_score >= 40 || re.hydration_score >= 40) return RISK_AMBER;
    if (cry.persistent)                                          return RISK_AMBER;

    return RISK_NORMAL;
}

void classifier_update() {
    const RiskEngineData& re  = risk_engine_get();
    const ApneaData&      ap  = apnea_get();
    const PpgData&        ppg = ppg_get();
    const CryData&        cry = cry_get();

    RiskLevel raw = raw_classify(re, ap, ppg, cry);

    // ── Signal persistence ───────────────────────────────────────────────────
    if (raw == pending_level) {
        pending_count++;
    } else {
        pending_level = raw;
        pending_count = 1;
    }

    int hold = (raw < result.level) ? DEESCALATE_COUNT : ESCALATE_COUNT;
    if (pending_count >= hold) {
        result.level = pending_level;
    }

    result.respiratory_score = re.respiratory_score;
    result.hydration_score   = re.hydration_score;

    // ── Flags ────────────────────────────────────────────────────────────────
    uint8_t f = 0;
    if (ap.apnea_now)                                          f |= (1 << 0);
    if (ppg.spo2_valid && (float)ppg.spo2 < SPO2_RED_THRESH)  f |= (1 << 1);
    if (cry.persistent)                                        f |= (1 << 2);
    if (re.lbw_active)                                         f |= (1 << 3);
    result.flags = f;
}

const ClassifierData& classifier_get() { return result; }
