import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../theme/app_theme.dart';

class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key});

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  String _timeRange = '7d';

  // Mock data
  final List<Map<String, dynamic>> _breathingData = [
    {'time': 'Mon', 'rate': 28.0},
    {'time': 'Tue', 'rate': 26.0},
    {'time': 'Wed', 'rate': 30.0},
    {'time': 'Thu', 'rate': 29.0},
    {'time': 'Fri', 'rate': 27.0},
    {'time': 'Sat', 'rate': 31.0},
    {'time': 'Sun', 'rate': 28.0},
  ];

  final List<Map<String, dynamic>> _heartRateData = [
    {'time': '6 AM', 'hr': 108.0},
    {'time': '9 AM', 'hr': 112.0},
    {'time': '12 PM', 'hr': 115.0},
    {'time': '3 PM', 'hr': 110.0},
    {'time': '6 PM', 'hr': 118.0},
    {'time': '9 PM', 'hr': 105.0},
  ];

  final List<Map<String, dynamic>> _activityData = [
    {'hour': '12AM', 'sleep': 60.0, 'active': 0.0, 'feeding': 0.0},
    {'hour': '2AM', 'sleep': 60.0, 'active': 0.0, 'feeding': 0.0},
    {'hour': '4AM', 'sleep': 50.0, 'active': 0.0, 'feeding': 10.0},
    {'hour': '6AM', 'sleep': 40.0, 'active': 10.0, 'feeding': 10.0},
    {'hour': '8AM', 'sleep': 20.0, 'active': 30.0, 'feeding': 10.0},
    {'hour': '10AM', 'sleep': 40.0, 'active': 15.0, 'feeding': 5.0},
    {'hour': '12PM', 'sleep': 30.0, 'active': 20.0, 'feeding': 10.0},
    {'hour': '2PM', 'sleep': 50.0, 'active': 5.0, 'feeding': 5.0},
    {'hour': '4PM', 'sleep': 20.0, 'active': 30.0, 'feeding': 10.0},
    {'hour': '6PM', 'sleep': 10.0, 'active': 40.0, 'feeding': 10.0},
    {'hour': '8PM', 'sleep': 40.0, 'active': 15.0, 'feeding': 5.0},
    {'hour': '10PM', 'sleep': 55.0, 'active': 5.0, 'feeding': 0.0},
  ];

  final List<Map<String, dynamic>> _hydrationData = [
    {'day': 'Mon', 'wet_diapers': 7.0, 'feeding_sessions': 8.0},
    {'day': 'Tue', 'wet_diapers': 6.0, 'feeding_sessions': 7.0},
    {'day': 'Wed', 'wet_diapers': 8.0, 'feeding_sessions': 9.0},
    {'day': 'Thu', 'wet_diapers': 7.0, 'feeding_sessions': 8.0},
    {'day': 'Fri', 'wet_diapers': 6.0, 'feeding_sessions': 7.0},
    {'day': 'Sat', 'wet_diapers': 7.0, 'feeding_sessions': 8.0},
    {'day': 'Sun', 'wet_diapers': 8.0, 'feeding_sessions': 9.0},
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
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

          // Breathing Regularity Chart
          _buildChartCard(
            title: 'Breathing Regularity',
            subtitle:
                'Average breathing rate per day (normal range: 25-35 breaths/min)',
            child: SizedBox(
              height: 220,
              child: _buildBreathingChart(),
            ),
          ),
          const SizedBox(height: 16),

          // Heart Rate Trend
          _buildChartCard(
            title: 'Heart Rate Trend',
            subtitle:
                "Today's heart rate measurements (normal: 100-130 bpm)",
            child: SizedBox(
              height: 180,
              child: _buildHeartRateChart(),
            ),
          ),
          const SizedBox(height: 16),

          // Activity Patterns
          _buildChartCard(
            title: '24-Hour Activity Pattern',
            subtitle:
                'Distribution of sleep, active time, and feeding',
            child: Column(
              children: [
                SizedBox(
                  height: 220,
                  child: _buildActivityChart(),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _legendItem('Sleep', AppTheme.primaryMain),
                    const SizedBox(width: 16),
                    _legendItem('Active', AppTheme.successMain),
                    const SizedBox(width: 16),
                    _legendItem('Feeding', AppTheme.warningMain),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Hydration & Feeding Trends
          _buildChartCard(
            title: 'Hydration & Feeding Trends',
            subtitle: 'Daily wet diapers and feeding sessions',
            child: Column(
              children: [
                SizedBox(
                  height: 180,
                  child: _buildHydrationChart(),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _legendItem('Wet Diapers', AppTheme.infoMain),
                    const SizedBox(width: 16),
                    _legendItem('Feeding Sessions', AppTheme.warningMain),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Weekly Insights
          Card(
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
                    'Weekly Insights',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.primaryDark,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _insightItem(
                    'Breathing:',
                    'Consistent pattern within normal range. No concerning fluctuations detected.',
                  ),
                  const SizedBox(height: 8),
                  _insightItem(
                    'Activity:',
                    'Good sleep-wake cycle with 14-16 hours of sleep per day (expected for age).',
                  ),
                  const SizedBox(height: 8),
                  _insightItem(
                    'Hydration:',
                    'Average of 7 wet diapers per day indicates adequate hydration.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

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

  Widget _legendItem(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
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
              style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
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

  // ── Charts ──

  Widget _buildBreathingChart() {
    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 5,
          getDrawingHorizontalLine: (value) => FlLine(
            color: Colors.grey.shade200,
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx >= 0 && idx < _breathingData.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_breathingData[idx]['time'],
                        style: const TextStyle(fontSize: 10)),
                  );
                }
                return const SizedBox.shrink();
              },
              reservedSize: 28,
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              interval: 5,
              getTitlesWidget: (value, meta) => Text(
                '${value.toInt()}',
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
          topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
        ),
        minY: 20,
        maxY: 40,
        borderData: FlBorderData(show: false),
        // Normal range shading
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
            spots: _breathingData
                .asMap()
                .entries
                .map((e) => FlSpot(e.key.toDouble(), e.value['rate']))
                .toList(),
            isCurved: true,
            color: AppTheme.successMain,
            barWidth: 3,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) =>
                  FlDotCirclePainter(
                radius: 4,
                color: AppTheme.successMain,
                strokeWidth: 0,
              ),
            ),
            belowBarData: BarAreaData(show: false),
          ),
        ],
      ),
    );
  }

  Widget _buildHeartRateChart() {
    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 5,
          getDrawingHorizontalLine: (value) => FlLine(
            color: Colors.grey.shade200,
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx >= 0 && idx < _heartRateData.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_heartRateData[idx]['time'],
                        style: const TextStyle(fontSize: 9)),
                  );
                }
                return const SizedBox.shrink();
              },
              reservedSize: 28,
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              interval: 5,
              getTitlesWidget: (value, meta) => Text(
                '${value.toInt()}',
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
          topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
        ),
        minY: 95,
        maxY: 125,
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: _heartRateData
                .asMap()
                .entries
                .map((e) => FlSpot(e.key.toDouble(), e.value['hr']))
                .toList(),
            isCurved: true,
            color: AppTheme.errorMain,
            barWidth: 2,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) =>
                  FlDotCirclePainter(
                radius: 5,
                color: AppTheme.errorMain,
                strokeWidth: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityChart() {
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        barTouchData: BarTouchData(enabled: false),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 20,
          getDrawingHorizontalLine: (value) => FlLine(
            color: Colors.grey.shade200,
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx >= 0 && idx < _activityData.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_activityData[idx]['hour'],
                        style: const TextStyle(fontSize: 8)),
                  );
                }
                return const SizedBox.shrink();
              },
              reservedSize: 28,
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 20,
              getTitlesWidget: (value, meta) => Text(
                '${value.toInt()}',
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
          topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        barGroups: _activityData.asMap().entries.map((entry) {
          final d = entry.value;
          return BarChartGroupData(
            x: entry.key,
            barRods: [
              BarChartRodData(
                toY: d['sleep'] + d['active'] + d['feeding'],
                width: 14,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                ),
                rodStackItems: [
                  BarChartRodStackItem(0, d['sleep'], AppTheme.primaryMain),
                  BarChartRodStackItem(d['sleep'],
                      d['sleep'] + d['active'], AppTheme.successMain),
                  BarChartRodStackItem(d['sleep'] + d['active'],
                      d['sleep'] + d['active'] + d['feeding'], AppTheme.warningMain),
                ],
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildHydrationChart() {
    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 2,
          getDrawingHorizontalLine: (value) => FlLine(
            color: Colors.grey.shade200,
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx >= 0 && idx < _hydrationData.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_hydrationData[idx]['day'],
                        style: const TextStyle(fontSize: 10)),
                  );
                }
                return const SizedBox.shrink();
              },
              reservedSize: 28,
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 2,
              getTitlesWidget: (value, meta) => Text(
                '${value.toInt()}',
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
          topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
        ),
        minY: 4,
        maxY: 12,
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: _hydrationData
                .asMap()
                .entries
                .map((e) =>
                    FlSpot(e.key.toDouble(), e.value['wet_diapers']))
                .toList(),
            isCurved: true,
            color: AppTheme.infoMain,
            barWidth: 2,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) =>
                  FlDotCirclePainter(
                radius: 4,
                color: AppTheme.infoMain,
                strokeWidth: 0,
              ),
            ),
          ),
          LineChartBarData(
            spots: _hydrationData
                .asMap()
                .entries
                .map((e) =>
                    FlSpot(e.key.toDouble(), e.value['feeding_sessions']))
                .toList(),
            isCurved: true,
            color: AppTheme.warningMain,
            barWidth: 2,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) =>
                  FlDotCirclePainter(
                radius: 4,
                color: AppTheme.warningMain,
                strokeWidth: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
