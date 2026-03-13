#pragma once

/**
 * BLE GATT Server — PediaSense
 *
 * Service UUID: 4FAFC201-1FB5-459E-8FCC-C5C9C331914B
 *
 * Characteristics (all Notify | Read, 4 bytes each):
 *
 *   VitalSigns  bebe0001-...
 *     [0] HR (beats/min, uint8)
 *     [1] SpO2 (%, uint8)
 *     [2–3] Skin temp × 100 (int16 LE)
 *
 *   Motion      bebe0002-...
 *     [0–1] Accel magnitude × 1000 (uint16 LE)
 *     [2]  Breath rate (breaths/min, uint8)
 *     [3]  Motion state (0=still, 1=moving)
 *
 *   Audio       bebe0003-...
 *     [0] Cry detected (0/1)
 *     [1] Cry strength (0–100)
 *     [2–3] Mic RMS (uint16 LE, clamped to 65535)
 *
 *   RiskAlert   bebe0004-...
 *     [0] Risk level (0=NORMAL, 1=AMBER, 2=RED)
 *     [1] Respiratory score (0–100)
 *     [2] Hydration score (0–100)
 *     [3] Flags (bit0=apnea, bit1=spo2_low, bit2=cry_persist, bit3=lbw)
 */

void ble_server_init(const char* device_name = "PediaSense");
void ble_server_notify();
bool ble_server_connected();
