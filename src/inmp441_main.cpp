#include <Arduino.h>
#include <driver/i2s.h>

// Mic-only wiring (current test):
// VDD -> 3V3, GND -> GND, SD -> GPIO32, SCK -> GPIO14, WS -> GPIO15, L/R -> GND
static constexpr int I2S_SCK_PIN = 14;
static constexpr int I2S_WS_PIN  = 15;
static constexpr int I2S_SD_PIN  = 32;

static constexpr i2s_port_t I2S_PORT = I2S_NUM_0;
static constexpr int SAMPLE_RATE = 16000;
static constexpr int BUF_SAMPLES = 512; // int32 samples (interleaved L,R)

static int32_t raw32[BUF_SAMPLES];

bool mic_init() {
  i2s_config_t cfg = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
      .sample_rate = SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
      .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
      .communication_format = I2S_COMM_FORMAT_STAND_I2S,
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = 8,
      .dma_buf_len = 64,
      .use_apll = false,
      .tx_desc_auto_clear = false,
      .fixed_mclk = 0,
  };

  i2s_pin_config_t pins = {
      .bck_io_num = I2S_SCK_PIN,
      .ws_io_num = I2S_WS_PIN,
      .data_out_num = I2S_PIN_NO_CHANGE,
      .data_in_num = I2S_SD_PIN,
  };

  if (i2s_driver_install(I2S_PORT, &cfg, 0, NULL) != ESP_OK) return false;
  if (i2s_set_pin(I2S_PORT, &pins) != ESP_OK) return false;
  i2s_zero_dma_buffer(I2S_PORT);
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(400);
  Serial.println("\n=== INMP441 MIC-ONLY TEST ===");
  Serial.printf("Pins: SD=%d SCK=%d WS=%d\n", I2S_SD_PIN, I2S_SCK_PIN, I2S_WS_PIN);

  if (!mic_init()) {
    Serial.println("[MIC] init FAIL");
    while (true) delay(1000);
  }
  Serial.println("[MIC] init OK");
  Serial.println("Clap / speak near mic and watch RMS, peak, raw samples.");
}

void loop() {
  size_t bytesRead = 0;
  i2s_read(I2S_PORT, raw32, sizeof(raw32), &bytesRead, 100 / portTICK_PERIOD_MS);

  int samples = bytesRead / (int)sizeof(int32_t); // interleaved L,R
  if (samples < 2) {
    Serial.println("MIC │ no samples");
    delay(300);
    return;
  }

  int64_t sumSq = 0;
  int32_t peak = 0;
  int32_t first8[8] = {0};
  int show = 0;
  int monoCount = 0;

  for (int i = 0; i + 1 < samples; i += 2) {
    int32_t left  = raw32[i] >> 8;      // 24-bit signed
    int32_t right = raw32[i + 1] >> 8;  // 24-bit signed

    int32_t absL = left < 0 ? -left : left;
    int32_t absR = right < 0 ? -right : right;

    // Auto-pick active channel (handles L/R strap mismatch)
    int32_t v = (absL >= absR) ? left : right;

    if (show < 8) first8[show++] = v;

    int32_t a = v < 0 ? -v : v;
    if (a > peak) peak = a;
    sumSq += (int64_t)v * v;
    monoCount++;
  }

  float rms = (monoCount > 0) ? sqrtf((float)(sumSq / monoCount)) : 0.0f;

  Serial.printf("MIC │ RMS=%.0f  peak=%ld  monoSamples=%d  status=%s\n",
                rms, (long)peak, monoCount, (peak > 0 ? "DATA" : "NO DATA"));

  Serial.print("RAW │ ");
  for (int i = 0; i < show; i++) {
    Serial.printf("%ld", (long)first8[i]);
    if (i != show - 1) Serial.print(", ");
  }
  Serial.println();

  delay(1000);
}
