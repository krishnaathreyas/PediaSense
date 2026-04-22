#include "mic.h"
#include <driver/i2s.h>

// ── Hardware wiring (confirmed from schematic) ────────────────────
// L/R pin MUST be tied to GND (selects the left I2S channel).
#define I2S_SCK_PIN    14
#define I2S_WS_PIN     15
#define I2S_SD_PIN     32
#define I2S_PORT       I2S_NUM_0
#define SAMPLE_RATE    16000

// Active threshold: quiet room ≈ 200, normal speech ≈ 3000+
#define MIC_ACTIVE_THRESHOLD  400.0f

// ── Shared ring-buffer (used by cry.cpp) ─────────────────────────
int32_t mic_buf[MIC_BUF_SIZE] = {0};
int     mic_buf_count = 0;

static MicData  data = {0.f, 0, false, 0.f, false, false, CRY_NONE, 0, 0, false};
static bool     ok   = false;
static int32_t  raw32[MIC_BUF_SIZE];

// ── HPF filter state (α=0.88 → ~300 Hz @ 16 kHz) ─────────────────
static float hpf_in = 0.f, hpf_out = 0.f;

// ── Breathing rate state ──────────────────────────────────────────
// Two-speed envelope tracks signal level:
//   fast (α=0.20, τ≈0.3 s)  — follows breath amplitude swells
//   slow (α=0.003, τ≈20 s)  — tracks quiet-room baseline
static float     br_fast  = 0.f;
static float     br_slow  = 200.f;
static bool      br_high  = false;       // are we currently above threshold?
static const int BR_ZC_MAX = 16;
static unsigned long br_times[BR_ZC_MAX] = {0};
static int       br_zc_head = 0, br_zc_count = 0;

// ── Cry event log ─────────────────────────────────────────────────
static const int CRY_LOG = 20;
static unsigned long cry_starts[CRY_LOG] = {0};
static int cry_log_head = 0, cry_log_count = 0;
static bool     in_cry    = false;
static unsigned long cry_onset_ms = 0;
#define CRY_MIN_DUR_MS  300UL    // ignore blips shorter than 300 ms
#define CRY_WINDOW_MS   300000UL // 5 minutes

bool mic_init() {
    i2s_config_t cfg = {
        .mode                 = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
        .sample_rate          = SAMPLE_RATE,
        .bits_per_sample      = I2S_BITS_PER_SAMPLE_32BIT,
        .channel_format       = I2S_CHANNEL_FMT_RIGHT_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags     = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count        = 8,
        .dma_buf_len          = 128,   // 128 × 8 = 1024 total I2S frames buffered
        .use_apll             = false,
        .tx_desc_auto_clear   = false,
        .fixed_mclk           = 0
    };
    i2s_pin_config_t pins = {
        .bck_io_num   = I2S_SCK_PIN,
        .ws_io_num    = I2S_WS_PIN,
        .data_out_num = I2S_PIN_NO_CHANGE,
        .data_in_num  = I2S_SD_PIN
    };
    if (i2s_driver_install(I2S_PORT, &cfg, 0, NULL) != ESP_OK) return false;
    if (i2s_set_pin(I2S_PORT, &pins)                != ESP_OK) return false;
    i2s_zero_dma_buffer(I2S_PORT);
    ok = true;
    return true;
}

