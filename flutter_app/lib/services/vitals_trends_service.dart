import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ─── Data Models ─────────────────────────────────────────────────────────────

/// A single raw sensor reading buffered locally.
class SensorReading {
  final String type; // "heart_rate" | "breathing_rate"
  final double value;
  final DateTime timestamp;

  SensorReading({
    required this.type,
    required this.value,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'value': value,
    'timestamp': timestamp.toIso8601String(),
  };

  factory SensorReading.fromJson(Map<String, dynamic> j) => SensorReading(
    type: j['type'] as String,
    value: (j['value'] as num).toDouble(),
    timestamp: DateTime.parse(j['timestamp'] as String),
  );
}

/// An aggregated hourly vitals record.
class HourlyVitals {
  final String? id;
  final String babyId;
  final DateTime hourStart;
  final double avgHr, minHr, maxHr;
  final double avgBr, minBr, maxBr;
  final bool eventFlag;
  bool synced;

  HourlyVitals({
    this.id,
    this.babyId = 'default',
    required this.hourStart,
    required this.avgHr,
    required this.minHr,
    required this.maxHr,
    required this.avgBr,
    required this.minBr,
    required this.maxBr,
    required this.eventFlag,
    this.synced = false,
  });

  Map<String, dynamic> toSupabaseJson() => {
    'baby_id': babyId,
    'hour_start': hourStart.toUtc().toIso8601String(),
    'avg_hr': avgHr,
    'min_hr': minHr,
    'max_hr': maxHr,
    'avg_br': avgBr,
    'min_br': minBr,
    'max_br': maxBr,
    'event_flag': eventFlag,
  };

  Map<String, dynamic> toLocalJson() => {...toSupabaseJson(), 'synced': synced};

  factory HourlyVitals.fromSupabase(Map<String, dynamic> j) => HourlyVitals(
    id: j['id'] as String?,
    babyId: j['baby_id'] as String? ?? 'default',
    hourStart: DateTime.parse(j['hour_start'] as String).toLocal(),
    avgHr: (j['avg_hr'] as num?)?.toDouble() ?? 0,
    minHr: (j['min_hr'] as num?)?.toDouble() ?? 0,
    maxHr: (j['max_hr'] as num?)?.toDouble() ?? 0,
    avgBr: (j['avg_br'] as num?)?.toDouble() ?? 0,
    minBr: (j['min_br'] as num?)?.toDouble() ?? 0,
    maxBr: (j['max_br'] as num?)?.toDouble() ?? 0,
    eventFlag: j['event_flag'] as bool? ?? false,
    synced: true,
  );

  factory HourlyVitals.fromLocalJson(Map<String, dynamic> j) => HourlyVitals(
    babyId: j['baby_id'] as String? ?? 'default',
    hourStart: DateTime.parse(j['hour_start'] as String).toLocal(),
    avgHr: (j['avg_hr'] as num?)?.toDouble() ?? 0,
    minHr: (j['min_hr'] as num?)?.toDouble() ?? 0,
    maxHr: (j['max_hr'] as num?)?.toDouble() ?? 0,
    avgBr: (j['avg_br'] as num?)?.toDouble() ?? 0,
    minBr: (j['min_br'] as num?)?.toDouble() ?? 0,
    maxBr: (j['max_br'] as num?)?.toDouble() ?? 0,
    eventFlag: j['event_flag'] as bool? ?? false,
    synced: j['synced'] as bool? ?? false,
  );
}

// ─── Vitals Trends Service (Singleton) ───────────────────────────────────────

class VitalsTrendsService {
  VitalsTrendsService._();
  static final VitalsTrendsService instance = VitalsTrendsService._();

  static const _bufferKeyPrefix = 'sensor_buffer';
  static const _localVitalsKeyPrefix = 'local_hourly_vitals';
  static const _table = 'hourly_vitals';

  SupabaseClient get _db => Supabase.instance.client;

  Timer? _simulationTimer;
  Timer? _aggregationTimer;
  Timer? _syncTimer;
  final _rng = Random();

  String _resolveBabyId(String? babyId) {
    final resolved =
        babyId ?? _db.auth.currentSession?.user.id ?? _db.auth.currentUser?.id;
    if (resolved == null || resolved.isEmpty) {
      throw StateError('No authenticated user. Unable to resolve baby_id.');
    }
    return resolved;
  }

