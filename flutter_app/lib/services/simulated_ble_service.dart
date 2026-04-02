import 'dart:async';
import 'dart:math';

import '../models/vitals_data.dart';

/// Simulated BLE service that generates realistic neonatal vitals for
/// emulator / development use. Drop-in replacement for EspBleService.
class SimulatedBleService {
  final _vitalsController = StreamController<VitalsData>.broadcast();
  final _connectedController = StreamController<bool>.broadcast();

  Stream<VitalsData> get vitalsStream => _vitalsController.stream;
  Stream<bool> get connectedStream => _connectedController.stream;

  Timer? _publishTimer;
  final _rng = Random();

  // ── Baseline vitals (healthy neonate)
  static const double _baseHR = 120;
  static const double _baseSpo2 = 97;
  static const double _baseBreathing = 32;
  static const double _baseTemp = 36.8;

  // ── State
  int _tick = 0;
  bool _inAnomalyEpisode = false;
  int _anomalyTicksLeft = 0;
  String _anomalyType = '';

  Future<void> start() async {
    // Simulate a connection delay
    await Future.delayed(const Duration(milliseconds: 1500));
    _connectedController.add(true);

    _publishTimer?.cancel();
    _tick = 0;
    _publishTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _tick++;
      _generateAndPublish();
    });

    // Publish immediately
    _generateAndPublish();
  }

  void _generateAndPublish() {
    // ── Check if we should trigger an anomaly episode (~every 30 ticks = 60s)
    if (!_inAnomalyEpisode && _tick > 10 && _tick % 30 == 0) {
      _inAnomalyEpisode = true;
      _anomalyTicksLeft = 5 + _rng.nextInt(3); // 10-16 seconds
      _anomalyType = ['tachycardia', 'desaturation', 'tachypnea', 'fever'][
          _rng.nextInt(4)];
    }

    if (_inAnomalyEpisode) {
      _anomalyTicksLeft--;
      if (_anomalyTicksLeft <= 0) {
        _inAnomalyEpisode = false;
      }
    }

    // ── Generate vitals with sinusoidal drift + noise
    final t = _tick.toDouble();
    double hr = _baseHR + 8 * sin(t * 0.15) + _noise(3);
    double spo2 = _baseSpo2 + 1.5 * sin(t * 0.08) + _noise(0.5);
    double breathing = _baseBreathing + 4 * sin(t * 0.12) + _noise(2);
    double temp = _baseTemp + 0.3 * sin(t * 0.05) + _noise(0.1);

    // ── Apply anomaly modifiers
    if (_inAnomalyEpisode) {
      switch (_anomalyType) {
        case 'tachycardia':
          hr += 25 + _noise(5); // push HR to ~145-155
          break;
        case 'desaturation':
          spo2 -= 6 + _noise(1); // push SpO2 to ~90-92
          break;
        case 'tachypnea':
          breathing += 18 + _noise(3); // push to ~50-55
          break;
        case 'fever':
          temp += 1.5 + _noise(0.2); // push to ~38.3-38.5
          break;
      }
    }

    // ── Clamp to physiological limits
    hr = hr.clamp(60, 200);
    spo2 = spo2.clamp(80, 100);
    breathing = breathing.clamp(10, 80);
    temp = temp.clamp(34, 42);

    // ── Determine risk level
    RiskLevel risk = _evaluateRisk(hr, spo2, breathing, temp);

    final vitals = VitalsData(
      heartRate: hr,
      spo2: spo2,
      breathingRate: breathing,
      skinTemp: temp,
      urineGap: 2.0 + 0.5 * sin(t * 0.02) + _noise(0.3),
      wetDiaperCount: 6 + (_tick ~/ 60), // slowly increases over session
      riskLevel: risk,
    );

    _vitalsController.add(vitals);
  }

  RiskLevel _evaluateRisk(
      double hr, double spo2, double breathing, double temp) {
    // RED — any single critical value
    if (spo2 < 90 || hr > 160 || hr < 80 || breathing > 60 || temp > 38.5) {
      return RiskLevel.urgent;
    }
    // AMBER — borderline values
    if (spo2 < 94 ||
        hr > 140 ||
        hr < 90 ||
        breathing > 50 ||
        temp > 38.0 ||
        temp < 36.0) {
      return RiskLevel.monitor;
    }
    return RiskLevel.normal;
  }

  double _noise(double amplitude) {
    return ((_rng.nextDouble() * 2) - 1) * amplitude;
  }

  Future<void> stop() async {
    _publishTimer?.cancel();
    _publishTimer = null;
    _connectedController.add(false);
  }

  Future<void> dispose() async {
    await stop();
    await _vitalsController.close();
    await _connectedController.close();
  }
}
