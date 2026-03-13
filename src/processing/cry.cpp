#include "cry.h"
#include "../sensors/mic.h"

/**
 * Simple cry detection:
 *  - 1st-order IIR high-pass filter to extract high-frequency energy
 *    (cutoff ~300 Hz at 16 kHz sample rate → α = 0.88)
 *  - Compare HPF energy to total energy → "cry ratio"
 *  - If cry ratio > threshold and absolute level > floor → crying
 *  - Track cry onset/offset timestamps to build cries_per_5min
 */

#define CRY_RATIO_THRESH   0.35f    // HPF : total energy ratio
#define CRY_FLOOR_RMS      600.0f   // minimum absolute level to even count
#define CRY_MIN_DURATION   400      // ms — ignore blips < 400 ms
#define CRY_MERGE_GAP      800      // ms — gaps < 800 ms = same cry event
#define CRY_WINDOW_MS      300000UL // 5 minutes

// HPF coefficient for ~300 Hz @ 16 kHz: α = 1 / (1 + 2π*fc/fs)
static const float HPF_ALPHA = 0.88f;

static CryData result = {false, 0, 0, false};

// IIR filter state (one per sample, applied across the buffer)
static float hpf_prev_in  = 0.0f;
static float hpf_prev_out = 0.0f;

// Cry event log
static const int CRY_LOG = 20;
static unsigned long cry_start_times[CRY_LOG] = {0};
static int cry_log_head = 0, cry_log_count = 0;

static bool     in_cry     = false;
static unsigned long cry_onset_ms = 0;

void cry_init() {
    hpf_prev_in = hpf_prev_out = 0.0f;
}

void cry_update() {
    if (mic_buf_count == 0) return;

    // ── Apply HPF across mic buffer ──────────────────────────
    // y[n] = α * (y[n-1] + x[n] - x[n-1])
    float total_e = 0.0f, hpf_e = 0.0f;
    float prev_in  = hpf_prev_in;
    float prev_out = hpf_prev_out;

    for (int i = 0; i < mic_buf_count; i++) {
        float x = (float)mic_buf[i];
        float y = HPF_ALPHA * (prev_out + x - prev_in);
        prev_in  = x;
        prev_out = y;
        total_e += x * x;
        hpf_e   += y * y;
    }
    hpf_prev_in  = prev_in;
    hpf_prev_out = prev_out;

    float rms_total = sqrtf(total_e / mic_buf_count);
    float ratio     = (total_e > 0.01f) ? (hpf_e / total_e) : 0.0f;

    bool detected = (rms_total > CRY_FLOOR_RMS) && (ratio > CRY_RATIO_THRESH);

    // ── Cry onset / offset debounce ──────────────────────────
    unsigned long now = millis();
    if (detected && !in_cry) {
        in_cry       = true;
        cry_onset_ms = now;
    } else if (!detected && in_cry) {
        // Check if cry lasted long enough
        if ((now - cry_onset_ms) >= CRY_MIN_DURATION) {
            cry_start_times[cry_log_head] = cry_onset_ms;
            cry_log_head  = (cry_log_head + 1) % CRY_LOG;
            if (cry_log_count < CRY_LOG) cry_log_count++;
        }
        in_cry = false;
    }

    result.crying = in_cry;

    // ── Strength: normalise rms_total to 0–100 ───────────────
    // Clip at 30000 RMS (loud cry), scale to 100
    result.strength = (uint8_t)min(100.0f, rms_total / 300.0f);

    // ── Count cries in last 5 minutes ────────────────────────
    int recent = 0;
    for (int i = 0; i < cry_log_count; i++) {
        if ((now - cry_start_times[i]) < CRY_WINDOW_MS) recent++;
    }
    if (in_cry) recent++;  // count current ongoing cry
    result.cries_per_5min = (uint8_t)min(recent, 255);
    result.persistent     = (result.cries_per_5min >= 3);
}

const CryData& cry_get() { return result; }
