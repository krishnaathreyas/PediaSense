#include "temp.h"
#include <Wire.h>

#define MLX_ADDR 0x5A
#define MLX_OBJ_TEMP 0x07
#define MLX_AMB_TEMP 0x06

// MLX90614 shares the main I2C bus (SDA=GPIO21, SCL=GPIO22)
// Clock is dropped to 100 kHz for each MLX read, then restored to 400 kHz.

static TempData data = {-999.0f, -999.0f, false};
static bool ok = false;

static float read_temp(uint8_t reg) {
  Wire.setClock(100000); // MLX needs ≤100 kHz
  Wire.beginTransmission(MLX_ADDR);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    Wire.setClock(400000);
    return -999.0f;
  }
  Wire.requestFrom((uint8_t)MLX_ADDR, (uint8_t)3);
  if (Wire.available() < 3) {
    Wire.setClock(400000);
    return -999.0f;
  }
  uint8_t lo = Wire.read();
  uint8_t hi = Wire.read();
  Wire.read();           // discard PEC
  Wire.setClock(400000); // restore for other I2C devices
  uint16_t raw = ((uint16_t)(hi & 0x7F) << 8) | lo;
  return raw * 0.02f - 273.15f;
}

bool temp_init() {
  // Wire.begin() is already called in main.cpp setup()
  Wire.setClock(100000);
  delay(50); // give MLX time to power up

  // ── I2C bus scan for diagnostics ──
  Serial.println("[TEMP] Scanning I2C bus for devices...");
  int deviceCount = 0;
  for (uint8_t addr = 1; addr < 127; addr++) {
    Wire.beginTransmission(addr);
    uint8_t err = Wire.endTransmission();
    if (err == 0) {
      Serial.printf("[TEMP]   Found device at 0x%02X\n", addr);
      deviceCount++;
    }
  }
  Serial.printf("[TEMP]   Scan complete: %d device(s) found\n", deviceCount);

  // ── Try to reach MLX at 0x5A with retries ──
  bool found = false;
  for (int attempt = 0; attempt < 3; attempt++) {
    Wire.beginTransmission(MLX_ADDR);
    uint8_t err = Wire.endTransmission();
    Serial.printf("[TEMP]   MLX probe attempt %d -> err=%d\n", attempt + 1,
                  err);
    if (err == 0) {
      found = true;
      break;
    }
    delay(100);
  }

  Wire.setClock(400000);
  if (!found) {
    Serial.println("[TEMP]   MLX90614 NOT found at 0x5A!");
    return false;
  }
  Serial.println("[TEMP]   MLX90614 OK");
  ok = true;
  return true;
}

void temp_update() {
  if (!ok)
    return;
  float sk = read_temp(MLX_OBJ_TEMP);
  float am = read_temp(MLX_AMB_TEMP);
  data.valid = (sk > -50.0f && sk < 60.0f);
  data.skin_c = sk;
  data.amb_c = am;
}

const TempData &temp_get() { return data; }
