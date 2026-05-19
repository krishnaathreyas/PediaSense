#include <Arduino.h>
#include <Wire.h>
#include <driver/i2s.h>

#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include "DHT.h"

// ======================================================
// Pins / wiring (ESP32 DevKit)
// ======================================================
// I2C (MPU6050): SDA=21, SCL=22
// DHT11: DATA=GPIO4
// INMP441 (I2S): WS/LRCLK=25, SCK/BCLK=26, SD/DOUT=33

static constexpr int I2C_SDA = 21;
static constexpr int I2C_SCL = 22;

static constexpr int DHTPIN = 4;
static constexpr uint8_t DHTTYPE = DHT11;

static constexpr int I2S_WS = 25;
static constexpr int I2S_SCK = 26;
static constexpr int I2S_SD = 33;

// ======================================================
// Sensors
// ======================================================

static DHT dht(DHTPIN, DHTTYPE);
static Adafruit_MPU6050 mpu;
static bool gHasMpu = false;

static bool i2cPing(uint8_t address) {
  Wire.beginTransmission(address);
  return Wire.endTransmission() == 0;
}

static void scanI2CBus() {
  Serial.println("I2C Scan: starting...");
  int found = 0;
  for (uint8_t addr = 1; addr < 127; addr++) {
    if (i2cPing(addr)) {
      Serial.print("I2C device found at 0x");
      if (addr < 16) Serial.print('0');
      Serial.println(addr, HEX);
      found++;
    }
    delay(2);
  }
  if (found == 0) {
    Serial.println("I2C Scan: no devices found (check SDA=21, SCL=22, GND, power)");
  } else {
    Serial.print("I2C Scan: total devices found: ");
    Serial.println(found);
  }
}

// ======================================================
// INMP441 (I2S)
// ======================================================

static constexpr i2s_port_t I2S_PORT = I2S_NUM_0;
static constexpr size_t kI2sBufferLen = 256; // int32 samples (interleaved L/R)
static int32_t sBuffer[kI2sBufferLen];

static void setupMic()
{
  i2s_config_t i2s_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = 16000,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    // Many I2S mics (e.g., INMP441) output on either Left or Right depending on L/R pin wiring.
    // Read both channels and choose the one with signal.
    .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = 64,
    .use_apll = false,
    .tx_desc_auto_clear = false,
    .fixed_mclk = 0
  };

  i2s_pin_config_t pin_config = {
    .bck_io_num = I2S_SCK,
    .ws_io_num = I2S_WS,
    .data_out_num = I2S_PIN_NO_CHANGE,
    .data_in_num = I2S_SD
  };

  i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_PORT, &pin_config);
  i2s_zero_dma_buffer(I2S_PORT);
}

static int16_t i2s32To16(int32_t raw32)
{
  // INMP441: 24-bit signed sample MSB-aligned in a 32-bit frame.
  // Keep the top 16 bits of the 24-bit sample.
  const int32_t sample24 = raw32 >> 8;
  return (int16_t)(sample24 >> 8);
}

static void readMicStats(int16_t& outRms, int16_t& outPeak)
{
  size_t bytesIn = 0;
  const esp_err_t err = i2s_read(
    I2S_PORT,
    sBuffer,
    sizeof(sBuffer),
    &bytesIn,
    portMAX_DELAY
  );

  if (err != ESP_OK || bytesIn < 2 * sizeof(int32_t)) {
    outRms = 0;
    outPeak = 0;
    return;
  }

  const size_t samples = bytesIn / sizeof(int32_t);
  int64_t sumSqL = 0;
  int64_t sumSqR = 0;
  int32_t peakL = 0;
  int32_t peakR = 0;
  size_t frames = 0;

  for (size_t i = 0; i + 1 < samples; i += 2) {
    const int16_t l = i2s32To16(sBuffer[i]);
    const int16_t r = i2s32To16(sBuffer[i + 1]);

    const int32_t al = abs((int)l);
    const int32_t ar = abs((int)r);

    sumSqL += (int64_t)al * (int64_t)al;
    sumSqR += (int64_t)ar * (int64_t)ar;

    if (al > peakL) peakL = al;
    if (ar > peakR) peakR = ar;
    frames++;
  }

  if (frames == 0) {
    outRms = 0;
    outPeak = 0;
    return;
  }

  // Choose the channel with higher RMS (INMP441 L/R pin decides which actually carries signal).
  const double rmsL = sqrt((double)sumSqL / (double)frames);
  const double rmsR = sqrt((double)sumSqR / (double)frames);

  if (rmsL >= rmsR) {
    outRms = (int16_t)min(32767.0, rmsL);
    outPeak = (int16_t)min(32767, peakL);
  } else {
    outRms = (int16_t)min(32767.0, rmsR);
    outPeak = (int16_t)min(32767, peakR);
  }
}

