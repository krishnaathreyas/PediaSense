#include "ble_server.h"
#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// Single-service BLE profile expected by Flutter demo client.
#define SVC_UUID  "12345678-1234-1234-1234-1234567890ab"
#define CHAR_UUID "abcd1234-5678-1234-5678-abcdef123456"

static BLEServer* pServer = nullptr;
static BLECharacteristic* pData = nullptr;

static bool deviceConnected    = false;
static bool prevConnected      = false;
static unsigned long lastNotifyMs = 0;
static uint32_t sampleCounter = 0;

// ── Connection callbacks ──────────────────────────────────────────────────────
class ConnCB : public BLEServerCallbacks {
    void onConnect(BLEServer*) override {
        deviceConnected = true;
    }
    void onDisconnect(BLEServer*) override {
        deviceConnected = false;
    }
};

static String build_dummy_payload() {
    const int hr = 110 + (sampleCounter % 20);          // 110..129
    const int spo2 = 95 + (sampleCounter % 4);          // 95..98
    const int br = 28 + (sampleCounter % 8);            // 28..35
    const float temp = 36.5f + ((sampleCounter % 10) * 0.05f); // 36.5..36.95

    String payload = "{";
    payload += "\"counter\":" + String(sampleCounter) + ",";
    payload += "\"hr\":" + String(hr) + ",";
    payload += "\"spo2\":" + String(spo2) + ",";
    payload += "\"br\":" + String(br) + ",";
    payload += "\"temp\":" + String(temp, 2);
    payload += "}";
    return payload;
}

void ble_server_init(const char* device_name) {
    BLEDevice::init(device_name);
    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new ConnCB());

    BLEService* svc = pServer->createService(SVC_UUID);
    pData = svc->createCharacteristic(
        CHAR_UUID,
        BLECharacteristic::PROPERTY_READ |
        BLECharacteristic::PROPERTY_NOTIFY
    );
    pData->addDescriptor(new BLE2902());
    pData->setValue("{\"status\":\"booting\"}");

    svc->start();

    BLEAdvertising* adv = BLEDevice::getAdvertising();
    adv->setScanResponse(true);
    adv->addServiceUUID(SVC_UUID);
    adv->setMinPreferred(0x06);   // helps with iOS connections
    adv->setMinPreferred(0x12);
    BLEDevice::startAdvertising();

}

void ble_server_notify() {
    // Restart advertising if disconnected
    if (!deviceConnected && prevConnected) {
        delay(500);  // give stack time to tidy up
        BLEDevice::startAdvertising();
        prevConnected = false;
    }
    if (deviceConnected && !prevConnected) {
        prevConnected = true;
    }

    // Emit dummy data every 1 second so scanner/client sees activity.
    const unsigned long now = millis();
    if (now - lastNotifyMs < 1000) return;
    lastNotifyMs = now;

    sampleCounter++;
    String payload = build_dummy_payload();
    pData->setValue(payload.c_str());

    if (deviceConnected) {
        pData->notify();
    }
}

bool ble_server_connected() { return deviceConnected; }
