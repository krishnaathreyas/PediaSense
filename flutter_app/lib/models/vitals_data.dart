enum RiskLevel { normal, monitor, urgent }

class VitalsData {
  final double spo2;
  final double heartRate;
  final double breathingRate;
  final double skinTemp;
  final double urineGap;
  final int wetDiaperCount;
  final RiskLevel riskLevel;

  VitalsData({
    required this.spo2,
    required this.heartRate,
    required this.breathingRate,
    required this.skinTemp,
    required this.urineGap,
    required this.wetDiaperCount,
    required this.riskLevel,
  });

  VitalsData copyWith({
    double? spo2,
    double? heartRate,
    double? breathingRate,
    double? skinTemp,
    double? urineGap,
    int? wetDiaperCount,
    RiskLevel? riskLevel,
  }) {
    return VitalsData(
      spo2: spo2 ?? this.spo2,
      heartRate: heartRate ?? this.heartRate,
      breathingRate: breathingRate ?? this.breathingRate,
      skinTemp: skinTemp ?? this.skinTemp,
      urineGap: urineGap ?? this.urineGap,
      wetDiaperCount: wetDiaperCount ?? this.wetDiaperCount,
      riskLevel: riskLevel ?? this.riskLevel,
    );
  }

  String get riskLevelString {
    switch (riskLevel) {
      case RiskLevel.normal:
        return 'normal';
      case RiskLevel.monitor:
        return 'monitor';
      case RiskLevel.urgent:
        return 'urgent';
    }
  }

  String get riskText {
    switch (riskLevel) {
      case RiskLevel.normal:
        return 'Normal - Observe';
      case RiskLevel.monitor:
        return 'Monitor Closely';
      case RiskLevel.urgent:
        return 'Act Immediately';
    }
  }
}
