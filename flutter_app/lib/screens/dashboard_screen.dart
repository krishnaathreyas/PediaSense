import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../theme/app_theme.dart';
import '../models/vitals_data.dart';
import '../models/baby_profile.dart';
import '../models/cry_prediction.dart';
import '../services/esp_ble_service.dart';
import '../services/cry_detection_service.dart';
import '../services/simulated_vitals_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.simulated = false});

  final bool simulated;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  VitalsData? _vitals;

  BabyProfile _profile = BabyProfile.defaultProfile();

  // Services
  EspBleService? _bleService;
  SimulatedVitalsService? _sim;

  StreamSubscription<VitalsData>? _vitalsSub;
  StreamSubscription<BleConnectionStatus>? _statusSub;
  BleConnectionStatus _bleStatus = BleConnectionStatus.disconnected;

  // ── Cry detection UX state ───────────────────────────────────────────────
  StreamSubscription<CryDetectionUpdate>? _crySub;
  CryDetectionStage _cryStage = CryDetectionStage.idle;
  double _cryProgress = 0;
  int? _crySecondsLeft;
  CryPrediction? _cryPrediction;
  String? _cryMessage;

  late final AnimationController _orbController;

  @override
  void initState() {
    super.initState();

    _orbController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);

    _loadProfile();
    _initVitalsSource();
  }

  Future<void> _initVitalsSource() async {
    if (widget.simulated) {
      final sim = SimulatedVitalsService();
      _sim = sim;
      sim.start();

      _vitalsSub = sim.stream.listen((vitals) {
        if (!mounted) return;
        setState(() => _vitals = vitals);
      });

      if (!mounted) return;
      setState(() => _bleStatus = BleConnectionStatus.disconnected);
      return;
    }

    try {
      final supported = await FlutterBluePlus.isSupported;
      if (!supported) throw Exception('BLE not supported');

      final ble = EspBleService();
      _bleService = ble;

      _statusSub = ble.statusStream.listen((status) {
        if (!mounted) return;
        setState(() => _bleStatus = status);
      });

      _vitalsSub = ble.vitalsStream.listen((vitals) {
        if (!mounted) return;
        setState(() => _vitals = vitals);
      });

      // If already connected via the DeviceConnectionScreen, don't force a re-scan.
      if (ble.connectedDevice == null) {
        await ble.start();
      } else {
        final latest = ble.latestVitals;
        if (latest != null && mounted) {
          setState(() => _vitals = latest);
        }
      }
    } catch (_) {
      // BLE unavailable — remain disconnected; UI will reflect state
      if (!mounted) return;
      setState(() => _bleStatus = BleConnectionStatus.disconnected);
    }
  }

  Future<void> _loadProfile() async {
    final profile = await BabyProfile.load();
    if (mounted) {
      setState(() => _profile = profile);
    }
  }

  @override
  void dispose() {
    _vitalsSub?.cancel();
    _statusSub?.cancel();
    _crySub?.cancel();
    _orbController.dispose();
    _bleService?.dispose();
    _sim?.stop();
    super.dispose();
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  "${_profile.babyName}'s Health",
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
              ),
              _BleStatusDot(controller: _orbController, status: _bleStatus),
            ],
          ),
          const SizedBox(height: 6),
          Text(_bleStatusLabel, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 18),

          // Vitals (edge-processed by ESP32)
          Text('Vitals', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          _buildVitalsGrid(),
          const SizedBox(height: 22),

          // Detect Cry
          Text('Detect Cry', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          _buildCryDetectionCard(),
          const SizedBox(height: 24),

          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Future<void> _startCryDetection() async {
    if (widget.simulated) {
      _showSnack('Cry detection requires a connected PediaSense device.');
      return;
    }
    if (_bleStatus != BleConnectionStatus.connected) {
      _showSnack('Connect to ${EspBleService.targetDeviceName} first.');
      return;
    }

    await _crySub?.cancel();
    setState(() {
      _cryStage = CryDetectionStage.requestingCapture;
      _cryProgress = 0;
      _crySecondsLeft = 5;
      _cryPrediction = null;
      _cryMessage = null;
    });

    final stream = CryDetectionService.instance.startCryDetection(
      captureDuration: const Duration(seconds: 5),
      modelH: 128,
      modelW: 128,
    );

    _crySub = stream.listen((u) {
      if (!mounted) return;
      setState(() {
        _cryStage = u.stage;
        _cryProgress = u.progress;
        _crySecondsLeft = u.secondsRemaining ?? _crySecondsLeft;
        _cryPrediction = u.prediction ?? _cryPrediction;
        _cryMessage = u.message;
      });
    });
  }

  Future<void> _cancelCryDetection() async {
    await CryDetectionService.instance.cancel();
    if (!mounted) return;
    setState(() {
      _cryStage = CryDetectionStage.cancelled;
      _cryMessage = 'Cancelled';
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Widget _buildCryDetectionCard() {
    final isActive =
        _cryStage == CryDetectionStage.requestingCapture ||
        _cryStage == CryDetectionStage.capturing ||
        _cryStage == CryDetectionStage.transferring ||
        _cryStage == CryDetectionStage.preprocessing ||
        _cryStage == CryDetectionStage.inferring;

    final Color glow = switch (_cryPrediction?.type) {
      CryType.hungry => AppTheme.warningMain,
      CryType.pain => AppTheme.errorMain,
      CryType.sleepy => AppTheme.infoMain,
      CryType.normal => AppTheme.successMain,
      _ => AppTheme.primaryMain,
    };

    final title = switch (_cryStage) {
      CryDetectionStage.idle => 'Tap to analyze a 5s cry sample',
      CryDetectionStage.requestingCapture => 'Starting capture...',
      CryDetectionStage.capturing => 'Listening...',
      CryDetectionStage.transferring => 'Receiving audio...',
      CryDetectionStage.preprocessing => 'Building spectrogram...',
      CryDetectionStage.inferring => 'Running model...',
      CryDetectionStage.completed => 'Result',
      CryDetectionStage.cancelled => 'Cancelled',
      CryDetectionStage.error => 'Error',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _GlowingOrb(
                  controller: _orbController,
                  color: glow,
                  active: isActive,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _cryMessage ??
                            (_cryPrediction != null
                                ? '${_cryPrediction!.label} detected'
                                : 'Ready'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (isActive)
                  TextButton(
                    onPressed: _cancelCryDetection,
                    child: const Text('Stop'),
                  ),
              ],
            ),
            const SizedBox(height: 14),

            if (isActive) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: _cryProgress.clamp(0.0, 1.0),
                  minHeight: 10,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation<Color>(glow),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _cryStage == CryDetectionStage.capturing
                        ? 'Recording (${_crySecondsLeft ?? 0}s left)'
                        : 'Processing',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    '${(_cryProgress * 100).round()}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ] else ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _startCryDetection,
                  icon: const Icon(Icons.graphic_eq),
                  label: const Text('Detect Cry'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],

            if (_cryStage == CryDetectionStage.completed &&
                _cryPrediction != null) ...[
              const SizedBox(height: 14),
              _buildCryResultCard(_cryPrediction!, glow),
            ],

            if (_cryStage == CryDetectionStage.error) ...[
              const SizedBox(height: 12),
              Text(
                _cryMessage ?? 'Cry detection failed',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppTheme.errorMain),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCryResultCard(CryPrediction pred, Color glow) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [glow.withValues(alpha: 0.14), glow.withValues(alpha: 0.06)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: glow.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, color: glow),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${pred.label} Detected',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  'Confidence: ${(pred.confidence * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String get _bleStatusLabel {
    if (widget.simulated) {
      return 'Simulated dashboard (no BLE connection)';
    }
    switch (_bleStatus) {
      case BleConnectionStatus.connected:
        return 'Connected to ${EspBleService.targetDeviceName}';
      case BleConnectionStatus.connecting:
        return 'Connecting…';
      case BleConnectionStatus.scanning:
        return 'Scanning for ${EspBleService.targetDeviceName}…';
      case BleConnectionStatus.reconnecting:
        return 'Reconnecting…';
      case BleConnectionStatus.disconnected:
        return 'Disconnected';
    }
  }

  Widget _buildVitalsGrid() {
    final v = _vitals;

    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.15,
      children: [
        _buildVitalCard(
          icon: Icons.favorite,
          accent: AppTheme.errorMain,
          label: 'Heart Rate',
          value: v == null ? '--' : '${v.hr}',
          unit: 'bpm',
        ),
        _buildVitalCard(
          icon: Icons.opacity,
          accent: AppTheme.primaryMain,
          label: 'SpO₂',
          value: v == null ? '--' : '${v.spo2}',
          unit: '%',
        ),
        _buildVitalCard(
          icon: Icons.air,
          accent: AppTheme.infoMain,
          label: 'Breathing Rate',
          value: v == null ? '--' : '${v.br}',
          unit: 'breaths/min',
        ),
        _buildVitalCard(
          icon: Icons.thermostat,
          accent: AppTheme.warningMain,
          label: 'Skin Temperature',
          value: v == null ? '--' : v.skinTemp.toStringAsFixed(1),
          unit: '°C',
        ),
      ],
    );
  }

  Widget _buildVitalCard({
    required IconData icon,
    required Color accent,
    required String label,
    required String value,
    required String unit,
  }) {
    return Card(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            colors: [
              accent.withValues(alpha: 0.10),
              accent.withValues(alpha: 0.03),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 20, color: accent),
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
              const SizedBox(height: 10),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: Text(
                  value,
                  key: ValueKey<String>(value),
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    fontSize: 28,
                    height: 1.1,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(unit, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _BleStatusDot extends StatelessWidget {
  const _BleStatusDot({required this.controller, required this.status});

  final AnimationController controller;
  final BleConnectionStatus status;

  Color get _color {
    switch (status) {
      case BleConnectionStatus.connected:
        return AppTheme.successMain;
      case BleConnectionStatus.reconnecting:
        return AppTheme.warningMain;
      case BleConnectionStatus.connecting:
      case BleConnectionStatus.scanning:
        return AppTheme.infoMain;
      case BleConnectionStatus.disconnected:
        return AppTheme.textSecondary;
    }
  }

  bool get _isActive {
    switch (status) {
      case BleConnectionStatus.connected:
      case BleConnectionStatus.disconnected:
        return false;
      case BleConnectionStatus.scanning:
      case BleConnectionStatus.connecting:
      case BleConnectionStatus.reconnecting:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value;
        final scale = _isActive ? (1.0 + 0.18 * t) : 1.0;
        final glow = _isActive ? (0.18 + 0.22 * t) : 0.10;

        return Transform.scale(
          scale: scale,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _color,
              boxShadow: [
                BoxShadow(
                  color: _color.withValues(alpha: glow),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _GlowingOrb extends StatelessWidget {
  const _GlowingOrb({
    required this.controller,
    required this.color,
    required this.active,
  });

  final AnimationController controller;
  final Color color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value;
        final scale = active ? (1.0 + 0.08 * t) : 1.0;
        final glow = active ? (0.35 + 0.35 * t) : 0.18;

        return Transform.scale(
          scale: scale,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  color.withValues(alpha: 0.9),
                  color.withValues(alpha: 0.35),
                ],
                radius: 0.85,
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: glow),
                  blurRadius: 22,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(
              active ? Icons.mic : Icons.mic_none,
              color: Colors.white,
              size: 22,
            ),
          ),
        );
      },
    );
  }
}