// ======================================================
// SETUP
// ======================================================

void setup()
{
  Serial.begin(115200);

  // I2C
  Wire.begin(I2C_SDA, I2C_SCL);

  delay(50);
  scanI2CBus();

  gHasMpu = mpu.begin(0x68, &Wire);
  Serial.print("MPU6050 present: ");
  Serial.println(gHasMpu ? "YES" : "NO");

  if (gHasMpu) {
    mpu.setAccelerometerRange(MPU6050_RANGE_8_G);
    mpu.setGyroRange(MPU6050_RANGE_500_DEG);
    mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
    Serial.println("MPU6050 Ready");
  }

  // ================= DHT11 =================

  dht.begin();
  Serial.println("DHT11 Ready");

  // ================= MEMS MIC =================

  setupMic();
  Serial.println("MEMS MIC Ready");

  Serial.println("Streaming JSON lines at 2Hz...");
}

// ======================================================
// LOOP
// ======================================================

void loop()
{
  // ================= MPU6050 =================
  float ax = 0, ay = 0, az = 0;
  float gx = 0, gy = 0, gz = 0;
  if (gHasMpu) {
    sensors_event_t accel;
    sensors_event_t gyro;
    sensors_event_t temp;
    mpu.getEvent(&accel, &gyro, &temp);
    ax = accel.acceleration.x;
    ay = accel.acceleration.y;
    az = accel.acceleration.z;
    gx = gyro.gyro.x;
    gy = gyro.gyro.y;
    gz = gyro.gyro.z;
  }

  // ================= DHT11 =================
  static unsigned long lastDhtMs = 0;
  static float lastTempC = NAN;
  static float lastHumPct = NAN;
  const unsigned long nowMs = millis();
  if (nowMs - lastDhtMs >= 2000) {
    lastTempC = dht.readTemperature();
    lastHumPct = dht.readHumidity();
    lastDhtMs = nowMs;
  }
  const float temperatureC = lastTempC;
  const float humidityPct = lastHumPct;

  // ================= INMP441 =================
  int16_t micRms = 0;
  int16_t micPeak = 0;
  readMicStats(micRms, micPeak);

  // ================= SERIAL OUTPUT =================
  // One JSON object per line (easy to parse/display)
  char json[256];
  const unsigned long ms = nowMs;

  const bool hasTemp = !isnan(temperatureC);
  const bool hasHum = !isnan(humidityPct);

  char tempBuf[16];
  char humBuf[16];
  if (hasTemp) {
    snprintf(tempBuf, sizeof(tempBuf), "%.2f", temperatureC);
  } else {
    strncpy(tempBuf, "null", sizeof(tempBuf));
    tempBuf[sizeof(tempBuf) - 1] = '\0';
  }
  if (hasHum) {
    snprintf(humBuf, sizeof(humBuf), "%.2f", humidityPct);
  } else {
    strncpy(humBuf, "null", sizeof(humBuf));
    humBuf[sizeof(humBuf) - 1] = '\0';
  }

  // NOTE: DHT11 updates slowly; reading faster than ~1Hz can return NaN.
  snprintf(
    json,
    sizeof(json),
    "{\"t_ms\":%lu,\"mpu_ok\":%s,\"ax\":%.3f,\"ay\":%.3f,\"az\":%.3f,\"gx\":%.3f,\"gy\":%.3f,\"gz\":%.3f,\"temp_c\":%s,\"hum\":%s,\"mic_rms\":%d,\"mic_peak\":%d}",
    ms,
    gHasMpu ? "true" : "false",
    ax, ay, az,
    gx, gy, gz,
    tempBuf,
    humBuf,
    (int)micRms,
    (int)micPeak
  );
  Serial.println(json);

  delay(500);
}