#pragma once

/**
 * BLE GATT Server — demo profile for Flutter BLE integration.
 *
 * Device name: PediaSense
 * Service UUID: 12345678-1234-1234-1234-1234567890ab
 * Characteristic UUID: abcd1234-5678-1234-5678-abcdef123456
 *
 * Characteristic supports READ + NOTIFY and emits dummy sensor JSON every 1s.
 */

void ble_server_init(const char* device_name = "PediaSense");
void ble_server_notify();
bool ble_server_connected();
