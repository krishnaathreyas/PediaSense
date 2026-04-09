/**
 * ═══════════════════════════════════════════════════════════════════
 *  PediaSense — ALL SENSORS DEMO
 * ═══════════════════════════════════════════════════════════════════
 *  Reads all 4 sensors and prints to Serial every second.
 *  No BLE, no processing — just raw readings to show your guide.
 *
 *  Sensors:
 *    MAX30102  — PPG (HR / SpO2 / IR)     I2C  0x57
 *    MPU6050   — IMU (accel + gyro)        I2C  0x68
 *    MLX90614  — Skin + ambient temp       I2C  0x5A
 *    INMP441   — MEMS microphone           I2S  GPIO14/15/32
 *
 *  Pins:
 *    I2C  SDA=21  SCL=22
 *    I2S  SCK=14  WS=15  SD=32
 * ═══════════════════════════════════════════════════════════════════
 */

#include <Arduino.h>
#include <Wire.h>
#include <driver/i2s.h>

// ── SparkFun MAX30105 (works with MAX30102) ────────────────────
#include <MAX30105.h>
#include <spo2_algorithm.h>

// ═══════════════════════════════════════════════════════════════════
//  GLOBALS
// ═══════════════════════════════════════════════════════════════════

MAX30105 ppgSensor;
static bool mlxFound = false;  // skip MLX reads if not on bus

// ── MPU6050 raw-register addresses ─────────────────────────────
#define MPU_ADDR      0x68
#define MPU_PWR_MGMT  0x6B
#define MPU_ACCEL_CFG 0x1C
#define MPU_GYRO_CFG  0x1B
#define MPU_ACCEL_OUT 0x3B  // 14 bytes: accel(6) + temp(2) + gyro(6)

// ── MLX90614 ───────────────────────────────────────────────────
#define MLX_ADDR   0x5A
#define MLX_TOBJ1  0x07
#define MLX_TAMB   0x06

// ── I2S pins ───────────────────────────────────────────────────
#define I2S_SCK  14
#define I2S_WS   15
#define I2S_SD   32

// ── HR / SpO2 state ────────────────────────────────────────────
static float avgHR     = 0;
static float avgSpO2   = 0;
static bool  hrValid   = false;
static bool  spo2Valid = false;
static bool  firstRun  = true;

// Effective sample rate: sampleRate(100) / sampleAvg(8) = 12.5 Hz
#define EFF_SAMPLE_RATE 12.5f
#define SPO2_SAMPLES  100   // 100 samples at 12.5Hz = 8 seconds window
#define NEW_SAMPLES    12   // slide by 12 = ~1 second
uint32_t irBuffer[SPO2_SAMPLES];
uint32_t redBuffer[SPO2_SAMPLES];

// Peak detection on buffer to count heart beats
float detect_hr_from_buffer(uint32_t* ir, int len, float sampleRate) {
    // 1. Remove DC with simple moving average (low-pass subtraction)
    float mean = 0;
    for (int i = 0; i < len; i++) mean += ir[i];
    mean /= len;

    // AC signal: subtract DC
    float ac[100];
    float maxAC = 0, minAC = 0;
    for (int i = 0; i < len; i++) {
        ac[i] = (float)ir[i] - mean;
        if (ac[i] > maxAC) maxAC = ac[i];
        if (ac[i] < minAC) minAC = ac[i];
    }
    float amplitude = maxAC - minAC;
    if (amplitude < 100) return -1;  // signal too weak

    // 2. Threshold at 60% of max AC (pick only real pulse peaks)
    float threshold = maxAC * 0.6f;

    // 3. Find peaks (local maxima above threshold)
    //    Min distance 0.4s between peaks → max ~150bpm
    int minDist = (int)(sampleRate * 0.4f);
    int peaks[20];
    int peakCount = 0;
    for (int i = 3; i < len - 3 && peakCount < 20; i++) {
        if (ac[i] > threshold &&
            ac[i] >= ac[i-1] && ac[i] >= ac[i-2] && ac[i] >= ac[i-3] &&
            ac[i] >= ac[i+1] && ac[i] >= ac[i+2] && ac[i] >= ac[i+3]) {
            if (peakCount == 0 || (i - peaks[peakCount-1]) >= minDist) {
                peaks[peakCount++] = i;
            }
        }
    }

    // 4. Calculate HR from peak-to-peak intervals
    if (peakCount < 2) return -1;
    float totalInterval = (float)(peaks[peakCount-1] - peaks[0]) / sampleRate;
    float bpm = 60.0f * (peakCount - 1) / totalInterval;
    return (bpm >= 40 && bpm <= 150) ? bpm : -1;
}

