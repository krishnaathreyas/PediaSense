#include "ble_server.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#include "../sensors/ppg.h"
#include "../sensors/imu.h"
#include "../sensors/temp.h"
#include "../sensors/mic.h"
#include "../processing/breathing.h"
#include "../processing/apnea.h"
#include "../processing/cry.h"
#include "../fusion/classifier.h"

// ── UUIDs ─────────────────────────────────────────────────────────────────────
#define SVC_UUID   "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define VITAL_UUID "bebe0001-1fb5-459e-8fcc-c5c9c331914b"
#define MOTN_UUID  "bebe0002-1fb5-459e-8fcc-c5c9c331914b"
#define AUDIO_UUID "bebe0003-1fb5-459e-8fcc-c5c9c331914b"
#define RISK_UUID  "bebe0004-1fb5-459e-8fcc-c5c9c331914b"

static BLEServer*         pServer  = nullptr;
static BLECharacteristic* pVital   = nullptr;
static BLECharacteristic* pMotion  = nullptr;
static BLECharacteristic* pAudio   = nullptr;
static BLECharacteristic* pRisk    = nullptr;

static bool deviceConnected    = false;
static bool prevConnected      = false;

// ── Connection callbacks ──────────────────────────────────────────────────────
class ConnCB : public BLEServerCallbacks {
    void onConnect(BLEServer*) override    { deviceConnected = true;  }
    void onDisconnect(BLEServer*) override { deviceConnected = false; }
};

// ── Previous packet storage (notify only on change) ──────────────────────────
static uint8_t prev_vital[4]  = {0xFF, 0xFF, 0xFF, 0xFF};
static uint8_t prev_motn[4]   = {0xFF, 0xFF, 0xFF, 0xFF};
static uint8_t prev_audio[4]  = {0xFF, 0xFF, 0xFF, 0xFF};
static uint8_t prev_risk[4]   = {0xFF, 0xFF, 0xFF, 0xFF};

static BLECharacteristic* make_char(BLEService* svc, const char* uuid) {
    auto* ch = svc->createCharacteristic(
        uuid,
        BLECharacteristic::PROPERTY_READ |
        BLECharacteristic::PROPERTY_NOTIFY
    );
    ch->addDescriptor(new BLE2902());
    return ch;
}

void ble_server_init(const char* device_name) {
    BLEDevice::init(device_name);
    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new ConnCB());

    BLEService* svc = pServer->createService(SVC_UUID);
    pVital  = make_char(svc, VITAL_UUID);
    pMotion = make_char(svc, MOTN_UUID);
    pAudio  = make_char(svc, AUDIO_UUID);
    pRisk   = make_char(svc, RISK_UUID);

    svc->start();

    BLEAdvertising* adv = BLEDevice::getAdvertising();
    adv->addServiceUUID(SVC_UUID);
    adv->setScanResponse(true);
    adv->setMinPreferred(0x06);   // helps with iOS connections
    adv->setMinPreferred(0x12);
    BLEDevice::startAdvertising();

    Serial.println("[BLE] advertising as \"" + String(device_name) + "\"");
}

static void notify_if_changed(BLECharacteristic* ch,
                               uint8_t* buf, uint8_t* prev, size_t len) {
    if (memcmp(buf, prev, len) == 0) return;
    memcpy(prev, buf, len);
    ch->setValue(buf, len);
    ch->notify();
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

    if (!deviceConnected) return;

    // ── VitalSigns ────────────────────────────────────────────────────────────
    {
        const PpgData&  p = ppg_get();
        const TempData& t = temp_get();
        int16_t skin100   = (int16_t)(t.skin_c * 100.0f);
        uint8_t buf[4] = {
            (uint8_t)(p.hr_valid   ? (uint8_t)p.hr   : 0),
            (uint8_t)(p.spo2_valid ? (uint8_t)p.spo2 : 0),
            (uint8_t)(skin100 & 0xFF),
            (uint8_t)((skin100 >> 8) & 0xFF)
        };
        notify_if_changed(pVital, buf, prev_vital, 4);
    }

    // ── Motion ────────────────────────────────────────────────────────────────
    {
        const ImuData&   m = imu_get();
        const BreathData& b = breathing_get();
        uint16_t amag = (uint16_t)min(65535.0f, m.accel_mag * 1000.0f);
        bool moving   = (m.motion_delta > 0.12f);
        uint8_t buf[4] = {
            (uint8_t)(amag & 0xFF),
            (uint8_t)((amag >> 8) & 0xFF),
            (uint8_t)(b.valid ? (uint8_t)b.rate_bpm : 0),
            (uint8_t)(moving ? 1 : 0)
        };
        notify_if_changed(pMotion, buf, prev_motn, 4);
    }

    // ── Audio ─────────────────────────────────────────────────────────────────
    {
        const CryData& c  = cry_get();
        const MicData& md = mic_get();
        uint16_t rms16    = (uint16_t)min(65535.0f, md.rms);
        uint8_t buf[4] = {
            (uint8_t)(c.crying ? 1 : 0),
            c.strength,
            (uint8_t)(rms16 & 0xFF),
            (uint8_t)((rms16 >> 8) & 0xFF)
        };
        notify_if_changed(pAudio, buf, prev_audio, 4);
    }

    // ── RiskAlert ─────────────────────────────────────────────────────────────
    {
        const ClassifierData& cls = classifier_get();
        uint8_t buf[4] = {
            (uint8_t)cls.level,
            cls.respiratory_score,
            cls.hydration_score,
            cls.flags
        };
        notify_if_changed(pRisk, buf, prev_risk, 4);
    }
}

bool ble_server_connected() { return deviceConnected; }
