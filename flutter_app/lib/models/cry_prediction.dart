enum CryType { hungry, pain, sleepy, normal, unknown }

class CryPrediction {
  final CryType type;

  /// 0.0 - 1.0
  final double confidence;
  final DateTime predictedAt;

  const CryPrediction({
    required this.type,
    required this.confidence,
    required this.predictedAt,
  });

  String get label {
    switch (type) {
      case CryType.hungry:
        return 'Hungry Cry';
      case CryType.pain:
        return 'Pain Cry';
      case CryType.sleepy:
        return 'Sleepy Cry';
      case CryType.normal:
        return 'Normal Sound';
      case CryType.unknown:
        return 'Unknown';
    }
  }
}
