#include <Arduino.h>
#include <driver/i2s.h>
#include <math.h>

static constexpr int MIC_SCK_PIN = 18;
static constexpr int MIC_WS_PIN = 19;
static constexpr int MIC_SD_PIN = 23;

static constexpr i2s_port_t I2S_PORT = I2S_NUM_0;
static constexpr int SAMPLE_RATE = 16000;
static constexpr int BUF_SAMPLES = 256;

static int32_t rawBuf[BUF_SAMPLES];

static bool initMicI2S() {
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
      .bck_io_num = MIC_SCK_PIN,
      .ws_io_num = MIC_WS_PIN,
      .data_out_num = I2S_PIN_NO_CHANGE,
      .data_in_num = MIC_SD_PIN,
  };

  if (i2s_driver_install(I2S_PORT, &cfg, 0, NULL) != ESP_OK) {
    return false;
  }
  if (i2s_set_pin(I2S_PORT, &pins) != ESP_OK) {
    return false;
  }
  i2s_zero_dma_buffer(I2S_PORT);
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(300);

  Serial.println("=== INMP441 MINIMAL TEST ===");
  Serial.printf("Pins SCK=%d WS=%d SD=%d\n", MIC_SCK_PIN, MIC_WS_PIN, MIC_SD_PIN);

  if (!initMicI2S()) {
    Serial.println("I2S INIT FAILED");
    while (true) {
      delay(1000);
    }
  }

  Serial.println("I2S INIT OK");
}

void loop() {
  size_t bytesRead = 0;
  i2s_read(I2S_PORT, rawBuf, sizeof(rawBuf), &bytesRead, 100 / portTICK_PERIOD_MS);

  Serial.printf("bytesRead=%u\n", (unsigned int)bytesRead);

  if (bytesRead == 0) {
    Serial.println("NO DATA - I2S read returned nothing");
    delay(500);
    return;
  }

  int count = (int)(bytesRead / sizeof(int32_t));
  int show = count < 4 ? count : 4;
  Serial.print("raw[0..3]=");
  for (int i = 0; i < show; i++) {
    Serial.printf("%ld", (long)rawBuf[i]);
    if (i < show - 1) {
      Serial.print(", ");
    }
  }
  Serial.println();

  bool allZeros = true;
  int64_t sumSq = 0;
  int32_t peak = 0;

  for (int i = 0; i < count; i++) {
    int32_t v = rawBuf[i];
    if (v != 0) {
      allZeros = false;
    }

    int32_t a = abs(v);
    if (a > peak) {
      peak = a;
    }
    sumSq += (int64_t)v * v;
  }

  float rms = (count > 0) ? sqrtf((float)sumSq / (float)count) : 0.0f;

  Serial.printf("RMS=%.2f PEAK=%ld\n", rms, (long)peak);

  if (allZeros) {
    Serial.println("ALL ZEROS - mic connected but no signal");
  }

  if (rms > 100.0f) {
    Serial.println("MIC OK - signal detected");
  }

  delay(500);
}
