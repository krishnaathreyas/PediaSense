#include "mic.h"
#include <driver/i2s.h>

#define I2S_SCK_PIN   26
#define I2S_WS_PIN    25
#define I2S_SD_PIN    34
#define I2S_PORT      I2S_NUM_0
#define SAMPLE_RATE   16000
// Active threshold: quiet room ≈ 500, normal speech ≈ 5000+
#define MIC_ACTIVE_THRESHOLD  800.0f

int32_t mic_buf[MIC_BUF_SIZE] = {0};
int     mic_buf_count = 0;

static MicData data = {0.0f, 0, false};
static bool    ok   = false;

static int32_t raw32[MIC_BUF_SIZE];

bool mic_init() {
    i2s_config_t cfg = {
        .mode                 = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
        .sample_rate          = SAMPLE_RATE,
        .bits_per_sample      = I2S_BITS_PER_SAMPLE_32BIT,
        .channel_format       = I2S_CHANNEL_FMT_ONLY_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags     = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count        = 8,
        .dma_buf_len          = 64,
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
    if (i2s_set_pin(I2S_PORT, &pins) != ESP_OK) return false;
    i2s_zero_dma_buffer(I2S_PORT);
    ok = true;
    return true;
}

void mic_update() {
    if (!ok) return;
    size_t bytesRead = 0;
    // Non-blocking: 0 ms timeout — take whatever is in the DMA buffer right now
    i2s_read(I2S_PORT, raw32, sizeof(raw32), &bytesRead, 0);

    int count = bytesRead / sizeof(int32_t);
    if (count == 0) return;

    int64_t sum  = 0;
    int32_t peak = 0;
    for (int i = 0; i < count; i++) {
        int32_t s = raw32[i] >> 8;   // 24-bit left-justified → signed 24-bit
        mic_buf[i] = s;
        int32_t a  = s < 0 ? -s : s;
        if (a > peak) peak = a;
        sum += (int64_t)s * s;
    }
    mic_buf_count  = count;
    data.rms       = sqrtf((float)(sum / count));
    data.peak      = peak;
    data.active    = (data.rms > MIC_ACTIVE_THRESHOLD);
}

const MicData& mic_get() { return data; }
