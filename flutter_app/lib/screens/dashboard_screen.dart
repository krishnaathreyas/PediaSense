import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/vitals_data.dart';
import '../models/baby_profile.dart';
import '../services/esp_ble_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  VitalsData _vitals = VitalsData(
    spo2: 98,
    heartRate: 110,
    breathingRate: 28,
    skinTemp: 36.8,
    urineGap: 2.5,
    wetDiaperCount: 6,
    riskLevel: RiskLevel.normal,
  );

  BabyProfile _profile = BabyProfile.defaultProfile();
  final EspBleService _bleService = EspBleService();
  StreamSubscription<VitalsData>? _vitalsSub;
  StreamSubscription<bool>? _connectedSub;
  bool _bleConnected = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _connectedSub = _bleService.connectedStream.listen((connected) {
      if (!mounted) return;
      setState(() {
        _bleConnected = connected;
      });
    });

    _vitalsSub = _bleService.vitalsStream.listen((vitals) {
      if (!mounted) return;
      setState(() {
        _vitals = _vitals.copyWith(
          spo2: vitals.spo2,
          heartRate: vitals.heartRate,
          breathingRate: vitals.breathingRate,
          skinTemp: vitals.skinTemp,
          riskLevel: vitals.riskLevel,
        );
      });
    });

    _bleService.start();
  }

  Future<void> _loadProfile() async {
    final profile = await BabyProfile.load();
    if (mounted) {
      setState(() {
        _profile = profile;
      });
    }
  }

  @override
  void dispose() {
    _vitalsSub?.cancel();
    _connectedSub?.cancel();
    _bleService.dispose();
    super.dispose();
  }

  Color get _riskColor => AppTheme.getRiskColor(_vitals.riskLevelString);

  IconData get _riskIcon {
    switch (_vitals.riskLevel) {
      case RiskLevel.normal:
        return Icons.check_circle;
      case RiskLevel.monitor:
        return Icons.warning_amber;
      case RiskLevel.urgent:
        return Icons.error;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Text('Welcome back,', style: Theme.of(context).textTheme.bodyMedium),
          Text(
            "${_profile.babyName}'s Health",
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 4),
          Text(
            _bleConnected
                ? 'BLE: Connected to ESP32'
                : 'BLE: Scanning for PediaSense...',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),

          // Circular Status Indicator
          _buildStatusCard(),
          const SizedBox(height: 24),

          // Real-time Vitals
          Text(
            'Real-time Vitals',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          _buildVitalsGrid(),
          const SizedBox(height: 24),

          // Hydration Tracker
          Text(
            'Hydration Tracker',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          _buildHydrationCard(),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    return SizedBox(
      width: double.infinity,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_riskColor, _riskColor.withValues(alpha: 0.75)],
          ),
          boxShadow: [
            BoxShadow(
              color: _riskColor.withValues(alpha: 0.4),
              blurRadius: 16,
              offset: const Offset(0, 6),
              spreadRadius: 0,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
          child: Column(
            children: [
              // Circular indicator
              Container(
                width: 130,
                height: 130,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_riskIcon, size: 36, color: _riskColor),
                    const SizedBox(height: 6),
                    Text(
                      _vitals.riskLevelString.toUpperCase(),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: _riskColor,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _vitals.riskText,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'All vitals within expected range',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVitalsGrid() {
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.3,
      children: [
        _buildVitalCard(
          icon: Icons.opacity,
          iconColor: AppTheme.primaryMain,
          label: 'SpO₂',
          value: '${_vitals.spo2.toStringAsFixed(1)}%',
          badge: 'Normal',
          badgeColor: AppTheme.successMain,
        ),
        _buildVitalCard(
          icon: Icons.favorite,
          iconColor: AppTheme.errorMain,
          label: 'Heart Rate',
          value: '${_vitals.heartRate.round()}',
          subtitle: 'bpm',
        ),
        _buildVitalCard(
          icon: Icons.air,
          iconColor: AppTheme.infoMain,
          label: 'Breathing Rate',
          value: '${_vitals.breathingRate.round()}',
          subtitle: 'breaths/min',
        ),
        _buildVitalCard(
          icon: Icons.thermostat,
          iconColor: AppTheme.warningMain,
          label: 'Skin Temp',
          value: '${_vitals.skinTemp.toStringAsFixed(1)}°C',
          subtitle: '${(_vitals.skinTemp * 9 / 5 + 32).toStringAsFixed(1)}°F',
        ),
      ],
    );
  }

  Widget _buildVitalCard({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    String? subtitle,
    String? badge,
    Color? badgeColor,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.headlineLarge?.copyWith(fontSize: 22),
            ),
            if (badge != null) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: (badgeColor ?? AppTheme.successMain).withValues(
                    alpha: 0.1,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: badgeColor ?? AppTheme.successMain,
                  ),
                ),
              ),
            ] else if (subtitle != null)
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _buildHydrationCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Urine Gap
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.water_drop,
                            size: 20,
                            color: AppTheme.infoMain,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Urine Gap',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_vitals.urineGap.toStringAsFixed(1)} hrs',
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      Text(
                        'Since last wet diaper',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                // Wet Diapers
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      "Today's Wet Diapers",
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_vitals.wetDiaperCount}',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    Text(
                      'Normal: 6-8/day',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (_vitals.wetDiaperCount / 8).clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: Colors.grey.shade200,
                valueColor: AlwaysStoppedAnimation<Color>(
                  _vitals.wetDiaperCount >= 6
                      ? AppTheme.successMain
                      : AppTheme.warningMain,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