  String _bufferKey(String babyId) => '${_bufferKeyPrefix}_$babyId';
  String _localVitalsKey(String babyId) => '${_localVitalsKeyPrefix}_$babyId';

  // ═══════════════════════════════════════════════════════════════════════════
  //  1. LOCAL SENSOR BUFFER (SharedPreferences)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Add a raw sensor reading to the local buffer.
  Future<void> bufferReading(SensorReading reading, {String? babyId}) async {
    final resolvedBabyId = _resolveBabyId(babyId);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_bufferKey(resolvedBabyId)) ?? [];
    raw.add(jsonEncode(reading.toJson()));
    await prefs.setStringList(_bufferKey(resolvedBabyId), raw);
  }

  /// Get all buffered readings.
  Future<List<SensorReading>> getBufferedReadings({String? babyId}) async {
    final resolvedBabyId = _resolveBabyId(babyId);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_bufferKey(resolvedBabyId)) ?? [];
    return raw.map((s) => SensorReading.fromJson(jsonDecode(s))).toList();
  }

  /// Clear the sensor buffer after aggregation.
  Future<void> clearBuffer({String? babyId}) async {
    final resolvedBabyId = _resolveBabyId(babyId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_bufferKey(resolvedBabyId));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  2. HOURLY AGGREGATION
  // ═══════════════════════════════════════════════════════════════════════════

  /// Aggregate buffered readings into an hourly record.
  Future<HourlyVitals?> aggregate({String? babyId}) async {
    final resolvedBabyId = _resolveBabyId(babyId);
    final readings = await getBufferedReadings(babyId: resolvedBabyId);
    if (readings.isEmpty) return null;

    final hrReadings = readings.where((r) => r.type == 'heart_rate').toList();
    final brReadings = readings
        .where((r) => r.type == 'breathing_rate')
        .toList();

    if (hrReadings.isEmpty && brReadings.isEmpty) return null;

    // Compute heart rate stats
    double avgHr = 0, minHr = 0, maxHr = 0;
    if (hrReadings.isNotEmpty) {
      final hrValues = hrReadings.map((r) => r.value).toList();
      avgHr = hrValues.reduce((a, b) => a + b) / hrValues.length;
      minHr = hrValues.reduce((a, b) => a < b ? a : b);
      maxHr = hrValues.reduce((a, b) => a > b ? a : b);
    }

    // Compute breathing rate stats
    double avgBr = 0, minBr = 0, maxBr = 0;
    if (brReadings.isNotEmpty) {
      final brValues = brReadings.map((r) => r.value).toList();
      avgBr = brValues.reduce((a, b) => a + b) / brValues.length;
      minBr = brValues.reduce((a, b) => a < b ? a : b);
      maxBr = brValues.reduce((a, b) => a > b ? a : b);
    }

    // Detect abnormal conditions
    final eventFlag = avgHr < 100 || avgHr > 130 || avgBr < 25 || avgBr > 35;

    // Hour start = truncate to hour
    final now = DateTime.now();
    final hourStart = DateTime(now.year, now.month, now.day, now.hour);

    final vitals = HourlyVitals(
      babyId: resolvedBabyId,
      hourStart: hourStart,
      avgHr: double.parse(avgHr.toStringAsFixed(1)),
      minHr: double.parse(minHr.toStringAsFixed(1)),
      maxHr: double.parse(maxHr.toStringAsFixed(1)),
      avgBr: double.parse(avgBr.toStringAsFixed(1)),
      minBr: double.parse(minBr.toStringAsFixed(1)),
      maxBr: double.parse(maxBr.toStringAsFixed(1)),
      eventFlag: eventFlag,
      synced: false,
    );

    // Store locally
    await _storeLocalVitals(vitals);

    // Clear buffer after successful aggregation
    await clearBuffer(babyId: resolvedBabyId);

    // Try to sync immediately
    await syncUnsynced(babyId: resolvedBabyId);

    return vitals;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  3. LOCAL STORAGE FOR AGGREGATED RECORDS
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _storeLocalVitals(HourlyVitals vitals) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _localVitalsKey(vitals.babyId);
    final raw = prefs.getStringList(key) ?? [];

    // Check for duplicate (same hour_start)
    final hourStr = vitals.hourStart.toUtc().toIso8601String();
    raw.removeWhere((s) {
      final j = jsonDecode(s) as Map<String, dynamic>;
      return j['hour_start'] == hourStr;
    });

    raw.add(jsonEncode(vitals.toLocalJson()));
    await prefs.setStringList(key, raw);
  }

  Future<List<HourlyVitals>> getLocalVitals({String? babyId}) async {
    final resolvedBabyId = _resolveBabyId(babyId);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_localVitalsKey(resolvedBabyId)) ?? [];
    return raw.map((s) => HourlyVitals.fromLocalJson(jsonDecode(s))).toList()
      ..sort((a, b) => b.hourStart.compareTo(a.hourStart));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  4. OFFLINE-FIRST SYNC
  // ═══════════════════════════════════════════════════════════════════════════

  /// Push all unsynced local records to Supabase.
  Future<void> syncUnsynced({String? babyId}) async {
    final resolvedBabyId = _resolveBabyId(babyId);
    final prefs = await SharedPreferences.getInstance();
    final key = _localVitalsKey(resolvedBabyId);
    final raw = prefs.getStringList(key) ?? [];
    bool changed = false;

    final updated = <String>[];
    for (final s in raw) {
      final j = jsonDecode(s) as Map<String, dynamic>;
      if (j['synced'] == true) {
        updated.add(s);
        continue;
      }

      try {
        final vitals = HourlyVitals.fromLocalJson(j);
        // Upsert to prevent duplicates (unique index on baby_id + hour_start)
        await _db
            .from(_table)
            .upsert(vitals.toSupabaseJson(), onConflict: 'baby_id,hour_start')
            .timeout(const Duration(seconds: 5));
        j['synced'] = true;
        updated.add(jsonEncode(j));
        changed = true;
      } catch (e) {
        debugPrint(
          'Vitals sync failed for baby_id=${j['baby_id']} hour_start=${j['hour_start']}: $e',
        );
        // Keep as unsynced, will retry later
        updated.add(s);
      }
    }

    if (changed) {
      await prefs.setStringList(key, updated);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  5. FETCH FROM SUPABASE (for trends)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Fetch hourly vitals for the last N hours.
  Future<List<HourlyVitals>> fetchHourly({
    int hours = 24,
    String? babyId,
  }) async {
    final resolvedBabyId = _resolveBabyId(babyId);
    final from = DateTime.now().subtract(Duration(hours: hours));
    final response = await _db
        .from(_table)
        .select()
        .eq('baby_id', resolvedBabyId)
        .gte('hour_start', from.toUtc().toIso8601String())
        .order('hour_start', ascending: true)
        .timeout(const Duration(seconds: 6));

    return (response as List)
        .map((r) => HourlyVitals.fromSupabase(r as Map<String, dynamic>))
        .toList();
  }

  /// Fetch hourly vitals for the last N days.
  Future<List<HourlyVitals>> fetchDays({int days = 7, String? babyId}) async {
    final resolvedBabyId = _resolveBabyId(babyId);
    final from = DateTime.now().subtract(Duration(days: days));
    final response = await _db
        .from(_table)
        .select()
        .eq('baby_id', resolvedBabyId)
        .gte('hour_start', from.toUtc().toIso8601String())
        .order('hour_start', ascending: true)
        .timeout(const Duration(seconds: 6));

    return (response as List)
        .map((r) => HourlyVitals.fromSupabase(r as Map<String, dynamic>))
        .toList();
  }

  /// Group hourly records by day and compute daily averages.
  static List<Map<String, dynamic>> groupByDay(List<HourlyVitals> records) {
    final grouped = <String, List<HourlyVitals>>{};
    for (final r in records) {
      final key =
          '${r.hourStart.year}-${r.hourStart.month.toString().padLeft(2, '0')}-${r.hourStart.day.toString().padLeft(2, '0')}';
      grouped.putIfAbsent(key, () => []).add(r);
    }

    final result = <Map<String, dynamic>>[];
    for (final entry in grouped.entries) {
      final list = entry.value;
      final avgHr =
          list.map((r) => r.avgHr).reduce((a, b) => a + b) / list.length;
      final avgBr =
          list.map((r) => r.avgBr).reduce((a, b) => a + b) / list.length;
      final hasEvents = list.any((r) => r.eventFlag);
      result.add({
        'date': entry.key,
        'avgHr': double.parse(avgHr.toStringAsFixed(1)),
        'avgBr': double.parse(avgBr.toStringAsFixed(1)),
        'eventFlag': hasEvents,
        'count': list.length,
      });
    }

    result.sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
    return result;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  6. DYNAMIC INSIGHTS
  // ═══════════════════════════════════════════════════════════════════════════

  static List<Map<String, String>> generateInsights(
    List<HourlyVitals> vitals, {
    int diaperCount = 0,
    int feedingCount = 0,
  }) {
    final insights = <Map<String, String>>[];

    if (vitals.isEmpty) {
      insights.add({
        'label': 'Data:',
        'text': 'Not enough data yet. Keep monitoring to build trends.',
      });
      return insights;
    }

    // Heart rate insight
    final avgHr =
        vitals.map((v) => v.avgHr).reduce((a, b) => a + b) / vitals.length;
    if (avgHr >= 100 && avgHr <= 130) {
      insights.add({
        'label': 'Heart Rate:',
        'text':
            'Average ${avgHr.toStringAsFixed(0)} bpm — within normal range (100-130 bpm). No concerns.',
      });
    } else {
      insights.add({
        'label': 'Heart Rate:',
        'text':
            'Average ${avgHr.toStringAsFixed(0)} bpm — outside normal range. Consider consulting your pediatrician.',
      });
    }

    // Breathing insight
    final avgBr =
        vitals.map((v) => v.avgBr).reduce((a, b) => a + b) / vitals.length;
    if (avgBr >= 25 && avgBr <= 35) {
      insights.add({
        'label': 'Breathing:',
        'text':
            'Average ${avgBr.toStringAsFixed(0)} breaths/min — consistent within normal range.',
      });
    } else {
      insights.add({
        'label': 'Breathing:',
        'text':
            'Average ${avgBr.toStringAsFixed(0)} breaths/min — slightly outside normal range. Monitor closely.',
      });
    }

    // Event flag insight
    final eventCount = vitals.where((v) => v.eventFlag).length;
    if (eventCount > 0) {
      insights.add({
        'label': 'Alerts:',
        'text':
            '$eventCount hour(s) with abnormal readings detected in this period.',
      });
    }

    // Hydration insight
    if (diaperCount > 0) {
      insights.add({
        'label': 'Hydration:',
        'text': diaperCount >= 6
            ? '$diaperCount wet diapers today — adequate hydration.'
            : '$diaperCount wet diapers today — below recommended (6+). Increase fluid intake.',
      });
    }

    // Feeding insight
    if (feedingCount > 0) {
      insights.add({
        'label': 'Feeding:',
        'text': '$feedingCount feeding sessions logged today.',
      });
    }

    return insights;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  7. SIMULATION (for testing without hardware)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Start simulating sensor readings every 5 seconds.
  void startSimulation() {
    final resolvedBabyId = _resolveBabyId(null);

    _simulationTimer?.cancel();
    _simulationTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _simulateSensorData(resolvedBabyId);
    });

    // Auto-aggregate every 60 seconds for testing (instead of 1 hour)
    _aggregationTimer?.cancel();
    _aggregationTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      aggregate(babyId: resolvedBabyId);
    });

    // Auto-sync every 30 seconds
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      syncUnsynced(babyId: resolvedBabyId);
    });
  }

  void stopSimulation() {
    _simulationTimer?.cancel();
    _aggregationTimer?.cancel();
    _syncTimer?.cancel();
  }

  void _simulateSensorData(String babyId) {
    // Simulate realistic neonatal vitals
    final hr = 110.0 + _rng.nextDouble() * 20 - 5; // 105-125 bpm
    final br = 28.0 + _rng.nextDouble() * 8 - 2; // 26-34 breaths/min

    bufferReading(
      SensorReading(
        type: 'heart_rate',
        value: double.parse(hr.toStringAsFixed(1)),
        timestamp: DateTime.now(),
      ),
      babyId: babyId,
    );
    bufferReading(
      SensorReading(
        type: 'breathing_rate',
        value: double.parse(br.toStringAsFixed(1)),
        timestamp: DateTime.now(),
      ),
      babyId: babyId,
    );
  }

  /// Manually trigger aggregation (for testing).
  Future<HourlyVitals?> triggerAggregation() => aggregate();
}
