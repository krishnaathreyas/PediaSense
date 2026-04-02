#include <Arduino.h>
#include <Wire.h>

static constexpr uint8_t SDA_PIN = 21;
static constexpr uint8_t SCL_PIN = 22;
static constexpr uint32_t I2C_FREQ_HZ = 100000;

void scan_i2c_bus() {
  int found_count = 0;

  Serial.println("\n[I2C] Scanning addresses 0x01 to 0x7E...");
  for (uint8_t address = 1; address < 127; address++) {
    Wire.beginTransmission(address);
    uint8_t error = Wire.endTransmission();

    if (error == 0) {
      Serial.printf("[I2C] Found device at 0x%02X\n", address);
      found_count++;
    }
  }

  if (found_count == 0) {
    Serial.println("[I2C] No devices found.");
  } else {
    Serial.printf("[I2C] Scan done. Total devices: %d\n", found_count);
  }
}

void setup() {
  Serial.begin(115200);
  delay(400);

  Serial.println("\n[I2C Scanner] ESP32 startup");
  Serial.printf("[I2C Scanner] SDA=%d, SCL=%d, Freq=%lu Hz\n", SDA_PIN, SCL_PIN,
                I2C_FREQ_HZ);

  Wire.begin(SDA_PIN, SCL_PIN);
  Wire.setClock(I2C_FREQ_HZ);

  scan_i2c_bus();
}

void loop() {
  delay(2000);
  scan_i2c_bus();
}