// ═══════════════════════════════════════════════════════════════════
//  HELPERS
// ═══════════════════════════════════════════════════════════════════

// --- I2C scan (quick) ---
void i2c_scan() {
    Serial.println("\n=== I2C Bus Scan ===");
    int found = 0;
    for (uint8_t a = 1; a < 127; a++) {
        Wire.beginTransmission(a);
        if (Wire.endTransmission() == 0) {
            Serial.printf("  0x%02X  ", a);
            found++;
        }
    }
    Serial.printf("\n  %d device(s) found\n", found);
}

// --- MLX90614 raw SMBus read ---
float mlx_read(uint8_t reg) {
    Wire.setClock(100000);
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
    uint16_t raw = Wire.read();
    raw |= (uint16_t)Wire.read() << 8;
    Wire.read(); // PEC
    Wire.setClock(400000);
    return raw * 0.02f - 273.15f;
}

// ═══════════════════════════════════════════════════════════════════
//  SETUP
// ═══════════════════════════════════════════════════════════════════
void setup() {
    Serial.begin(115200);
    delay(500);
    Serial.println("\n╔═══════════════════════════════════════════╗");
    Serial.println("║   PediaSense — ALL SENSORS DEMO           ║");
    Serial.println("╚═══════════════════════════════════════════╝");

    Wire.begin(21, 22);
    Wire.setClock(400000);
    i2c_scan();

    // ── 1. MAX30102 (PPG) ──────────────────────────────────────
    Serial.print("[PPG]  MAX30102 init... ");
    if (ppgSensor.begin(Wire, I2C_SPEED_FAST)) {
        // sampleAvg=8, LEDmode=2(Red+IR), sampleRate=100, pulseWidth=411, adcRange=4096
        ppgSensor.setup(60, 8, 2, 100, 411, 4096);
        // Don't override LED power — setup() already set both to 60
        Serial.println("OK");
    } else {
        Serial.println("FAIL — check wiring to 0x57");
    }

    // ── 2. MPU6050 (IMU) ──────────────────────────────────────
    Serial.print("[IMU]  MPU6050 init... ");
    Wire.beginTransmission(MPU_ADDR);
    Wire.write(MPU_PWR_MGMT);
    Wire.write(0x00);  // wake up
    if (Wire.endTransmission() == 0) {
        // ±4g
        Wire.beginTransmission(MPU_ADDR);
        Wire.write(MPU_ACCEL_CFG);
        Wire.write(0x08);
        Wire.endTransmission();
        // ±500°/s
        Wire.beginTransmission(MPU_ADDR);
        Wire.write(MPU_GYRO_CFG);
        Wire.write(0x08);
        Wire.endTransmission();
        Serial.println("OK");
    } else {
        Serial.println("FAIL — check wiring to 0x68");
    }

    // ── 3. MLX90614 (Temp) ────────────────────────────────────
    Serial.print("[TEMP] MLX90614 init... ");
    // Check if 0x5A is on the bus first
    Wire.beginTransmission(MLX_ADDR);
    if (Wire.endTransmission() == 0) {
        mlxFound = true;
        float t = mlx_read(MLX_TOBJ1);
        Serial.printf("OK (skin=%.1f\u00b0C)\n", t);
    } else {
        mlxFound = false;
        Serial.println("NOT FOUND \u2014 skipping (0x5A not on bus)");
    }

    // ── 4. INMP441 (Mic) ──────────────────────────────────────
    Serial.print("[MIC]  INMP441 init... ");
    i2s_config_t i2s_cfg = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
        .sample_rate = 16000,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
        .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 4,
        .dma_buf_len = 512,
        .use_apll = false,
        .tx_desc_auto_clear = false,
        .fixed_mclk = 0
    };
    i2s_pin_config_t pin_cfg = {
        .bck_io_num   = I2S_SCK,
        .ws_io_num    = I2S_WS,
        .data_out_num = I2S_PIN_NO_CHANGE,
        .data_in_num  = I2S_SD
    };
    if (i2s_driver_install(I2S_NUM_0, &i2s_cfg, 0, NULL) == ESP_OK &&
        i2s_set_pin(I2S_NUM_0, &pin_cfg) == ESP_OK) {
        Serial.println("OK");
    } else {
        Serial.println("FAIL");
    }

    Serial.println("\n── Readings every 1 second ──────────────────\n");
}

