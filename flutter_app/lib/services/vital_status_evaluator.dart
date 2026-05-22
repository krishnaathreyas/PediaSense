import 'dart:math' as math;

import '../models/care_log_summary.dart';
import '../models/vitals_data.dart';

// ═══════════════════════════════════════════════════════════════════════════════
//  Neonatal Health Evaluation Engine (IMNCI / IAP-Grounded)
// ═══════════════════════════════════════════════════════════════════════════════
//
//  Two-tier evaluation:
//
//  TIER 1 — IMNCI Danger Sign Detection
//    Any single danger sign → immediate RED.
//    Based on: WHO IMNCI Chart Booklet (Young Infant 0-2 months)
//    Source: nhm.gov.in/IMNCI, WHO IMCI guidelines
//
//  TIER 2 — Weighted Composite Score (modified Neonatal Early Warning Score)
//    Per-parameter scoring (0/1/2) weighted by clinical significance.
//    Integrates sensor vitals + care log data (diaper/feeding/symptoms).
//    Based on: NEWS adapted with IAP/IMNCI thresholds
//
//  Graceful degradation: when care logs are unavailable, the engine
//  operates on sensor vitals alone with redistributed weights.
//
//  DISCLAIMER: This is a caregiver decision-support tool, NOT a medical
//  device. It does not replace professional clinical judgment.
// ═══════════════════════════════════════════════════════════════════════════════

/// Risk severity level.
enum RiskLevel { green, amber, red }

/// A single vital's or care-log parameter's evaluation result.
class VitalAlert {
  final String vital;      // e.g. "Heart Rate", "Hydration", "Feeding"
  final RiskLevel level;
  final String message;    // clinical message
  final String shortLabel; // e.g. "Tachycardia", "Low Diapers"

  const VitalAlert({
    required this.vital,
    required this.level,
    required this.message,
    required this.shortLabel,
  });
}

/// Full evaluation result for a set of vitals + optional care logs.
class VitalEvaluation {
  final RiskLevel overallLevel;
  final List<VitalAlert> alerts;
  final String overallMessage;

  /// Normalized composite score (0.0 = fully normal, 1.0 = critical).
  /// Provides finer granularity than the 3-level classification.
  final double compositeScore;

