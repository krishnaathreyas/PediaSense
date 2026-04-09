#include <Arduino.h>
#include <Wire.h>

static constexpr uint8_t SDA_PIN = 21;
static constexpr uint8_t SCL_PIN = 22;
static constexpr uint8_t MLX_DEFAULT_ADDR = 0x5A;

static float mlx_read_temp_c(uint8_t addr, uint8_t reg, bool &ok) {
  ok = false;
  Wire.beginTransmission(addr);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return -999.0f;

  uint8_t got = Wire.requestFrom(addr, (uint8_t)3);
  if (got < 3) return -999.0f;

  uint8_t lo = Wire.read();
  uint8_t hi = Wire.read();
  Wire.read(); // PEC, not validated in this quick diagnostic

  uint16_t raw = ((uint16_t)(hi & 0x7F) << 8) | lo;
  float c = raw * 0.02f - 273.15f;
  ok = true;
  return c;
}

static int scan_i2c() {
  int found = 0;
  Serial.println("[I2C] Scan start (0x01..0x7E)");
  for (uint8_t a = 1; a < 127; a++) {
    Wire.beginTransmission(a);
    if (Wire.endTransmission() == 0) {
      Serial.printf("[I2C] Found 0x%02X\n", a);
      found++;
    }
  }
  Serial.printf("[I2C] Scan done, found=%d\n", found);
  return found;
}

static void mlx_probe_addr(uint8_t addr) {
  bool okAmb = false;
  bool okObj = false;
  float amb = mlx_read_temp_c(addr, 0x06, okAmb);
  float obj = mlx_read_temp_c(addr, 0x07, okObj);

  if (okAmb && okObj) {
    Serial.printf("[MLX] 0x%02X READ OK  amb=%.2fC  obj=%.2fC\n", addr, amb, obj);
  } else {
    Serial.printf("[MLX] 0x%02X READ FAIL (amb_ok=%d obj_ok=%d)\n", addr,
                  okAmb ? 1 : 0, okObj ? 1 : 0);
  }
}

void setup() {
  Serial.begin(115200);
  delay(500);

  Serial.println("\n=== MLX90614 DIAGNOSTIC ===");
  Serial.printf("Pins SDA=%d SCL=%d\n", SDA_PIN, SCL_PIN);

  Wire.begin(SDA_PIN, SCL_PIN);

  Wire.setClock(100000);
  Serial.println("[I2C] Bus clock=100kHz");
  scan_i2c();

  Serial.println("[MLX] Probing common addresses at 100kHz...");
  mlx_probe_addr(MLX_DEFAULT_ADDR);
  mlx_probe_addr(0x5B);
  mlx_probe_addr(0x48);

  Wire.setClock(400000);
  Serial.println("[I2C] Bus clock=400kHz");
  scan_i2c();

  Serial.println("[MLX] Probing common addresses at 400kHz...");
  mlx_probe_addr(MLX_DEFAULT_ADDR);
  mlx_probe_addr(0x5B);
  mlx_probe_addr(0x48);

  Serial.println("[MLX] Diagnostics running. Rechecking every 2s at 100kHz.");
}

void loop() {
  Wire.setClock(100000);
  bool okAmb = false;
  bool okObj = false;
  float amb = mlx_read_temp_c(MLX_DEFAULT_ADDR, 0x06, okAmb);
  float obj = mlx_read_temp_c(MLX_DEFAULT_ADDR, 0x07, okObj);

  if (okAmb && okObj) {
    Serial.printf("[MLX] 0x5A LIVE  amb=%.2fC  obj=%.2fC\n", amb, obj);
  } else {
    Serial.printf("[MLX] 0x5A LIVE FAIL (amb_ok=%d obj_ok=%d)\n", okAmb ? 1 : 0,
                  okObj ? 1 : 0);
  }

  delay(2000);
}
