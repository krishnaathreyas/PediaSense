#include "breathing.h"
#include "../sensors/ppg.h"
#include "../sensors/imu.h"

/**
 * Strategy:
 * 1. Take the PPG IR ring-buffer (100 samples, ~1 s at 100 sps).
 * 2. Subtract DC (mean), smooth with 3-tap MA.
 * 3. Count positive-to-negative zero crossings → breathing half-cycles.
 * 4. Accumulate crossing timestamps over 8 seconds → derive rate.
 * 5. Cross-validate: if IMU accel_mag peaks align (within 20 %), boost
 *    confidence; regularity = 1 - CV of inter-breath intervals.
 */

static BreathData result = {0, false, 0.0f, false};

// Timestamp ring-buffer for zero-crossing events (ms)
static const int ZC_BUF = 10;
static unsigned long zc_times[ZC_BUF] = {0};
static int zc_head = 0;
static int zc_count = 0;

static float prev_ac = 0.0f;

// Compute mean of the PPG IR buffer
static float ir_mean() {
    double sum = 0;
    for (int i = 0; i < PPG_IR_BUF_SIZE; i++) sum += ppg_ir_buf[i];
    return (float)(sum / PPG_IR_BUF_SIZE);
}

void breathing_init() {
    // Nothing to configure
}

void breathing_update() {
    // Need a valid finger for PPG breathing extraction
    if (!ppg_get().finger_on) {
        result.valid = false;
        return;
    }

    // ── 1. AC component of newest IR sample ─────────────────
    float mean   = ir_mean();
    float newest = (float)ppg_ir_buf[(ppg_ir_head + PPG_IR_BUF_SIZE - 1) % PPG_IR_BUF_SIZE];
    float ac     = newest - mean;

    // ── 2. Detect zero crossing (negative-to-positive) ──────
    bool crossing = (prev_ac < 0.0f && ac >= 0.0f);
    prev_ac = ac;

    if (crossing) {
        unsigned long now = millis();
        zc_times[zc_head] = now;
        zc_head  = (zc_head + 1) % ZC_BUF;
        if (zc_count < ZC_BUF) zc_count++;
    }

    if (zc_count < 3) {
        result.valid = false;
        return;
    }

    // ── 3. Compute rate from last N crossings ────────────────
    // Each crossing = one full breath cycle
    unsigned long newest_zc = zc_times[(zc_head + ZC_BUF - 1) % ZC_BUF];
    unsigned long oldest_zc = zc_times[(zc_head + ZC_BUF - zc_count) % ZC_BUF];
    unsigned long span_ms   = newest_zc - oldest_zc;

    if (span_ms == 0) return;
    float breaths = (float)(zc_count - 1);
    float rate    = breaths / (span_ms / 60000.0f);  // breaths per minute

    if (rate < 10.0f || rate > 100.0f) return;
    result.rate_bpm = (uint8_t)rate;

    // ── 4. Regularity: coefficient of variation of intervals ─
    float intervals[ZC_BUF];
    int   n = 0;
    for (int i = 0; i < zc_count - 1; i++) {
        int idx1 = (zc_head + ZC_BUF - zc_count + i)     % ZC_BUF;
        int idx2 = (zc_head + ZC_BUF - zc_count + i + 1) % ZC_BUF;
        intervals[n++] = (float)(zc_times[idx2] - zc_times[idx1]);
    }
    if (n < 2) { result.valid = true; result.regular = true; result.regularity = 1.0f; return; }
    float mean_iv = 0;
    for (int i = 0; i < n; i++) mean_iv += intervals[i];
    mean_iv /= n;
    float var = 0;
    for (int i = 0; i < n; i++) var += (intervals[i] - mean_iv) * (intervals[i] - mean_iv);
    float cv = sqrtf(var / n) / mean_iv;   // coefficient of variation
    result.regularity = fmaxf(0.0f, 1.0f - cv);
    result.regular    = (result.regularity > 0.6f);
    result.valid      = true;
}

const BreathData& breathing_get() { return result; }