// ═══════════════════════════════════════════════════════════════════
//  LOOP
// ═══════════════════════════════════════════════════════════════════
void loop() {
    // ── 1. PPG (MAX30102) — sliding window for HR + SpO2 ──
    if (firstRun) {
        for (int i = 0; i < SPO2_SAMPLES; i++) {
            while (!ppgSensor.available()) ppgSensor.check();
            redBuffer[i] = ppgSensor.getRed();
            irBuffer[i]  = ppgSensor.getIR();
            ppgSensor.nextSample();
        }
        firstRun = false;
    } else {
        // Shift old data left, collect NEW_SAMPLES fresh
        for (int i = 0; i < SPO2_SAMPLES - NEW_SAMPLES; i++) {
            redBuffer[i] = redBuffer[i + NEW_SAMPLES];
            irBuffer[i]  = irBuffer[i + NEW_SAMPLES];
        }
        for (int i = SPO2_SAMPLES - NEW_SAMPLES; i < SPO2_SAMPLES; i++) {
            while (!ppgSensor.available()) ppgSensor.check();
            redBuffer[i] = ppgSensor.getRed();
            irBuffer[i]  = ppgSensor.getIR();
            ppgSensor.nextSample();
        }
    }

    long irValue = irBuffer[SPO2_SAMPLES - 1];
    bool finger = (irValue > 50000);

    if (finger) {
        // HR from peak detection on IR buffer
        float bpm = detect_hr_from_buffer(irBuffer, SPO2_SAMPLES, EFF_SAMPLE_RATE);
        if (bpm > 0) {
            if (!hrValid) avgHR = bpm;
            else          avgHR = avgHR * 0.5f + bpm * 0.5f;
            hrValid = true;
        }

        // SpO2 from Maxim algorithm
        int32_t spo2Val, hrVal;
        int8_t  spo2Ok, hrOk;
        maxim_heart_rate_and_oxygen_saturation(
            irBuffer, SPO2_SAMPLES, redBuffer,
            &spo2Val, &spo2Ok, &hrVal, &hrOk);
        if (spo2Ok && spo2Val >= 70 && spo2Val <= 100) {
            if (!spo2Valid) avgSpO2 = spo2Val;
            else           avgSpO2 = avgSpO2 * 0.6f + spo2Val * 0.4f;
            spo2Valid = true;
        }
    } else {
        hrValid = false; spo2Valid = false; firstRun = true;
    }

    // ── 2. MPU6050 — burst read ────────────────────────────────
    float ax = 0, ay = 0, az = 0, gx = 0, gy = 0, gz = 0;
    Wire.beginTransmission(MPU_ADDR);
    Wire.write(MPU_ACCEL_OUT);
    Wire.endTransmission(false);
    Wire.requestFrom((uint8_t)MPU_ADDR, (uint8_t)14, (uint8_t)true);
    if (Wire.available() >= 14) {
        int16_t raw_ax = (Wire.read() << 8) | Wire.read();
        int16_t raw_ay = (Wire.read() << 8) | Wire.read();
        int16_t raw_az = (Wire.read() << 8) | Wire.read();
        Wire.read(); Wire.read(); // skip temp
        int16_t raw_gx = (Wire.read() << 8) | Wire.read();
        int16_t raw_gy = (Wire.read() << 8) | Wire.read();
        int16_t raw_gz = (Wire.read() << 8) | Wire.read();
        ax = raw_ax / 8192.0f * 9.81f;
        ay = raw_ay / 8192.0f * 9.81f;
        az = raw_az / 8192.0f * 9.81f;
        gx = raw_gx / 65.5f;
        gy = raw_gy / 65.5f;
        gz = raw_gz / 65.5f;
    }
    float accel_mag = sqrtf(ax*ax + ay*ay + az*az);

    // ── 3. MLX90614 — skin + ambient (only if detected) ────
    float skin = -999.0f, amb = -999.0f;
    if (mlxFound) {
        skin = mlx_read(MLX_TOBJ1);
        amb  = mlx_read(MLX_TAMB);
    }

    // ── 4. INMP441 — one DMA buffer ───────────────────────────
    int32_t mic_buf[512];
    size_t bytesRead = 0;
    i2s_read(I2S_NUM_0, mic_buf, sizeof(mic_buf), &bytesRead, 100 / portTICK_PERIOD_MS);
    int samples = bytesRead / 4; // interleaved L,R
    float mic_rms = 0;
    int32_t mic_peak = 0;
    int monoSamples = 0;
    for (int i = 0; i + 1 < samples; i += 2) {
        int32_t left  = mic_buf[i] >> 8;
        int32_t right = mic_buf[i + 1] >> 8;
        int32_t aL    = left < 0 ? -left : left;
        int32_t aR    = right < 0 ? -right : right;
        int32_t v     = (aL >= aR) ? left : right;
        float fv = (float)v;
        mic_rms += fv * fv;
        int32_t a = v < 0 ? -v : v;
        if (a > mic_peak) mic_peak = a;
        monoSamples++;
    }
    mic_rms = (monoSamples > 0) ? sqrtf(mic_rms / monoSamples) : 0;

    // ── PRINT ──────────────────────────────────────────────────
    Serial.println("──────────────────────────────────────────────");
    Serial.printf("PPG  │ IR=%ld  finger=%s\n",
                  irValue, finger ? "YES" : "NO");
    if (finger) {
        Serial.printf("     │ HR=%.0f bpm (%s)  SpO2=%.0f%% (%s)\n",
                      avgHR, hrValid ? "OK" : "wait...",
                      avgSpO2, spo2Valid ? "OK" : "wait...");
    } else {
        Serial.println("     │ Place finger on sensor for HR & SpO2");
    }
    Serial.printf("IMU  │ ax=%.2f ay=%.2f az=%.2f m/s²  mag=%.2f\n",
                  ax, ay, az, accel_mag);
    Serial.printf("     │ gx=%.1f gy=%.1f gz=%.1f °/s\n", gx, gy, gz);
    Serial.printf("TEMP │ skin=%.1f°C  ambient=%.1f°C  %s\n",
                  skin, amb, (skin > -200) ? "OK" : "FAIL");
    Serial.printf("MIC  │ RMS=%.0f  peak=%ld  samples=%d  %s\n",
                  mic_rms, (long)mic_peak, monoSamples,
                  (mic_peak > 0) ? "OK" : "NO DATA");
    Serial.println();
    // 100 samples at 100Hz ≈ 1 sec, no extra delay needed
}
