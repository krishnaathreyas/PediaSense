#include <Arduino.h>
#include <Wire.h>
#include "MAX30105.h"
#include "heartRate.h"
#include "spo2_algorithm.h"

MAX30105 particleSensor;

// Buffers for SpO2 algorithm
const byte BUFFER_SIZE = 100;
uint32_t irBuffer[BUFFER_SIZE];
uint32_t redBuffer[BUFFER_SIZE];

int32_t spo2;
int8_t  validSPO2;
int32_t heartRate;
int8_t  validHeartRate;

void setup() {
  Serial.begin(115200);
  Serial.println("MAX30102 - Pulse Oximeter & Heart Rate");

  // Initialize I2C on ESP32 default pins: SDA=21, SCL=22
  Wire.begin(21, 22);

  if (!particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("MAX30102 not found. Check wiring/power.");
    while (true); // halt
  }

  // Configure sensor
  byte ledBrightness = 60;  // 0-255. 60 = ~18mA (good starting point)
  byte sampleAverage = 4;   // 1, 2, 4, 8, 16, 32
  byte ledMode       = 2;   // 1 = Red only, 2 = Red + IR (SpO2 mode)
  int  sampleRate    = 100; // samples per second
  int  pulseWidth    = 411; // microseconds
  int  adcRange      = 4096;

  particleSensor.setup(ledBrightness, sampleAverage, ledMode,
                       sampleRate, pulseWidth, adcRange);

  Serial.println("Sensor ready. Place finger on sensor.");
}

void loop() {
  // Collect 100 samples into buffers
  for (byte i = 0; i < BUFFER_SIZE; i++) {
    while (!particleSensor.available()) {
      particleSensor.check();
    }
    redBuffer[i] = particleSensor.getRed();
    irBuffer[i]  = particleSensor.getIR();
    particleSensor.nextSample();
  }

  // Calculate heart rate and SpO2
  maxim_heart_rate_and_oxygen_saturation(
    irBuffer, BUFFER_SIZE, redBuffer,
    &spo2, &validSPO2, &heartRate, &validHeartRate
  );

  // Print results
  Serial.print("Heart Rate: ");
  if (validHeartRate) {
    Serial.print(heartRate);
    Serial.print(" bpm");
  } else {
    Serial.print("Invalid");
  }

  Serial.print("  |  SpO2: ");
  if (validSPO2) {
    Serial.print(spo2);
    Serial.print(" %");
  } else {
    Serial.print("Invalid");
  }

  Serial.println();
}