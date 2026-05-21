import '../models/vitals_data.dart';

// ═══════════════════════════════════════════════════════════════════════════════
//  Neonatal Clinical Threshold Engine
// ═══════════════════════════════════════════════════════════════════════════════
//
//  Evaluates live vitals against WHO/IAP neonatal reference ranges.
//  Produces an overall risk level (GREEN / AMBER / RED) and per-vital
//  alerts with human-readable clinical messages.
//
//  Rule: ANY RED → overall RED.  Otherwise ANY AMBER → overall AMBER.
//         Else GREEN.
// ═══════════════════════════════════════════════════════════════════════════════

/// Risk severity level.
enum RiskLevel { green, amber, red }

/// A single vital's evaluation result.
class VitalAlert {
  final String vital;        // e.g. "Heart Rate"
  final RiskLevel level;
  final String message;      // clinical message
  final String shortLabel;   // e.g. "Tachycardia"

  const VitalAlert({
    required this.vital,
    required this.level,
    required this.message,
    required this.shortLabel,
  });
}

/// Full evaluation result for a set of vitals.
class VitalEvaluation {
  final RiskLevel overallLevel;
  final List<VitalAlert> alerts;
  final String overallMessage;

  const VitalEvaluation({
    required this.overallLevel,
    required this.alerts,
    required this.overallMessage,
  });

  /// Only RED and AMBER alerts.
  List<VitalAlert> get activeAlerts =>
      alerts.where((a) => a.level != RiskLevel.green).toList();

  /// True if there are any non-green alerts.
  bool get hasAlerts => activeAlerts.isNotEmpty;
}

// ─── Threshold Engine ────────────────────────────────────────────────────────

class VitalStatusEvaluator {
  const VitalStatusEvaluator._();
  static const VitalStatusEvaluator instance = VitalStatusEvaluator._();

  // ── Configurable thresholds ────────────────────────────────────────────

  // Heart Rate (bpm)
  static const double hrGreenLow   = 100;
  static const double hrGreenHigh  = 160;
  static const double hrAmberLow   = 80;
  static const double hrAmberHigh  = 180;
  // Below hrAmberLow or above hrAmberHigh → RED

  // SpO₂ (%)
  static const double spo2GreenLow = 95;
  static const double spo2AmberLow = 90;
  // Below spo2AmberLow → RED

  // Breathing Rate (breaths/min)
  static const double brGreenLow   = 30;
  static const double brGreenHigh  = 60;
  static const double brAmberLow   = 20;
  static const double brAmberHigh  = 70;
  // Below brAmberLow or above brAmberHigh → RED

  // Skin Temperature (°C)
  static const double tempGreenLow  = 36.5;
  static const double tempGreenHigh = 37.5;
  static const double tempAmberLow  = 36.0;
  static const double tempAmberHigh = 38.0;
  // Below tempAmberLow or above tempAmberHigh → RED

  // ── Evaluate all vitals ────────────────────────────────────────────────

  VitalEvaluation evaluate(VitalsData vitals) {
    final alerts = <VitalAlert>[
      _evaluateHr(vitals.hr),
      _evaluateSpo2(vitals.spo2),
      _evaluateBr(vitals.br),
      _evaluateTemp(vitals.skinTemp),
    ];

    // Overall: worst-case wins
    RiskLevel overall = RiskLevel.green;
    for (final a in alerts) {
      if (a.level == RiskLevel.red) {
        overall = RiskLevel.red;
        break;
      }
      if (a.level == RiskLevel.amber) {
        overall = RiskLevel.amber;
      }
    }

    final overallMsg = switch (overall) {
      RiskLevel.green => 'All vitals within normal range',
      RiskLevel.amber => 'Caution — some vitals need monitoring',
      RiskLevel.red   => 'Critical — immediate attention required',
    };

    return VitalEvaluation(
      overallLevel: overall,
      alerts: alerts,
      overallMessage: overallMsg,
    );
  }

  // ── Per-vital evaluators ───────────────────────────────────────────────

  VitalAlert _evaluateHr(int hr) {
    if (hr < hrAmberLow) {
      return VitalAlert(
        vital: 'Heart Rate',
        level: RiskLevel.red,
        message: 'Severe bradycardia detected ($hr bpm). '
            'Normal neonatal range: ${hrGreenLow.round()}–${hrGreenHigh.round()} bpm.',
        shortLabel: 'Bradycardia',
      );
    }
    if (hr > hrAmberHigh) {
      return VitalAlert(
        vital: 'Heart Rate',
        level: RiskLevel.red,
        message: 'Severe tachycardia detected ($hr bpm). '
            'Normal neonatal range: ${hrGreenLow.round()}–${hrGreenHigh.round()} bpm.',
        shortLabel: 'Tachycardia',
      );
    }
    if (hr < hrGreenLow) {
      return VitalAlert(
        vital: 'Heart Rate',
        level: RiskLevel.amber,
        message: 'Mildly low heart rate ($hr bpm). Monitor closely.',
        shortLabel: 'Low HR',
      );
    }
    if (hr > hrGreenHigh) {
      return VitalAlert(
        vital: 'Heart Rate',
        level: RiskLevel.amber,
        message: 'Mildly elevated heart rate ($hr bpm). Monitor closely.',
        shortLabel: 'Elevated HR',
      );
    }
    return VitalAlert(
      vital: 'Heart Rate',
      level: RiskLevel.green,
      message: 'Heart rate normal ($hr bpm).',
      shortLabel: 'Normal',
    );
  }

