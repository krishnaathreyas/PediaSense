// PediaSense — Care Log model with Supabase serialization.

enum LogType { diaper, feeding, symptom }

class LogEntry {
  final String id;
  final String babyId;
  final DateTime timestamp;
  final LogType type;
  final Map<String, dynamic> data;

  LogEntry({
    required this.id,
    this.babyId = 'default',
    required this.timestamp,
    required this.type,
    required this.data,
  });

  // ── Supabase serialization ──────────────────────────────────────────────

  /// Create from Supabase row
  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry(
      id: json['id'] as String,
      babyId: json['baby_id'] as String? ?? 'default',
      timestamp: DateTime.parse(json['created_at'] as String).toLocal(),
      type: _parseType(json['type'] as String),
      data: (json['value'] as Map<String, dynamic>?) ?? {},
    );
  }

  /// Convert to Supabase insert payload (no id/created_at — auto-generated)
  Map<String, dynamic> toInsertJson() {
    return {
      'baby_id': babyId,
      'type': typeString,
      'value': data,
    };
  }

  // ── Type helpers ────────────────────────────────────────────────────────

  String get typeString {
    switch (type) {
      case LogType.diaper:
        return 'diaper';
      case LogType.feeding:
        return 'feeding';
      case LogType.symptom:
        return 'symptom';
    }
  }

  static LogType _parseType(String s) {
    switch (s) {
      case 'diaper':
        return LogType.diaper;
      case 'feeding':
        return LogType.feeding;
      case 'symptom':
        return LogType.symptom;
      default:
        return LogType.symptom;
    }
  }

  // ── Display helpers ─────────────────────────────────────────────────────

  String get formattedData {
    switch (type) {
      case LogType.diaper:
        final wet = data['wetness'] ?? data['wet'] ?? '?';
        final stool = data['stool'] ?? 'none';
        return '$wet • Stool: $stool';
      case LogType.feeding:
        final mode = data['type'] ?? data['mode'] ?? '?';
        final dur = data['duration'] ?? 0;
        return '$mode milk • $dur min';
      case LogType.symptom:
        final sym = data['type'] ?? data['symptom'] ?? '?';
        final sev = data['severity'] ?? 'unknown';
        return '$sym ($sev)';
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

  String get formattedTime {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String get formattedDate {
    return '${timestamp.day}/${timestamp.month}/${timestamp.year}';
  }
}