  const VitalEvaluation({
    required this.overallLevel,
    required this.alerts,
    required this.overallMessage,
    required this.compositeScore,
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

  // ═══════════════════════════════════════════════════════════════════════════
  //  CLINICAL THRESHOLDS (WHO IMNCI / IAP Neonatology)
  // ═══════════════════════════════════════════════════════════════════════════

  // ── Heart Rate (bpm) — IAP Neonatology ──────────────────────────────────
  static const double hrGreenLow   = 100;
  static const double hrGreenHigh  = 160;
  static const double hrAmberLow   =  80;  // below → RED (severe bradycardia)
  static const double hrAmberHigh  = 180;  // above → RED (severe tachycardia)

  // ── SpO₂ (%) — IAP/WHO ─────────────────────────────────────────────────
  static const double spo2GreenLow =  95;
  static const double spo2AmberLow =  90;  // below → RED (hypoxemia)

  // ── Breathing Rate (breaths/min) — IMNCI ────────────────────────────────
  static const double brGreenLow   =  30;
  static const double brGreenHigh  =  60;
  static const double brAmberLow   =  20;  // below → RED (bradypnea)
  static const double brAmberHigh  =  70;  // above → RED (tachypnea)

  // ── Skin Temperature (°C) — IMNCI/IAP ──────────────────────────────────
  static const double tempGreenLow  = 36.5;
  static const double tempGreenHigh = 37.5;
  static const double tempAmberLow  = 36.0; // below → RED (hypothermia)
  static const double tempAmberHigh = 38.0; // above → RED (fever)

  // ── Hydration — WHO breastfeeding adequacy ──────────────────────────────
  static const int diaperGreenMin  = 6;    // ≥6 wet diapers/24h = adequate
  static const int diaperAmberMin  = 4;    // 4-5 = monitor
  // ≤3 → concerning (Tier 2 score 2)

  // ── Feeding — WHO exclusive BF / IAP ────────────────────────────────────
  static const int feedGreenMin    = 8;    // ≥8 feeds/24h = adequate
  static const int feedAmberMin    = 6;    // 6-7 = monitor
  // <6 → concerning

  static const double feedGapGreenMax = 3.0; // ≤3h between feeds = OK
  static const double feedGapAmberMax = 4.0; // 3-4h = monitor
  // >4h → concerning

  // Not feeding for >6h is an IMNCI danger sign (Tier 1 RED)
  static const double feedGapDangerHours = 6.0;

  // ═══════════════════════════════════════════════════════════════════════════
  //  COMPOSITE SCORE WEIGHTS
  // ═══════════════════════════════════════════════════════════════════════════
  //
  //  Based on IMNCI triage priority:
  //  Vitals (most acute, always available) > Hydration (dehydration assessment)
  //  > Feeding (IMNCI danger sign) > Symptoms (caregiver observations)

  static const double _wVitals   = 0.50;
  static const double _wHydration = 0.20;
  static const double _wFeeding  = 0.18;
  static const double _wSymptoms = 0.12;

  // AMBER threshold for composite score
  static const double _amberThreshold = 0.15;

  // ═══════════════════════════════════════════════════════════════════════════
  //  MAIN EVALUATE METHOD
  // ═══════════════════════════════════════════════════════════════════════════

  /// Evaluate all available data and produce a [VitalEvaluation].
  ///
  /// [vitals] — real-time sensor data (always required).
  /// [careLogSummary] — aggregated care log metrics (optional).
  ///   When null or empty, the engine operates on vitals alone.
  VitalEvaluation evaluate(
    VitalsData vitals, {
    CareLogSummary? careLogSummary,
  }) {
    final summary = careLogSummary;

    // ── TIER 1: IMNCI Danger Sign Detection ────────────────────────────
    final dangerAlerts = _checkDangerSigns(vitals, summary);
    if (dangerAlerts.isNotEmpty) {
      // Collect all per-vital alerts for full context
      final allAlerts = <VitalAlert>[
        ..._evaluateAllVitals(vitals),
        if (summary != null && summary.hasAnyLogs)
          ..._evaluateAllCareLogs(summary),
        ...dangerAlerts,
      ];
      // Deduplicate by vital name + level (keep danger sign version)
      final deduped = _deduplicateAlerts(allAlerts);

      return VitalEvaluation(
        overallLevel: RiskLevel.red,
        alerts: deduped,
        overallMessage: 'Critical — immediate attention required',
        compositeScore: 1.0,
      );
    }

    // ── TIER 2: Weighted Composite Score ────────────────────────────────
    final allAlerts = <VitalAlert>[
      ..._evaluateAllVitals(vitals),
      if (summary != null && summary.hasAnyLogs)
        ..._evaluateAllCareLogs(summary),
    ];

    final cs = _computeCompositeScore(vitals, summary);

    final overall = cs >= _amberThreshold ? RiskLevel.amber : RiskLevel.green;

    return VitalEvaluation(
      overallLevel: overall,
      alerts: allAlerts,
      overallMessage: switch (overall) {
        RiskLevel.green => 'All vitals within expected range',
        RiskLevel.amber => 'Caution — some parameters need monitoring',
        RiskLevel.red   => 'Critical — immediate attention required',
      },
      compositeScore: cs,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  TIER 1: IMNCI DANGER SIGN DETECTION
  // ═══════════════════════════════════════════════════════════════════════════
  //
  //  Each rule maps to an IMNCI "Possible Serious Bacterial Infection
  //  or Very Severe Disease" classification criterion.

  List<VitalAlert> _checkDangerSigns(
    VitalsData vitals,
    CareLogSummary? summary,
  ) {
    final dangers = <VitalAlert>[];

    // ── Rule 1: Severe bradycardia (HR < 80 bpm) ──────────────────────
    if (vitals.hr < hrAmberLow) {
      dangers.add(VitalAlert(
        vital: 'Heart Rate',
        level: RiskLevel.red,
        message: 'Severe bradycardia detected (${vitals.hr} bpm). '
            'Normal neonatal range: ${hrGreenLow.round()}–${hrGreenHigh.round()} bpm.',
        shortLabel: 'Bradycardia',
      ));
    }

    // ── Rule 2: Severe tachycardia (HR > 180 bpm) ─────────────────────
    if (vitals.hr > hrAmberHigh) {
      dangers.add(VitalAlert(
        vital: 'Heart Rate',
        level: RiskLevel.red,
        message: 'Severe tachycardia detected (${vitals.hr} bpm). '
            'Normal neonatal range: ${hrGreenLow.round()}–${hrGreenHigh.round()} bpm.',
        shortLabel: 'Tachycardia',
      ));
    }

    // ── Rule 3: Severe hypoxemia (SpO₂ < 90%) ────────────────────────
    if (vitals.spo2 < spo2AmberLow) {
      dangers.add(VitalAlert(
        vital: 'SpO₂',
        level: RiskLevel.red,
        message: 'Dangerously low oxygen saturation (${vitals.spo2}%). '
            'Possible hypoxemia. Seek immediate medical attention.',
        shortLabel: 'Hypoxemia',
      ));
    }

    // ── Rule 4: Severe respiratory depression (BR < 20/min) ───────────
    if (vitals.br < brAmberLow) {
      dangers.add(VitalAlert(
        vital: 'Breathing Rate',
        level: RiskLevel.red,
        message: 'Dangerously low breathing rate (${vitals.br} breaths/min). '
            'Possible respiratory depression.',
        shortLabel: 'Bradypnea',
      ));
    }

    // ── Rule 5: Tachypnea (BR > 70/min) ──────────────────────────────
    if (vitals.br > brAmberHigh) {
      dangers.add(VitalAlert(
        vital: 'Breathing Rate',
        level: RiskLevel.red,
        message: 'Dangerously high breathing rate (${vitals.br} breaths/min). '
            'Possible respiratory distress.',
        shortLabel: 'Tachypnea',
      ));
    }

    // ── Rule 6: Hypothermia (Temp < 36.0°C) ──────────────────────────
    if (vitals.skinTemp < tempAmberLow) {
      dangers.add(VitalAlert(
        vital: 'Skin Temperature',
        level: RiskLevel.red,
        message: 'Hypothermia detected (${vitals.skinTemp.toStringAsFixed(1)}°C). '
            'Warm the baby immediately.',
        shortLabel: 'Hypothermia',
      ));
    }

    // ── Rule 7: Fever (Temp > 38.0°C) ────────────────────────────────
    if (vitals.skinTemp > tempAmberHigh) {
      dangers.add(VitalAlert(
        vital: 'Skin Temperature',
        level: RiskLevel.red,
        message: 'Fever detected (${vitals.skinTemp.toStringAsFixed(1)}°C). '
            'Seek medical attention.',
        shortLabel: 'Fever',
      ));
    }

    // ── Care-log based danger signs (only when logs are available) ────
    if (summary != null && summary.hasAnyLogs) {
      // Rule 8: Not feeding — IMNCI danger sign
      // Only trigger when feeding logs are actively being used
      // (at least 1 feed logged today) and gap exceeds danger threshold
      if (summary.hasFeedingLogs &&
          summary.hoursSinceLastFeed != null &&
          summary.hoursSinceLastFeed! >= feedGapDangerHours) {
        dangers.add(VitalAlert(
          vital: 'Feeding',
          level: RiskLevel.red,
          message: 'No feeding recorded for ${summary.hoursSinceLastFeed!.toStringAsFixed(1)} hours. '
              'IMNCI: "Not able to feed" is a danger sign requiring urgent attention.',
          shortLabel: 'Not Feeding',
        ));
      }

      // Rule 9: Severe symptom logged — IMNCI danger sign
      if (summary.hasSymptomLogs &&
          summary.worstSymptomSeverity == 'severe') {
        dangers.add(VitalAlert(
          vital: 'Symptoms',
          level: RiskLevel.red,
          message: 'Severe symptom logged. '
              'IMNCI recommends urgent clinical assessment.',
          shortLabel: 'Severe Symptom',
        ));
      }

      // Rule 10: Diarrhea with dehydration signs
      // Watery stool + low wet diapers = dehydration risk per IMNCI
      if (summary.hasDiaperLogs &&
          summary.hasWateryStool &&
          summary.wetDiaperCount < diaperAmberMin) {
        dangers.add(VitalAlert(
          vital: 'Hydration',
          level: RiskLevel.red,
          message: 'Diarrhea with possible dehydration — '
              'watery stool with only ${summary.wetDiaperCount} wet diapers today. '
              'IMNCI: Assess for dehydration immediately.',
          shortLabel: 'Dehydration Risk',
        ));
      }
    }

    // ── Rule 11: Multi-vital escalation (PEWS principle) ──────────────
    // ≥3 vitals in AMBER zone simultaneously → escalate to RED
    if (dangers.isEmpty) {
      int amberCount = 0;
      if (_vitalScore(vitals.hr.toDouble(), hrGreenLow, hrGreenHigh,
              hrAmberLow, hrAmberHigh) >= 1) amberCount++;
      if (_spo2Score(vitals.spo2.toDouble()) >= 1) amberCount++;
      if (_vitalScore(vitals.br.toDouble(), brGreenLow, brGreenHigh,
              brAmberLow, brAmberHigh) >= 1) amberCount++;
      if (_tempScore(vitals.skinTemp) >= 1) amberCount++;

      if (amberCount >= 3) {
        dangers.add(VitalAlert(
          vital: 'Multi-Vital',
          level: RiskLevel.red,
          message: '$amberCount vitals outside normal range simultaneously. '
              'Combined abnormality warrants urgent assessment.',
          shortLabel: 'Multiple Abnormal',
        ));
      }
    }

    return dangers;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  TIER 2: WEIGHTED COMPOSITE SCORE
  // ═══════════════════════════════════════════════════════════════════════════

  double _computeCompositeScore(
    VitalsData vitals,
    CareLogSummary? summary,
  ) {
    // ── Vitals channel (always available) ─────────────────────────────
    final hrScore   = _vitalScore(vitals.hr.toDouble(),
        hrGreenLow, hrGreenHigh, hrAmberLow, hrAmberHigh);
    final spo2Score = _spo2Score(vitals.spo2.toDouble());
    final brScore   = _vitalScore(vitals.br.toDouble(),
        brGreenLow, brGreenHigh, brAmberLow, brAmberHigh);
    final tScore    = _tempScore(vitals.skinTemp);

    // Vitals raw: sum of 4 scores (each 0-2), max = 8
    final vitalsRaw = (hrScore + spo2Score + brScore + tScore).toDouble();
    final vitalsNorm = vitalsRaw / 8.0;

    // ── Care log channels ─────────────────────────────────────────────
    double? hydrationNorm;
    double? feedingNorm;
    double? symptomsNorm;

    if (summary != null) {
      if (summary.hasDiaperLogs) {
        hydrationNorm = _computeHydrationScore(summary);
      }
      if (summary.hasFeedingLogs) {
        feedingNorm = _computeFeedingScore(summary);
      }
      if (summary.hasSymptomLogs) {
        symptomsNorm = _computeSymptomScore(summary);
      }
    }

    // ── Weight redistribution ─────────────────────────────────────────
    // Active channels get their base weight; inactive weights are
    // redistributed proportionally among active channels.
    double wV = _wVitals;
    double wH = hydrationNorm != null ? _wHydration : 0;
    double wF = feedingNorm   != null ? _wFeeding   : 0;
    double wS = symptomsNorm  != null ? _wSymptoms  : 0;

    final totalActive = wV + wH + wF + wS;

    // Normalize weights to sum to 1.0
    wV /= totalActive;
    wH /= totalActive;
    wF /= totalActive;
    wS /= totalActive;

    // ── Composite score ───────────────────────────────────────────────
    double cs = wV * vitalsNorm;
    if (hydrationNorm != null) cs += wH * hydrationNorm;
    if (feedingNorm   != null) cs += wF * feedingNorm;
    if (symptomsNorm  != null) cs += wS * symptomsNorm;

    return cs.clamp(0.0, 1.0);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  PER-PARAMETER SCORING FUNCTIONS
  // ═══════════════════════════════════════════════════════════════════════════

  /// Generic symmetric vital score: 0 (green), 1 (amber), 2 (red zone but
  /// caught by Tier 1 — capped at 2 here for composite math).
  int _vitalScore(double val, double greenLow, double greenHigh,
      double amberLow, double amberHigh) {
    if (val < amberLow || val > amberHigh) return 2;
    if (val < greenLow || val > greenHigh) return 1;
    return 0;
  }

  /// SpO₂: one-sided (only low values are concerning).
  int _spo2Score(double spo2) {
    if (spo2 < spo2AmberLow) return 2;
    if (spo2 < spo2GreenLow) return 1;
    return 0;
  }

  /// Temperature: uses specific thresholds (asymmetric clinical significance).
  int _tempScore(double temp) {
    if (temp < tempAmberLow || temp > tempAmberHigh) return 2;
    if (temp < tempGreenLow || temp > tempGreenHigh) return 1;
    return 0;
  }

  /// Hydration channel normalized score (0.0–1.0).
  /// Based on WHO breastfeeding adequacy indicators.
  double _computeHydrationScore(CareLogSummary summary) {
    // Wet diaper sub-score (0, 1, 2)
    int diaperScore;
    if (summary.wetDiaperCount >= diaperGreenMin) {
      diaperScore = 0;
    } else if (summary.wetDiaperCount >= diaperAmberMin) {
      diaperScore = 1;
    } else {
      diaperScore = 2;
    }

    // Stool character sub-score (0, 1, 2)
    // Based on IMNCI diarrhea classification
    int stoolScore;
    if (summary.hasWateryStool) {
      stoolScore = 2;  // diarrhea — IMNCI concern
    } else if (summary.hasLooseStool) {
      stoolScore = 1;  // monitor
    } else {
      stoolScore = 0;  // normal or none
    }

    // Max possible = 4 (2 params × 2)
    return (diaperScore + stoolScore) / 4.0;
  }

  /// Feeding channel normalized score (0.0–1.0).
  /// Based on WHO exclusive breastfeeding and IAP feeding guidelines.
  double _computeFeedingScore(CareLogSummary summary) {
    // Feed count sub-score (0, 1, 2)
    int countScore;
    if (summary.feedCount >= feedGreenMin) {
      countScore = 0;
    } else if (summary.feedCount >= feedAmberMin) {
      countScore = 1;
    } else {
      countScore = 2;
    }

    // Feed gap sub-score (0, 1, 2)
    int gapScore;
    if (summary.maxFeedGapHours <= feedGapGreenMax) {
      gapScore = 0;
    } else if (summary.maxFeedGapHours <= feedGapAmberMax) {
      gapScore = 1;
    } else {
      gapScore = 2;
    }

    // Max possible = 4
    return (countScore + gapScore) / 4.0;
  }

  /// Symptom channel normalized score (0.0–1.0).
  /// Based on IMNCI symptom classification.
  double _computeSymptomScore(CareLogSummary summary) {
    // Severity sub-score (0, 1, 2)
    // 'severe' is handled by Tier 1 danger sign, so max here is 'moderate' = 2
    int severityScore;
    switch (summary.worstSymptomSeverity) {
      case 'moderate':
        severityScore = 2;
      case 'mild':
        severityScore = 1;
      default:
        severityScore = 0;
    }

    // Symptom count sub-score (0, 1, 2)
    // Multiple concurrent symptoms = higher concern
    int countScore;
    if (summary.symptomTypeCount == 0) {
      countScore = 0;
    } else if (summary.symptomTypeCount == 1) {
      countScore = 1;
    } else {
      countScore = 2; // ≥2 distinct symptom types
    }

    // Max possible = 4
    return (severityScore + countScore) / 4.0;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  PER-VITAL ALERT EVALUATORS (individual clinical messages)
  // ═══════════════════════════════════════════════════════════════════════════

  List<VitalAlert> _evaluateAllVitals(VitalsData vitals) {
    return [
      _evaluateHr(vitals.hr),
      _evaluateSpo2(vitals.spo2),
      _evaluateBr(vitals.br),
      _evaluateTemp(vitals.skinTemp),
    ];
  }

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

  // ═══════════════════════════════════════════════════════════════════════════
  //  CARE LOG ALERT EVALUATORS
  // ═══════════════════════════════════════════════════════════════════════════

  List<VitalAlert> _evaluateAllCareLogs(CareLogSummary summary) {
    final alerts = <VitalAlert>[];
    if (summary.hasDiaperLogs)  alerts.add(_evaluateHydration(summary));
    if (summary.hasFeedingLogs) alerts.add(_evaluateFeeding(summary));
    if (summary.hasSymptomLogs) alerts.add(_evaluateSymptoms(summary));
    return alerts;
  }

  VitalAlert _evaluateHydration(CareLogSummary summary) {
    // Watery stool + low diapers is handled by Tier 1
    if (summary.hasWateryStool && summary.wetDiaperCount < diaperAmberMin) {
      return VitalAlert(
        vital: 'Hydration',
        level: RiskLevel.red,
        message: 'Diarrhea with only ${summary.wetDiaperCount} wet diapers. '
            'Risk of dehydration per IMNCI assessment.',
        shortLabel: 'Dehydration Risk',
      );
    }
    if (summary.wetDiaperCount < diaperAmberMin || summary.hasWateryStool) {
      return VitalAlert(
        vital: 'Hydration',
        level: RiskLevel.amber,
        message: summary.hasWateryStool
            ? 'Watery stool detected — monitor hydration closely.'
            : 'Only ${summary.wetDiaperCount} wet diapers today. '
                'WHO recommends ≥$diaperGreenMin/day.',
        shortLabel: summary.hasWateryStool ? 'Diarrhea' : 'Low Diapers',
      );
    }
    if (summary.wetDiaperCount < diaperGreenMin || summary.hasLooseStool) {
      return VitalAlert(
        vital: 'Hydration',
        level: RiskLevel.amber,
        message: summary.hasLooseStool
            ? 'Loose stool noted — ensure adequate fluid intake.'
            : '${summary.wetDiaperCount} wet diapers so far. Monitor for adequate output.',
        shortLabel: summary.hasLooseStool ? 'Loose Stool' : 'Monitor Diapers',
      );
    }
    return VitalAlert(
      vital: 'Hydration',
      level: RiskLevel.green,
      message: '${summary.wetDiaperCount} wet diapers — adequate hydration.',
      shortLabel: 'Normal',
    );
  }

  VitalAlert _evaluateFeeding(CareLogSummary summary) {
    // >6h gap is Tier 1 danger sign
    if (summary.hoursSinceLastFeed != null &&
        summary.hoursSinceLastFeed! >= feedGapDangerHours) {
      return VitalAlert(
        vital: 'Feeding',
        level: RiskLevel.red,
        message: 'No feeding for ${summary.hoursSinceLastFeed!.toStringAsFixed(1)} hours. '
            'IMNCI danger sign.',
        shortLabel: 'Not Feeding',
      );
    }
    if (summary.feedCount < feedAmberMin ||
        summary.maxFeedGapHours > feedGapAmberMax) {
      return VitalAlert(
        vital: 'Feeding',
        level: RiskLevel.amber,
        message: summary.feedCount < feedAmberMin
            ? 'Only ${summary.feedCount} feeds today. '
                'WHO recommends ≥$feedGreenMin feeds/day.'
            : 'Feed gap of ${summary.maxFeedGapHours.toStringAsFixed(1)}h detected. '
                'Recommended: ≤${feedGapGreenMax.toStringAsFixed(0)}h between feeds.',
        shortLabel: summary.feedCount < feedAmberMin
            ? 'Low Feeds' : 'Feed Gap',
      );
    }
    if (summary.feedCount < feedGreenMin ||
        summary.maxFeedGapHours > feedGapGreenMax) {
      return VitalAlert(
        vital: 'Feeding',
        level: RiskLevel.amber,
        message: '${summary.feedCount} feeds today with '
            '${summary.maxFeedGapHours.toStringAsFixed(1)}h max gap. Monitor.',
        shortLabel: 'Monitor Feeds',
      );
    }
    return VitalAlert(
      vital: 'Feeding',
      level: RiskLevel.green,
      message: '${summary.feedCount} feeds today — adequate frequency.',
      shortLabel: 'Normal',
    );
  }

  VitalAlert _evaluateSymptoms(CareLogSummary summary) {
    if (summary.worstSymptomSeverity == 'severe') {
      return VitalAlert(
        vital: 'Symptoms',
        level: RiskLevel.red,
        message: 'Severe symptom logged. Seek medical assessment.',
        shortLabel: 'Severe Symptom',
      );
    }
    if (summary.worstSymptomSeverity == 'moderate' ||
        summary.symptomTypeCount >= 2) {
      return VitalAlert(
        vital: 'Symptoms',
        level: RiskLevel.amber,
        message: summary.symptomTypeCount >= 2
            ? '${summary.symptomTypeCount} different symptoms logged today. Monitor closely.'
            : 'Moderate symptom logged. Monitor closely.',
        shortLabel: summary.symptomTypeCount >= 2
            ? 'Multiple Symptoms' : 'Moderate Symptom',
      );
    }
    if (summary.symptomTypeCount >= 1) {
      return VitalAlert(
        vital: 'Symptoms',
        level: RiskLevel.amber,
        message: 'Mild symptom logged. Continue to observe.',
        shortLabel: 'Mild Symptom',
      );
    }
    return VitalAlert(
      vital: 'Symptoms',
      level: RiskLevel.green,
      message: 'No concerning symptoms reported.',
      shortLabel: 'Normal',
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  /// Deduplicate alerts — when the same vital appears in both per-vital
  /// evaluation and Tier 1 danger signs, keep the higher-severity one.
  List<VitalAlert> _deduplicateAlerts(List<VitalAlert> alerts) {
    final Map<String, VitalAlert> best = {};
    for (final a in alerts) {
      final existing = best[a.vital];
      if (existing == null || a.level.index > existing.level.index) {
        best[a.vital] = a;
      }
    }
    return best.values.toList();
  }

  /// Map RiskLevel to a RAG-compatible severity string.
  String riskToSeverity(RiskLevel level) => switch (level) {
    RiskLevel.green => 'normal',
    RiskLevel.amber => 'monitor',
    RiskLevel.red   => 'urgent',
  };
}
