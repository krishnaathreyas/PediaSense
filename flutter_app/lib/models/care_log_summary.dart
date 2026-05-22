import 'log_entry.dart';

// ═══════════════════════════════════════════════════════════════════════════════
//  Care Log Summary — Aggregated metrics from today's care logs
// ═══════════════════════════════════════════════════════════════════════════════
//
//  Transforms raw LogEntry list into evaluation-ready metrics for the
//  Neonatal Health Evaluation Engine.
//
//  Sources:
//  • Wet diaper count: WHO breastfeeding adequacy (≥6/day after day 5)
//  • Feed frequency: WHO exclusive BF recommendation (8–12 feeds/24h)
//  • Symptom severity: IMNCI danger sign classification
// ═══════════════════════════════════════════════════════════════════════════════

class CareLogSummary {
  /// Number of wet (or very-wet) diapers in the evaluation window.
  final int wetDiaperCount;

  /// Whether any watery / diarrhea stool was logged.
  final bool hasWateryStool;

  /// Whether any loose stool was logged.
  final bool hasLooseStool;

  /// Total number of feeds logged in the evaluation window.
  final int feedCount;

  /// Longest gap (in hours) between consecutive feeds.
  /// 0.0 if ≤1 feed logged.
  final double maxFeedGapHours;

  /// Hours since the most recent feed. `null` if no feeds logged.
  final double? hoursSinceLastFeed;

  /// Number of distinct symptom types logged today.
  final int symptomTypeCount;

  /// Worst severity among all symptoms logged today.
  /// One of: 'none', 'mild', 'moderate', 'severe'.
  final String worstSymptomSeverity;

  // ── Channel availability flags ───────────────────────────────────────────
  // True if at least one log of that type exists today.
  // When false, the evaluator skips that channel and redistributes weight.

  final bool hasDiaperLogs;
  final bool hasFeedingLogs;
  final bool hasSymptomLogs;

  const CareLogSummary({
    required this.wetDiaperCount,
    required this.hasWateryStool,
    required this.hasLooseStool,
    required this.feedCount,
    required this.maxFeedGapHours,
    required this.hoursSinceLastFeed,
    required this.symptomTypeCount,
    required this.worstSymptomSeverity,
    required this.hasDiaperLogs,
    required this.hasFeedingLogs,
    required this.hasSymptomLogs,
  });

  /// Whether any care log channel is available.
  bool get hasAnyLogs => hasDiaperLogs || hasFeedingLogs || hasSymptomLogs;

  /// Build a summary from a list of today's log entries.
  factory CareLogSummary.fromLogs(List<LogEntry> logs) {
    final now = DateTime.now();

    // ── Diaper analysis ──────────────────────────────────────────────────
    final diaperLogs = logs.where((l) => l.type == LogType.diaper).toList();
    int wetCount = 0;
    bool wateryStool = false;
    bool looseStool = false;

    for (final log in diaperLogs) {
      final wetness = (log.data['wetness'] ?? log.data['wet'] ?? '')
          .toString()
          .toLowerCase();
      if (wetness == 'wet' || wetness == 'very-wet') {
        wetCount++;
      }

      final stool =
          (log.data['stool'] ?? '').toString().toLowerCase();
      if (stool == 'watery') wateryStool = true;
      if (stool == 'loose') looseStool = true;
    }

    // ── Feeding analysis ─────────────────────────────────────────────────
    final feedingLogs = logs.where((l) => l.type == LogType.feeding).toList();
    // Sort by timestamp ascending for gap calculation
    feedingLogs.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    double maxGapHours = 0;
    for (int i = 1; i < feedingLogs.length; i++) {
      final gap = feedingLogs[i]
          .timestamp
          .difference(feedingLogs[i - 1].timestamp)
          .inMinutes /
          60.0;
      if (gap > maxGapHours) maxGapHours = gap;
    }

    double? hoursSinceLast;
    if (feedingLogs.isNotEmpty) {
      hoursSinceLast =
          now.difference(feedingLogs.last.timestamp).inMinutes / 60.0;
      // The gap from last feed to now might be the largest gap
      if (hoursSinceLast > maxGapHours) {
        maxGapHours = hoursSinceLast;
      }
    }

    // ── Symptom analysis ─────────────────────────────────────────────────
    final symptomLogs = logs.where((l) => l.type == LogType.symptom).toList();

    final symptomTypes = <String>{};
    String worstSeverity = 'none';
    const severityOrder = ['none', 'mild', 'moderate', 'severe'];

    for (final log in symptomLogs) {
      final symType =
          (log.data['type'] ?? log.data['symptom'] ?? '').toString();
      if (symType.isNotEmpty) symptomTypes.add(symType);

      final sev = (log.data['severity'] ?? 'mild').toString().toLowerCase();
      final currentIdx = severityOrder.indexOf(worstSeverity);
      final newIdx = severityOrder.indexOf(sev);
      if (newIdx > currentIdx) worstSeverity = sev;
    }

    return CareLogSummary(
      wetDiaperCount: wetCount,
      hasWateryStool: wateryStool,
      hasLooseStool: looseStool,
      feedCount: feedingLogs.length,
      maxFeedGapHours: maxGapHours,
      hoursSinceLastFeed: hoursSinceLast,
      symptomTypeCount: symptomTypes.length,
      worstSymptomSeverity: worstSeverity,
      hasDiaperLogs: diaperLogs.isNotEmpty,
      hasFeedingLogs: feedingLogs.isNotEmpty,
      hasSymptomLogs: symptomLogs.isNotEmpty,
    );
  }

  /// Empty summary — no logs available.
  const CareLogSummary.empty()
      : wetDiaperCount = 0,
        hasWateryStool = false,
        hasLooseStool = false,
        feedCount = 0,
        maxFeedGapHours = 0,
        hoursSinceLastFeed = null,
        symptomTypeCount = 0,
        worstSymptomSeverity = 'none',
        hasDiaperLogs = false,
        hasFeedingLogs = false,
        hasSymptomLogs = false;

  @override
  String toString() =>
      'CareLogSummary(diapers=$wetDiaperCount wet, watery=$hasWateryStool, '
      'feeds=$feedCount, maxGap=${maxGapHours.toStringAsFixed(1)}h, '
      'symptoms=$symptomTypeCount [$worstSymptomSeverity])';
}
