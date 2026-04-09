import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

import '../theme/app_theme.dart';
import '../services/vitals_trends_service.dart';
import '../services/care_log_service.dart';
import '../models/log_entry.dart';

class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key});

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  final _trendsService = VitalsTrendsService.instance;
  final _careLogService = CareLogService.instance;

  String _timeRange = '7d';
  bool _isLoading = true;
  String? _error;

  // ── Fetched data ──
  List<HourlyVitals> _vitals = [];
  List<Map<String, dynamic>> _dailyVitals = [];
  List<Map<String, dynamic>> _hydrationData = [];
  List<Map<String, String>> _insights = [];

  @override
  void initState() {
    super.initState();
    // Start simulation so data gets generated
    _trendsService.startSimulation();
    _fetchData();
  }

  @override
  void dispose() {
    super.dispose();
  }

  // ── Data fetching ─────────────────────────────────────────────────────────

  Future<void> _fetchData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Fetch vitals from Supabase based on time range
      List<HourlyVitals> vitals;
      if (_timeRange == '24h') {
        vitals = await _trendsService.fetchHourly(hours: 24);
      } else if (_timeRange == '7d') {
        vitals = await _trendsService.fetchDays(days: 7);
      } else {
        vitals = await _trendsService.fetchDays(days: 30);
      }

      // If no remote data, try local
      if (vitals.isEmpty) {
        vitals = await _trendsService.getLocalVitals();
      }

      // Group by day for daily charts
      final daily = VitalsTrendsService.groupByDay(vitals);

      // Fetch today's care logs for hydration/feeding
      List<LogEntry> todayLogs = [];
      try {
        todayLogs = await _careLogService.fetchTodayLogs();
      } catch (_) {}

      final diaperCount =
          todayLogs.where((l) => l.type == LogType.diaper).length;
      final feedingCount =
          todayLogs.where((l) => l.type == LogType.feeding).length;

      // Build hydration data from care_logs (last 7 days)
      List<Map<String, dynamic>> hydration = [];
      try {
        final weekLogs = await _careLogService.fetchTodayLogs();
        // Group today's logs
        hydration = [
          {
            'day': 'Today',
            'wet_diapers': weekLogs
                .where((l) => l.type == LogType.diaper)
                .length
                .toDouble(),
            'feeding_sessions': weekLogs
                .where((l) => l.type == LogType.feeding)
                .length
                .toDouble(),
          }
        ];
      } catch (_) {}

      // Generate dynamic insights
      final insights = VitalsTrendsService.generateInsights(
        vitals,
        diaperCount: diaperCount,
        feedingCount: feedingCount,
      );

      if (!mounted) return;
      setState(() {
        _vitals = vitals;
        _dailyVitals = daily;
        _hydrationData = hydration;
        _insights = insights;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Failed to load trends. Pull down to retry.';
      });
    }
  }

  // ═════════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═════════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _fetchData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text('Health Trends',
                style: Theme.of(context).textTheme.headlineLarge),
            const SizedBox(height: 8),
            Text("Visualize your baby's health patterns over time",
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),

            // Time Range Selector
            Center(
              child: ToggleButtons(
                isSelected: [
                  _timeRange == '24h',
                  _timeRange == '7d',
                  _timeRange == '30d',
                ],
                onPressed: (index) {
                  setState(() {
                    _timeRange = ['24h', '7d', '30d'][index];
                  });
                  _fetchData();
                },
                borderRadius: BorderRadius.circular(8),
                selectedColor: Colors.white,
                fillColor: AppTheme.primaryMain,
                color: AppTheme.textSecondary,
                constraints:
                    const BoxConstraints(minWidth: 80, minHeight: 36),
                children: const [
                  Text('24 Hours', style: TextStyle(fontSize: 12)),
                  Text('7 Days', style: TextStyle(fontSize: 12)),
                  Text('30 Days', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ── Content ──
            if (_isLoading)
              const SizedBox(
                height: 300,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _buildErrorState()
            else if (_vitals.isEmpty)
              _buildEmptyState()
            else ...[
              // Heart Rate Chart
              _buildChartCard(
                title: 'Heart Rate Trend',
                subtitle: _timeRange == '24h'
                    ? 'Hourly avg heart rate (normal: 100-130 bpm)'
                    : 'Daily avg heart rate (normal: 100-130 bpm)',
                child: SizedBox(
                  height: 200,
                  child: _timeRange == '24h'
                      ? _buildHourlyHrChart()
                      : _buildDailyHrChart(),
                ),
              ),
              const SizedBox(height: 16),

              // Breathing Chart
              _buildChartCard(
                title: 'Breathing Regularity',
                subtitle: _timeRange == '24h'
                    ? 'Hourly avg breathing rate (normal: 25-35/min)'
                    : 'Daily avg breathing rate (normal: 25-35/min)',
                child: SizedBox(
                  height: 200,
                  child: _timeRange == '24h'
                      ? _buildHourlyBrChart()
                      : _buildDailyBrChart(),
                ),
              ),
              const SizedBox(height: 16),

              // Hydration & Feeding
              if (_hydrationData.isNotEmpty) ...[
                _buildChartCard(
                  title: 'Hydration & Feeding',
                  subtitle: "Today's diaper and feeding counts",
                  child: _buildHydrationSummary(),
                ),
                const SizedBox(height: 16),
              ],

              // Insights
              _buildInsightsCard(),
            ],

            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }

  // ── Charts ──────────────────────────────────────────────────────────────

  Widget _buildHourlyHrChart() {
    if (_vitals.isEmpty) return _chartEmpty();
    return LineChart(
      LineChartData(
        gridData: _defaultGrid(),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: (_vitals.length / 6).ceilToDouble().clamp(1, 10),
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx >= 0 && idx < _vitals.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${_vitals[idx].hourStart.hour}:00',
                      style: const TextStyle(fontSize: 9),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
              reservedSize: 28,
            ),
          ),
          leftTitles: _leftTitles(interval: 10),
          topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
        ),
        minY: 80,
        maxY: 150,
        borderData: FlBorderData(show: false),
        rangeAnnotations: RangeAnnotations(
          horizontalRangeAnnotations: [
            HorizontalRangeAnnotation(
              y1: 100,
              y2: 130,
              color: AppTheme.successMain.withValues(alpha: 0.08),
            ),
          ],
        ),
        lineBarsData: [
          LineChartBarData(
            spots: _vitals
                .asMap()
                .entries
                .map((e) => FlSpot(e.key.toDouble(), e.value.avgHr))
                .toList(),
            isCurved: true,
            color: AppTheme.errorMain,
            barWidth: 2,
            dotData: FlDotData(
              show: _vitals.length <= 30,
              getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                radius: 3,
                color: AppTheme.errorMain,
                strokeWidth: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDailyHrChart() {
    if (_dailyVitals.isEmpty) return _chartEmpty();
    return LineChart(
      LineChartData(
        gridData: _defaultGrid(),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx >= 0 && idx < _dailyVitals.length) {
                  final parts =
                      (_dailyVitals[idx]['date'] as String).split('-');
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('${parts[2]}/${parts[1]}',
                        style: const TextStyle(fontSize: 9)),
                  );
                }
                return const SizedBox.shrink();
              },
              reservedSize: 28,
            ),
          ),
          leftTitles: _leftTitles(interval: 10),
          topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
        ),
        minY: 80,
        maxY: 150,
        borderData: FlBorderData(show: false),
        rangeAnnotations: RangeAnnotations(
          horizontalRangeAnnotations: [
            HorizontalRangeAnnotation(
              y1: 100,
              y2: 130,
              color: AppTheme.successMain.withValues(alpha: 0.08),
            ),
          ],
        ),
        lineBarsData: [
          LineChartBarData(
            spots: _dailyVitals
                .asMap()
                .entries
                .map((e) =>
                    FlSpot(e.key.toDouble(), (e.value['avgHr'] as num).toDouble()))
                .toList(),
            isCurved: true,
            color: AppTheme.errorMain,
            barWidth: 3,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                radius: 4,
                color: AppTheme.errorMain,
                strokeWidth: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHourlyBrChart() {
    if (_vitals.isEmpty) return _chartEmpty();
    return LineChart(
      LineChartData(
        gridData: _defaultGrid(),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: (_vitals.length / 6).ceilToDouble().clamp(1, 10),
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx >= 0 && idx < _vitals.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${_vitals[idx].hourStart.hour}:00',
                      style: const TextStyle(fontSize: 9),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
              reservedSize: 28,
            ),
          ),
          leftTitles: _leftTitles(interval: 5),
          topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
        ),
        minY: 15,
        maxY: 45,
        borderData: FlBorderData(show: false),
        rangeAnnotations: RangeAnnotations(
          horizontalRangeAnnotations: [
            HorizontalRangeAnnotation(
              y1: 25,
              y2: 35,
              color: AppTheme.successMain.withValues(alpha: 0.08),
            ),
          ],
        ),
        lineBarsData: [
          LineChartBarData(
            spots: _vitals
                .asMap()
                .entries
                .map((e) => FlSpot(e.key.toDouble(), e.value.avgBr))
                .toList(),
            isCurved: true,
            color: AppTheme.successMain,
            barWidth: 2,
            dotData: FlDotData(
              show: _vitals.length <= 30,
              getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                radius: 3,
                color: AppTheme.successMain,
                strokeWidth: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDailyBrChart() {
    if (_dailyVitals.isEmpty) return _chartEmpty();
    return LineChart(
      LineChartData(
        gridData: _defaultGrid(),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx >= 0 && idx < _dailyVitals.length) {
                  final parts =
                      (_dailyVitals[idx]['date'] as String).split('-');
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('${parts[2]}/${parts[1]}',
                        style: const TextStyle(fontSize: 9)),
                  );
                }
                return const SizedBox.shrink();
              },
              reservedSize: 28,
            ),
          ),
          leftTitles: _leftTitles(interval: 5),
          topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
        ),
        minY: 15,
        maxY: 45,
        borderData: FlBorderData(show: false),
        rangeAnnotations: RangeAnnotations(
          horizontalRangeAnnotations: [
            HorizontalRangeAnnotation(
              y1: 25,
              y2: 35,
              color: AppTheme.successMain.withValues(alpha: 0.08),
            ),
          ],
        ),
        lineBarsData: [
          LineChartBarData(
            spots: _dailyVitals
                .asMap()
                .entries
                .map((e) =>
                    FlSpot(e.key.toDouble(), (e.value['avgBr'] as num).toDouble()))
                .toList(),
            isCurved: true,
            color: AppTheme.successMain,
            barWidth: 3,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                radius: 4,
                color: AppTheme.successMain,
                strokeWidth: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Hydration summary ────────────────────────────────────────────────────

  Widget _buildHydrationSummary() {
    final data = _hydrationData.isNotEmpty ? _hydrationData.first : {};
    final diapers = (data['wet_diapers'] as num?)?.toInt() ?? 0;
    final feedings = (data['feeding_sessions'] as num?)?.toInt() ?? 0;

    return Row(
      children: [
        Expanded(
          child: _statCard(
            icon: Icons.water_drop,
            label: 'Wet Diapers',
            value: '$diapers',
            color: AppTheme.infoMain,
            status: diapers >= 6 ? 'Adequate' : 'Low',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _statCard(
            icon: Icons.restaurant,
            label: 'Feedings',
            value: '$feedings',
            color: AppTheme.warningMain,
            status: 'Today',
          ),
        ),
      ],
    );
  }

  Widget _statCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    required String status,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 8),
          Text(value,
              style: TextStyle(
                  fontSize: 28, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
          Text(status,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  // ── Insights card ───────────────────────────────────────────────────────

  Widget _buildInsightsCard() {
    return Card(
      color: AppTheme.primaryLight.withValues(alpha: 0.1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
            color: AppTheme.primaryLight.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Insights',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: AppTheme.primaryDark,
              ),
            ),
            const SizedBox(height: 12),
            ..._insights.map((i) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _insightItem(i['label']!, i['text']!),
                )),
          ],
        ),
      ),
    );
  }

  // ── Shared helpers ──────────────────────────────────────────────────────

  Widget _buildChartCard({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(subtitle,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }

  Widget _insightItem(String boldText, String normalText) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('• ', style: TextStyle(fontSize: 14)),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: const TextStyle(
                  fontSize: 13, color: AppTheme.textSecondary),
              children: [
                TextSpan(
                  text: boldText,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(text: ' $normalText'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  FlGridData _defaultGrid() {
    return FlGridData(
      show: true,
      drawVerticalLine: false,
      horizontalInterval: 10,
      getDrawingHorizontalLine: (value) => FlLine(
        color: Colors.grey.shade200,
        strokeWidth: 1,
      ),
    );
  }

  AxisTitles _leftTitles({double interval = 10}) {
    return AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 32,
        interval: interval,
        getTitlesWidget: (value, meta) => Text(
          '${value.toInt()}',
          style: const TextStyle(fontSize: 10),
        ),
      ),
    );
  }

  Widget _chartEmpty() {
    return Center(
      child: Text(
        'No data for this period',
        style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
      ),
    );
  }

  Widget _buildEmptyState() {
    return SizedBox(
      height: 300,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.show_chart, size: 56, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              'No trend data yet',
              style: TextStyle(
                  fontSize: 16, color: Colors.grey.shade500,
                  fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Text(
              'Vitals will appear here as your device\ncollects data over time.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: () async {
                await _trendsService.triggerAggregation();
                _fetchData();
              },
              child: const Text('Generate Test Data'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return SizedBox(
      height: 300,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(_error!,
                style: TextStyle(color: Colors.grey.shade500),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _fetchData,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