void mic_update() {
    if (!ok) return;

    size_t bytesRead = 0;
    // Non-blocking: 0 ms timeout — returns whatever is in the DMA buffer now.
    // This keeps the 50 Hz main loop on schedule.
    i2s_read(I2S_PORT, raw32, sizeof(raw32), &bytesRead, 0);
    int count = (int)(bytesRead / sizeof(int32_t));
    if (count < 2) return;

    // ── Deinterleave L/R, pick active channel ────────────────────
    // The INMP441 outputs audio on one channel; the other is 0.
    // Comparing |L| vs |R| handles the case where L/R is miswired.
    float  total_e = 0.f, hpf_e = 0.f;
    float  prev_in  = hpf_in, prev_out = hpf_out;
    int32_t peak    = 0;
    int     out     = 0;

    for (int i = 0; i + 1 < count && out < MIC_BUF_SIZE; i += 2) {
        int32_t L = raw32[i]   >> 8;   // 24-bit signed
        int32_t R = raw32[i+1] >> 8;
        int32_t v = (abs(L) >= abs(R)) ? L : R;   // active channel

        // Write to shared ring-buffer (for cry.cpp)
        mic_buf[out++] = v;

        float x = float(v);

        // ── HPF: y[n] = α × (y[n-1] + x[n] − x[n-1]) ──────────
        float y   = 0.88f * (prev_out + x - prev_in);
        prev_in   = x;
        prev_out  = y;
        total_e  += x * x;
        hpf_e    += y * y;

        int32_t a = abs(v);
        if (a > peak) peak = a;
    }
    hpf_in  = prev_in;
    hpf_out = prev_out;
    mic_buf_count = out;
    if (out == 0) return;

    float rms       = sqrtf(total_e / out);
    float hpf_ratio = (total_e > 1.f) ? (hpf_e / total_e) : 0.f;

    data.rms    = rms;
    data.peak   = peak;
    data.active = (rms > MIC_ACTIVE_THRESHOLD);

    unsigned long now = millis();

    // ════════════════════════════════════════════════════════════
    //  BREATHING RATE — envelope peak detection
    // ════════════════════════════════════════════════════════════
    // Each RMS value is a point on the amplitude envelope.
    // A breath (even quiet) causes a small swell above the ambient baseline.
    br_fast = br_fast * 0.80f + rms * 0.20f;     // fast envelope (τ ≈ 0.3 s)
    br_slow = br_slow * 0.997f + rms * 0.003f;   // slow baseline (τ ≈ 20 s)
    float thr  = br_slow * 1.40f;                // 40% above baseline = breath
    bool  high = (br_fast > thr);

    if (high && !br_high) {
        // Rising edge — mark a breath onset
        br_times[br_zc_head] = now;
        br_zc_head = (br_zc_head + 1) % BR_ZC_MAX;
        if (br_zc_count < BR_ZC_MAX) br_zc_count++;
    }
    br_high = high;

    if (br_zc_count >= 4) {
        unsigned long newest = br_times[(br_zc_head + BR_ZC_MAX - 1) % BR_ZC_MAX];
        unsigned long oldest = br_times[(br_zc_head + BR_ZC_MAX - br_zc_count) % BR_ZC_MAX];
        unsigned long span   = newest - oldest;
        if (span > 0) {
            float rate = float(br_zc_count - 1) / (span / 60000.f);
            if (rate >= 8.f && rate <= 100.f) {
                data.breath_rate_bpm = rate;
                data.breath_valid    = true;
            }
        }
    } else {
        data.breath_valid = false;
    }

    // ════════════════════════════════════════════════════════════
    //  CRY DETECTION & CLASSIFICATION
    // ════════════════════════════════════════════════════════════
    // A cry is detected when:
    //   • absolute level > 500 RMS (not just room noise)
    //   • HPF band energy ratio > 0.28 (energy concentrated in high freqs)
    bool detected = (rms > 500.f && hpf_ratio > 0.28f);

    if (detected && !in_cry) {
        in_cry       = true;
        cry_onset_ms = now;
    } else if (!detected && in_cry) {
        if ((now - cry_onset_ms) >= CRY_MIN_DUR_MS) {
            cry_starts[cry_log_head] = cry_onset_ms;
            cry_log_head  = (cry_log_head + 1) % CRY_LOG;
            if (cry_log_count < CRY_LOG) cry_log_count++;
        }
        in_cry = false;
    }
    data.crying = in_cry;

    // Normalise strength 0–100 (clip at 5000 RMS = loud cry)
    data.cry_strength = (uint8_t)min(100.f, rms / 50.f);

    // Count recent cries
    int recent = 0;
    for (int i = 0; i < cry_log_count; i++) {
        if ((now - cry_starts[i]) < CRY_WINDOW_MS) recent++;
    }
    if (in_cry) recent++;
    data.cries_per_5min  = (uint8_t)min(recent, 255);
    data.cry_persistent  = (data.cries_per_5min >= 3);

    // Classify
    if (!detected) {
        data.cry_type = CRY_NONE;
    } else if (rms >= 4000.f || hpf_ratio > 0.65f || data.cry_persistent) {
        data.cry_type = CRY_DISTRESS;
    } else if (rms < 800.f) {
        data.cry_type = CRY_WEAK;
    } else {
        data.cry_type = CRY_NORMAL;
    }
}

const MicData& mic_get() { return data; }