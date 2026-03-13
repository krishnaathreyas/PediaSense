#include "temp.h"
#include <Wire.h>

#define MLX_ADDR     0x5A
#define MLX_OBJ_TEMP 0x07
#define MLX_AMB_TEMP 0x06

static TempData data = {-999.0f, -999.0f, false};
static bool     ok   = false;

static float read_temp(uint8_t reg) {
    Wire.setClock(100000);
    Wire.beginTransmission(MLX_ADDR);
    Wire.write(reg);
    if (Wire.endTransmission(false) != 0) return -999.0f;
    Wire.requestFrom(MLX_ADDR, 3);
    if (Wire.available() < 3) return -999.0f;
    uint8_t lo  = Wire.read();
    uint8_t hi  = Wire.read();
    Wire.read();   // discard PEC
    Wire.setClock(400000);  // restore fast clock for MAX30102
    uint16_t raw = ((uint16_t)(hi & 0x7F) << 8) | lo;
    return raw * 0.02f - 273.15f;
}

bool temp_init() {
    Wire.setClock(100000);
    Wire.beginTransmission(MLX_ADDR);
    bool found = (Wire.endTransmission() == 0);
    Wire.setClock(400000);
    if (!found) return false;
    ok = true;
    return true;
}

void temp_update() {
    if (!ok) return;
    float sk = read_temp(MLX_OBJ_TEMP);
    float am = read_temp(MLX_AMB_TEMP);
    data.valid  = (sk > -50.0f && sk < 60.0f);
    data.skin_c = sk;
    data.amb_c  = am;
}

const TempData& temp_get() { return data; }
