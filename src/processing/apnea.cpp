#include "apnea.h"
#include "breathing.h"
#include "../sensors/ppg.h"
#include "../sensors/imu.h"

#define APNEA_PAUSE_MS     15000UL   // 15 seconds no breath → apnea
#define SPO2_DROP_THRESH   3         // % drop to count as desaturation
#define STILL_THRESHOLD    0.15f     // m/s² motion delta — below = still
#define EVENT_WINDOW_MS    3600000UL // 60 minutes

static ApneaData result = {false, 0, 0};
static bool      ok     = false;

static unsigned long last_breath_ms  = 0;
static uint8_t       spo2_baseline   = 0;
static bool          baseline_set    = false;

// Circular buffer of event timestamps (max 20 per hour)
static const int EV_BUF = 20;
static unsigned long event_times[EV_BUF] = {0};
static int ev_head = 0, ev_count = 0;

void apnea_init() {
    last_breath_ms = millis();
    ok = true;
}

void apnea_update() {
    if (!ok) return;

    const BreathData& br   = breathing_get();
    const PpgData&    ppg  = ppg_get();
    const ImuData&    imu  = imu_get();
    unsigned long     now  = millis();

    // ── Track last detected breath ───────────────────────────
    if (br.valid && br.rate_bpm > 0) {
        last_breath_ms = now;
    }
    result.pause_ms = (uint16_t)min((unsigned long)65535, now - last_breath_ms);

    // ── Calibrate SpO2 baseline (take first 5 valid readings) ─
    static int spo2_calib_count = 0;
    if (!baseline_set && ppg.spo2_valid && spo2_calib_count < 5) {
        spo2_baseline = ppg.spo2;
        spo2_calib_count++;
        if (spo2_calib_count >= 5) baseline_set = true;
    }

    // ── Check apnea conditions ───────────────────────────────
    bool pause_long   = (result.pause_ms >= APNEA_PAUSE_MS);
    bool desaturation = baseline_set && ppg.spo2_valid &&
                        (spo2_baseline - ppg.spo2 >= SPO2_DROP_THRESH);
    bool still        = (imu.motion_delta < STILL_THRESHOLD);

    bool apnea = pause_long && still && (desaturation || !ppg.spo2_valid);

    if (apnea && !result.apnea_now) {
        // New event
        event_times[ev_head] = now;
        ev_head  = (ev_head + 1) % EV_BUF;
        if (ev_count < EV_BUF) ev_count++;
    }
    result.apnea_now = apnea;

    // ── Count events in last 60 minutes ──────────────────────
    int recent = 0;
    for (int i = 0; i < ev_count; i++) {
        if ((now - event_times[i]) < EVENT_WINDOW_MS) recent++;
    }
    result.event_count_1h = (uint8_t)min(recent, 255);
}

const ApneaData& apnea_get() { return result; }