  VitalAlert _evaluateSpo2(int spo2) {
    if (spo2 < spo2AmberLow) {
      return VitalAlert(
        vital: 'SpO₂',
        level: RiskLevel.red,
        message: 'Dangerously low oxygen saturation ($spo2%). '
            'Possible hypoxemia. Seek immediate medical attention.',
        shortLabel: 'Hypoxemia',
      );
    }
    if (spo2 < spo2GreenLow) {
      return VitalAlert(
        vital: 'SpO₂',
        level: RiskLevel.amber,
        message: 'Mildly low oxygen saturation ($spo2%). '
            'Monitor breathing pattern.',
        shortLabel: 'Low SpO₂',
      );
    }
    return VitalAlert(
      vital: 'SpO₂',
      level: RiskLevel.green,
      message: 'Oxygen saturation normal ($spo2%).',
      shortLabel: 'Normal',
    );
  }

  VitalAlert _evaluateBr(int br) {
    if (br < brAmberLow) {
      return VitalAlert(
        vital: 'Breathing Rate',
        level: RiskLevel.red,
        message: 'Dangerously low breathing rate ($br breaths/min). '
            'Possible respiratory depression.',
        shortLabel: 'Bradypnea',
      );
    }
    if (br > brAmberHigh) {
      return VitalAlert(
        vital: 'Breathing Rate',
        level: RiskLevel.red,
        message: 'Dangerously high breathing rate ($br breaths/min). '
            'Possible respiratory distress.',
        shortLabel: 'Tachypnea',
      );
    }
    if (br < brGreenLow) {
      return VitalAlert(
        vital: 'Breathing Rate',
        level: RiskLevel.amber,
        message: 'Slightly low breathing rate ($br breaths/min). Monitor closely.',
        shortLabel: 'Low BR',
      );
    }
    if (br > brGreenHigh) {
      return VitalAlert(
        vital: 'Breathing Rate',
        level: RiskLevel.amber,
        message: 'Slightly elevated breathing rate ($br breaths/min). '
            'Monitor closely.',
        shortLabel: 'Elevated BR',
      );
    }
    return VitalAlert(
      vital: 'Breathing Rate',
      level: RiskLevel.green,
      message: 'Breathing rate normal ($br breaths/min).',
      shortLabel: 'Normal',
    );
  }

  VitalAlert _evaluateTemp(double temp) {
    if (temp < tempAmberLow) {
      return VitalAlert(
        vital: 'Skin Temperature',
        level: RiskLevel.red,
        message: 'Hypothermia detected (${temp.toStringAsFixed(1)}°C). '
            'Warm the baby immediately.',
        shortLabel: 'Hypothermia',
      );
    }
    if (temp > tempAmberHigh) {
      return VitalAlert(
        vital: 'Skin Temperature',
        level: RiskLevel.red,
        message: 'Fever detected (${temp.toStringAsFixed(1)}°C). '
            'Seek medical attention.',
        shortLabel: 'Fever',
      );
    }
    if (temp < tempGreenLow) {
      return VitalAlert(
        vital: 'Skin Temperature',
        level: RiskLevel.amber,
        message: 'Slightly cool (${temp.toStringAsFixed(1)}°C). '
            'Ensure adequate warmth.',
        shortLabel: 'Cool',
      );
    }
    if (temp > tempGreenHigh) {
      return VitalAlert(
        vital: 'Skin Temperature',
        level: RiskLevel.amber,
        message: 'Slightly warm (${temp.toStringAsFixed(1)}°C). '
            'Monitor closely.',
        shortLabel: 'Warm',
      );
    }
    return VitalAlert(
      vital: 'Skin Temperature',
      level: RiskLevel.green,
      message: 'Temperature normal (${temp.toStringAsFixed(1)}°C).',
      shortLabel: 'Normal',
    );
  }

  /// Map RiskLevel to a RAG-compatible severity string.
  String riskToSeverity(RiskLevel level) => switch (level) {
    RiskLevel.green => 'normal',
    RiskLevel.amber => 'monitor',
    RiskLevel.red   => 'urgent',
  };
}
