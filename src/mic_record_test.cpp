#include <Arduino.h>
#include <driver/i2s.h>
#include <esp_heap_caps.h>

static constexpr int MIC_SCK_PIN = 18;
static constexpr int MIC_WS_PIN = 19;
static constexpr int MIC_SD_PIN = 23;

static constexpr i2s_port_t I2S_PORT = I2S_NUM_0;
static constexpr int SAMPLE_RATE = 16000;
static constexpr int RECORD_SECONDS = 4;
static constexpr int TOTAL_SAMPLES = SAMPLE_RATE * RECORD_SECONDS; // 64000
static constexpr size_t TOTAL_BYTES = TOTAL_SAMPLES * sizeof(int16_t);
static constexpr int RAW_CHUNK_SAMPLES = 512; // int32 entries (interleaved L/R)

static int32_t rawChunk[RAW_CHUNK_SAMPLES];

static bool initMicI2S() {
  i2s_config_t cfg = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
      .sample_rate = SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
      .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
      .communication_format = I2S_COMM_FORMAT_STAND_I2S,
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = 8,
      .dma_buf_len = 128,
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

static int16_t *allocAudioBuffer() {
  int16_t *audioBuf = NULL;

  if (psramFound()) {
    audioBuf = (int16_t *)heap_caps_malloc(TOTAL_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  }
  if (!audioBuf) {
    audioBuf = (int16_t *)malloc(TOTAL_BYTES);
  }

  return audioBuf;
}

static void waitForAnyKey() {
  Serial.println("Send any key to start 4-second recording...");
  while (!Serial.available()) {
    delay(10);
  }
  while (Serial.available()) {
    Serial.read();
  }
}

static void recordAndDump() {
  Serial.println("RECORDING...");
  Serial.println("DONE RECORDING. Sending PCM dump...");
  Serial.println("PCM16 16000 64000");

  int captured = 0;
  while (captured < TOTAL_SAMPLES) {
    size_t bytesRead = 0;
    i2s_read(I2S_PORT, rawChunk, sizeof(rawChunk), &bytesRead, portMAX_DELAY);

    int rawCount = (int)(bytesRead / sizeof(int32_t));
    for (int i = 0; i + 1 < rawCount && captured < TOTAL_SAMPLES; i += 2) {
      // Left channel only. final shift: raw >> 16.
      int32_t leftRaw = rawChunk[i];
      int16_t sample = (int16_t)(leftRaw >> 16);
      Serial.println(sample);
      captured++;
    }
  }
  Serial.println("END OF DUMP");
}

void setup() {
  Serial.begin(115200);
  delay(300);

  if (!initMicI2S()) {
    Serial.println("I2S INIT FAILED");
    while (true) {
      delay(1000);
    }
  }
}

void loop() {
  waitForAnyKey();
  recordAndDump();
}
