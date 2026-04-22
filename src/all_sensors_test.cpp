#include <Arduino.h>
#include <Wire.h>
#include <driver/i2s.h>
#include <math.h>

#include "MAX30105.h"

static constexpr uint8_t SDA_PIN = 21;
static constexpr uint8_t SCL_PIN = 22;
static constexpr int MIC_SCK = 14;
static constexpr int MIC_WS = 15;
static constexpr int MIC_SD = 32;

static constexpr uint8_t MPU_ADDR = 0x68;
static constexpr uint8_t MLX_ADDR = 0x5A;

static constexpr i2s_port_t I2S_PORT = I2S_NUM_0;
static constexpr int SAMPLE_RATE = 16000;
static constexpr int MIC_BUF_SAMPLES = 512;

static int32_t micRaw[MIC_BUF_SAMPLES];

static MAX30105 ppg;
static bool ppgOk = false;
static bool mpuOk = false;
static bool mlxOk = false;
static bool micOk = false;

static bool i2cDevicePresent(uint8_t addr) {
  Wire.beginTransmission(addr);
  return Wire.endTransmission() == 0;
}

static bool initMPU() {
  if (!i2cDevicePresent(MPU_ADDR)) {
    return false;
  }

  // Wake up MPU6050 from sleep mode.
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B);
  Wire.write(0x00);
  if (Wire.endTransmission() != 0) {
    return false;
  }

  // Set gyro full-scale to +/-250 dps.
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x1B);
  Wire.write(0x00);
  return Wire.endTransmission() == 0;
}

static bool readMPUGyroDps(float &gx, float &gy, float &gz) {
  gx = 0.0f;
  gy = 0.0f;
  gz = 0.0f;

  if (!mpuOk) {
    return false;
  }

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x43); // GYRO_XOUT_H
  if (Wire.endTransmission(false) != 0) {
    return false;
  }

  uint8_t need = 6;
  uint8_t got = Wire.requestFrom((int)MPU_ADDR, (int)need, (int)true);
  if (got != need) {
    return false;
  }

  int16_t rawX = (int16_t)((Wire.read() << 8) | Wire.read());
  int16_t rawY = (int16_t)((Wire.read() << 8) | Wire.read());
  int16_t rawZ = (int16_t)((Wire.read() << 8) | Wire.read());

  // For +/-250 dps: 131 LSB per dps.
  gx = rawX / 131.0f;
  gy = rawY / 131.0f;
  gz = rawZ / 131.0f;
  return true;
}

static bool readMLXObjectTempC(float &tempC) {
  tempC = -999.0f;

  if (!mlxOk) {
    return false;
  }

  Wire.beginTransmission(MLX_ADDR);
  Wire.write(0x07); // Object temperature register.
  if (Wire.endTransmission(false) != 0) {
    return false;
  }

  uint8_t need = 3;
  uint8_t got = Wire.requestFrom((int)MLX_ADDR, (int)need, (int)true);
  if (got != need) {
    return false;
  }

  uint8_t lsb = Wire.read();
  uint8_t msb = Wire.read();
  (void)Wire.read(); // PEC

  uint16_t raw = (uint16_t)(((uint16_t)msb << 8) | lsb);
  if (raw == 0x0000 || raw == 0xFFFF) {
    return false;
  }

  tempC = (raw * 0.02f) - 273.15f;
  return true;
}

static bool initMic() {
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
      .bck_io_num = MIC_SCK,
      .ws_io_num = MIC_WS,
      .data_out_num = I2S_PIN_NO_CHANGE,
      .data_in_num = MIC_SD,
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

static bool readMic(float &rms, int32_t &peak, bool &active) {
  rms = 0.0f;
  peak = 0;
  active = false;

  if (!micOk) {
    return false;
  }

  size_t bytesRead = 0;
  i2s_read(I2S_PORT, micRaw, sizeof(micRaw), &bytesRead, 30 / portTICK_PERIOD_MS);

  int samples = (int)(bytesRead / sizeof(int32_t));
  if (samples < 2) {
    return false;
  }

  int64_t sumSq = 0;
  int monoCount = 0;

  for (int i = 0; i + 1 < samples; i += 2) {
    int32_t left = micRaw[i] >> 8;
    int32_t right = micRaw[i + 1] >> 8;
    int32_t v = (abs(left) >= abs(right)) ? left : right;
    int32_t a = abs(v);

    if (a > peak) {
      peak = a;
    }
    sumSq += (int64_t)v * v;
    monoCount++;
  }

  if (monoCount <= 0) {
    return false;
  }

  rms = sqrtf((float)(sumSq / monoCount));
  active = rms > 400.0f;
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(300);

  Serial.println("\\n=== PediaSense All Sensors Test ===");
  Serial.printf("Pins: SDA=%u SCL=%u | MIC_SCK=%d MIC_WS=%d MIC_SD=%d\\n", SDA_PIN,
                SCL_PIN, MIC_SCK, MIC_WS, MIC_SD);

  Wire.begin(SDA_PIN, SCL_PIN);
  delay(50);

  ppgOk = ppg.begin(Wire, I2C_SPEED_FAST);
  if (ppgOk) {
    ppg.setup(80, 1, 2, 100, 411, 4096);
    ppg.setPulseAmplitudeRed(0x3F);
    ppg.setPulseAmplitudeIR(0x3F);
    ppg.setPulseAmplitudeGreen(0);
  }

  mpuOk = initMPU();
  mlxOk = i2cDevicePresent(MLX_ADDR);
  micOk = initMic();

  Serial.printf("Init: MAX30102=%s MPU6050=%s MLX90614=%s INMP441=%s\\n",
                ppgOk ? "OK" : "FAIL", mpuOk ? "OK" : "FAIL",
                mlxOk ? "OK" : "FAIL", micOk ? "OK" : "FAIL");
}

void loop() {
  long ir = 0;
  long red = 0;

  if (ppgOk) {
    ppg.check();
    if (ppg.available()) {
      ir = ppg.getIR();
      red = ppg.getRed();
      ppg.nextSample();
    }
  }

  float gx = 0.0f;
  float gy = 0.0f;
  float gz = 0.0f;
  bool gyroRead = readMPUGyroDps(gx, gy, gz);

  float tempC = -999.0f;
  bool tempRead = readMLXObjectTempC(tempC);

  float micRms = 0.0f;
  int32_t micPeak = 0;
  bool micActive = false;
  bool micRead = readMic(micRms, micPeak, micActive);
  const char *micStatus = "FAIL";
  if (micRead) {
    micStatus = (micPeak == 0 && micRms < 1.0f) ? "NO_DATA" : "OK";
  }

  Serial.println("---------------- SENSOR SNAPSHOT ----------------");
  Serial.printf("PPG  | IR=%-6ld RED=%-6ld\n", ir, red);
  Serial.printf("GYRO | X=%7.1f Y=%7.1f Z=%7.1f dps  [%s]\n", gx, gy, gz,
                gyroRead ? "OK" : "FAIL");
  Serial.printf("TEMP | %.1f C [%s]\n", tempC, tempRead ? "OK" : "FAIL");
  Serial.printf("MIC  | RMS=%-6.0f PEAK=%-6ld ACTIVE=%d [%s]\n", micRms,
                (long)micPeak, micActive ? 1 : 0, micStatus);
  Serial.println("-------------------------------------------------");

  delay(1000);
}
