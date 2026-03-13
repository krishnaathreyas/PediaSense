enum LogType { diaper, feeding, symptom }

class LogEntry {
  final String id;
  final DateTime timestamp;
  final LogType type;
  final Map<String, dynamic> data;

  LogEntry({
    required this.id,
    required this.timestamp,
    required this.type,
    required this.data,
  });

  String get formattedData {
    switch (type) {
      case LogType.diaper:
        return '${data['wetness']} • Stool: ${data['stool']}';
      case LogType.feeding:
        return '${data['type']} milk • ${data['duration']} min';
      case LogType.symptom:
        return '${data['type']} (${data['severity']})';
    }
  }

  String get typeLabel {
    switch (type) {
      case LogType.diaper:
        return 'Diaper';
      case LogType.feeding:
        return 'Feeding';
      case LogType.symptom:
        return 'Symptom';
    }
  }
}
