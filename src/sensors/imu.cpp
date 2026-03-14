#include "imu.h"
#include <Wire.h>

#define MPU_ADDR    0x68
#define PWR_MGMT_1  0x6B
#define ACCEL_XOUT  0x3B
#define ACCEL_CFG   0x1C
#define GYRO_CFG    0x1B
#define GYRO_XOUT   0x43

static ImuData data = {0};
static bool    ok   = false;

static void write_reg(uint8_t reg, uint8_t val) {
    Wire.beginTransmission(MPU_ADDR);
    Wire.write(reg); Wire.write(val);
    Wire.endTransmission();
}

static int16_t read16(uint8_t reg) {
    Wire.beginTransmission(MPU_ADDR); Wire.write(reg); Wire.endTransmission(false);
    Wire.requestFrom(MPU_ADDR, 2);
    return ((int16_t)Wire.read() << 8) | Wire.read();
}

bool imu_init() {
    Wire.beginTransmission(MPU_ADDR);
    if (Wire.endTransmission() != 0) return false;

    write_reg(PWR_MGMT_1, 0x00);   // wake from sleep
    delay(10);
    write_reg(ACCEL_CFG, 0x08);    // ±4g  → 8192 LSB/g
    write_reg(GYRO_CFG,  0x08);    // ±500°/s → 65.5 LSB/°/s
    ok = true;
    return true;
}

void imu_update() {
    if (!ok) return;

    // Read accel (6 bytes) + gyro (6 bytes) in one burst
    Wire.beginTransmission(MPU_ADDR); Wire.write(ACCEL_XOUT); Wire.endTransmission(false);
    Wire.requestFrom(MPU_ADDR, 14);
    int16_t rawAx = ((int16_t)Wire.read() << 8) | Wire.read();
    int16_t rawAy = ((int16_t)Wire.read() << 8) | Wire.read();
    int16_t rawAz = ((int16_t)Wire.read() << 8) | Wire.read();
    Wire.read(); Wire.read();  // skip temperature bytes
    int16_t rawGx = ((int16_t)Wire.read() << 8) | Wire.read();
    int16_t rawGy = ((int16_t)Wire.read() << 8) | Wire.read();
    int16_t rawGz = ((int16_t)Wire.read() << 8) | Wire.read();

    data.ax = rawAx / 8192.0f * 9.81f;
    data.ay = rawAy / 8192.0f * 9.81f;
    data.az = rawAz / 8192.0f * 9.81f;
    data.gx = rawGx / 65.5f;
    data.gy = rawGy / 65.5f;
    data.gz = rawGz / 65.5f;

    float prev_mag    = data.accel_mag;
    data.accel_mag    = sqrtf(data.ax*data.ax + data.ay*data.ay + data.az*data.az);
    data.motion_delta = fabsf(data.accel_mag - prev_mag);
}

const ImuData& imu_get() { return data; }
