#pragma once
#include <Arduino.h>

/**
 * @brief Skin temperature module — MLX90614
 *
 * Raw SMBus reads at 100 kHz.  Wire clock is set to 100 kHz before
 * each read and restored to 400 kHz afterwards so MAX30102 is
 * unaffected.
 *
 * Pins: I2C  SDA=GPIO21  SCL=GPIO22
 */

struct TempData {
    float skin_c;    // object (skin) temperature °C  (-999 = error)
    float amb_c;     // ambient temperature °C         (-999 = error)
    bool  valid;
};

bool          temp_init();
void          temp_update();
const TempData& temp_get();
