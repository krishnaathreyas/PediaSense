#pragma once
#include <Arduino.h>

/**
 * @brief IMU module — MPU6050
 *
 * Raw-register reads (clone-safe; works with WHO_AM_I = 0x70).
 * Provides accel XYZ, gyro XYZ, and a scalar motion-magnitude
 * used by apnea detection and breathing cross-validation.
 *
 * Pins: I2C  SDA=GPIO21  SCL=GPIO22  (shared bus)
 */

struct ImuData {
    float ax, ay, az;        // m/s²  (±4g range)
    float gx, gy, gz;        // °/s   (±500°/s range)
    float accel_mag;         // sqrt(ax²+ay²+az²)  m/s²
    float motion_delta;      // |accel_mag - prev_accel_mag| — spike = motion
};

bool       imu_init();
void       imu_update();
const ImuData& imu_get();
