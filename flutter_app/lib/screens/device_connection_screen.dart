import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/esp_ble_service.dart';
import '../theme/app_theme.dart';

// ─── Validation: PediaSense device detection ────────────────────────────────
//
// A device is considered a valid PediaSense device if EITHER:
//   1. Its advertised name starts with "PediaSense"
//   2. Its advertisement data contains the PediaSense BLE service UUID
//
// All other devices are shown but marked "Unsupported" and cannot connect.
// ─────────────────────────────────────────────────────────────────────────────

bool _isPediaSenseDevice(ScanResult result) {
  // Check 1: Device name matches expected ESP32 name OR legacy PediaSense prefix
  final name = result.device.platformName.trim();
  final advName = result.advertisementData.advName.trim();
  final effectiveName = (name.isNotEmpty ? name : advName).toLowerCase();

  if (effectiveName == EspBleService.targetDeviceName.toLowerCase()) {
    return true;
  }
  if (effectiveName.startsWith(EspBleService.legacyNamePrefix.toLowerCase())) {
    return true;
  }

  // Check 2: Advertisement contains PediaSense service UUID
  final adServiceUuids = result.advertisementData.serviceUuids;
  if (adServiceUuids.contains(EspBleService.serviceUuid)) return true;

  return false;
}

// ─── Device Connection Screen ───────────────────────────────────────────────

class DeviceConnectionScreen extends StatefulWidget {
  const DeviceConnectionScreen({super.key});

  @override
  State<DeviceConnectionScreen> createState() => _DeviceConnectionScreenState();
}

class _DeviceConnectionScreenState extends State<DeviceConnectionScreen> {
  // ── State ──────────────────────────────────────────────────────────────────
  final Map<String, ScanResult> _deviceMap = {}; // dedup by device ID
  bool _isScanning = false;
  bool _isConnecting = false;
  bool _isConnected = false;
  String _connectingDeviceName = '';
  String? _errorMsg;

  // ── Subscriptions ─────────────────────────────────────────────────────────
  StreamSubscription<List<ScanResult>>? _scanSub;
  final EspBleService _bleService = EspBleService();

  @override
  void initState() {
    super.initState();
    _requestPermissionsAndScan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }

  // ── Permissions ───────────────────────────────────────────────────────────

  Future<void> _requestPermissionsAndScan() async {
    final supported = await FlutterBluePlus.isSupported;
    if (!supported) {
      _setError('Bluetooth LE is not supported on this device.');
      return;
    }

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final granted = statuses.values.every((s) => s.isGranted || s.isLimited);
    if (!granted) {
      _setError('Bluetooth permissions are required. Please allow and retry.');
      return;
    }

    await _startScan();
  }

  // ── Scanning (shows ALL devices, no filtering) ────────────────────────────

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _errorMsg = null;
      _deviceMap.clear();
    });

    // Cancel any previous scan subscription
    await _scanSub?.cancel();
    await FlutterBluePlus.stopScan();

    // Listen to scan results and continuously update the device list
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        for (final result in results) {
          // Dedup by device ID — always keep the latest result (freshest RSSI)
          _deviceMap[result.device.remoteId.str] = result;
        }
      });
    });

    // Start scanning — NO service UUID filter, show ALL devices
    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 12),
      androidUsesFineLocation: true,
    );

    // Scan finished
    if (mounted) {
      setState(() => _isScanning = false);
    }
  }

  // ── Connection (validates PediaSense BEFORE connecting) ───────────────────

  Future<void> _handleDeviceTap(ScanResult result) async {
    // ─── Validation: only connect to PediaSense devices ───
    if (!_isPediaSenseDevice(result)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only PediaSense / ESP32_BLE devices are supported'),
          backgroundColor: AppTheme.warningDark,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // ─── Valid device → attempt connection ───
    final name = result.device.platformName.isNotEmpty
        ? result.device.platformName
        : result.device.remoteId.str;

    setState(() {
      _isConnecting = true;
      _connectingDeviceName = name;
      _errorMsg = null;
    });

    try {
      await FlutterBluePlus.stopScan();

      // Connect via EspBleService (discovers PediaSense characteristics)
      await _bleService.connectToScanResult(result);

      if (!mounted) return;
      setState(() {
        _isConnected = true;
        _isConnecting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _errorMsg = 'Failed to connect to $name. Please try again.';
      });
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _setError(String msg) {
    if (!mounted) return;
    setState(() {
      _isScanning = false;
      _errorMsg = msg;
    });
  }

  /// Sorted device list: only named devices (or PediaSense by UUID).
  /// PediaSense devices appear first, then sorted by signal strength.
  List<ScanResult> get _sortedDevices {
    final devices = _deviceMap.values.where((r) {
      // Always show PediaSense devices (even if name is missing)
      if (_isPediaSenseDevice(r)) return true;
      // Only show other devices that have a real name
      return r.device.platformName.isNotEmpty;
    }).toList();

    devices.sort((a, b) {
      final aSupported = _isPediaSenseDevice(a) ? 0 : 1;
      final bSupported = _isPediaSenseDevice(b) ? 0 : 1;
      if (aSupported != bSupported) return aSupported.compareTo(bSupported);
      return b.rssi.compareTo(a.rssi); // stronger signal first
    });
    return devices;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final devices = _sortedDevices;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header ─────────────────────────────────────────────────
              _buildHeader(),
              const SizedBox(height: 16),

              // ── Scanning progress bar ──────────────────────────────────
              if (_isScanning)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: LinearProgressIndicator(),
                ),

              // ── Error banner ───────────────────────────────────────────
              if (_errorMsg != null) ...[
                _buildErrorBanner(_errorMsg!),
                const SizedBox(height: 12),
              ],

              // ── Device count label ─────────────────────────────────────
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _isScanning
                      ? 'Scanning... (${devices.length} found)'
                      : '${devices.length} device${devices.length == 1 ? '' : 's'} found',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),

              // ── Device List ────────────────────────────────────────────
              Expanded(
                child: devices.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                        itemCount: devices.length,
                        itemBuilder: (context, index) {
                          return _buildDeviceTile(devices[index]);
                        },
                      ),
              ),

              const SizedBox(height: 12),

              // ── Bottom actions ──────────────────────────────────────────
              _buildBottomActions(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _isConnected
                  ? [AppTheme.successMain, AppTheme.successLight]
                  : [AppTheme.primaryMain, AppTheme.primaryLight],
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            _isConnected
                ? Icons.bluetooth_connected
                : (_isScanning ? Icons.bluetooth_searching : Icons.bluetooth),
            color: Colors.white,
            size: 26,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Device Connection',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 2),
              Text(
                _isConnected
                    ? 'Connected to $_connectingDeviceName'
                    : (_isConnecting
                          ? 'Connecting to $_connectingDeviceName...'
                          : 'Pair your PediaSense wearable'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Error banner ────────────────────────────────────────────────────────

  Widget _buildErrorBanner(String msg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.errorMain.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.errorMain.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppTheme.errorMain),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(fontSize: 13, color: AppTheme.errorMain),
            ),
          ),
        ],
      ),
    );
  }

  // ── Empty state ─────────────────────────────────────────────────────────

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _isScanning ? Icons.bluetooth_searching : Icons.bluetooth_disabled,
            size: 48,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 14),
          Text(
            _isScanning
                ? 'Searching for nearby devices...'
                : 'No BLE devices found nearby.',
            style: TextStyle(fontSize: 15, color: Colors.grey.shade500),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ── Single device tile ──────────────────────────────────────────────────

  Widget _buildDeviceTile(ScanResult result) {
    final isSupported = _isPediaSenseDevice(result);
    final name = result.device.platformName.isNotEmpty
        ? result.device.platformName
        : 'Unknown Device';
    final deviceId = result.device.remoteId.str;
    final rssi = result.rssi;
    final isThisConnecting =
        _isConnecting &&
        _connectingDeviceName ==
            (result.device.platformName.isNotEmpty
                ? result.device.platformName
                : result.device.remoteId.str);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSupported
            ? AppTheme.successMain.withValues(alpha: 0.05)
            : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSupported
              ? AppTheme.successMain.withValues(alpha: 0.3)
              : Colors.grey.shade200,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        // ── Icon + signal ──
        leading: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isSupported ? Icons.monitor_heart : Icons.bluetooth,
              color: isSupported ? AppTheme.successMain : Colors.grey.shade400,
              size: 24,
            ),
            const SizedBox(height: 2),
            Text(
              '$rssi dBm',
              style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
            ),
          ],
        ),
        // ── Name + ID ──
        title: Text(
          name,
          style: TextStyle(
            fontSize: 14,
            fontWeight: isSupported ? FontWeight.w600 : FontWeight.w400,
            color: isSupported ? AppTheme.textPrimary : Colors.grey.shade500,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              deviceId,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
            if (!isSupported)
              const Text(
                'Unsupported',
                style: TextStyle(
                  fontSize: 10,
                  color: AppTheme.warningDark,
                  fontWeight: FontWeight.w500,
                ),
              ),
            if (isSupported)
              const Text(
                'PediaSense Device ✓',
                style: TextStyle(
                  fontSize: 10,
                  color: AppTheme.successMain,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
        // ── Connect button ──
        trailing: SizedBox(
          width: 90,
          height: 36,
          child: ElevatedButton(
            onPressed: (_isConnected || _isConnecting)
                ? null
                : () => _handleDeviceTap(result),
            style: ElevatedButton.styleFrom(
              backgroundColor: isSupported
                  ? AppTheme.primaryMain
                  : Colors.grey.shade300,
              foregroundColor: Colors.white,
              padding: EdgeInsets.zero,
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: isThisConnecting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(isSupported ? 'Connect' : 'Connect'),
          ),
        ),
        onTap: (_isConnected || _isConnecting)
            ? null
            : () => _handleDeviceTap(result),
      ),
    );
  }

  // ── Bottom action buttons ───────────────────────────────────────────────

  Widget _buildBottomActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Rescan button
        if (!_isConnected)
          OutlinedButton.icon(
            onPressed: (_isScanning || _isConnecting) ? null : _startScan,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Scan Again'),
          ),
        const SizedBox(height: 8),

        // Proceed to dashboard
        ElevatedButton(
          onPressed: _isConnected
              ? () => Navigator.pushReplacementNamed(context, '/home')
              : null,
          child: const Text('Proceed to Dashboard'),
        ),

        const SizedBox(height: 10),

        OutlinedButton(
          onPressed: () => Navigator.pushReplacementNamed(context, '/home_sim'),
          child: const Text('Proceed to simulated dashboard'),
        ),
      ],
    );
  }
}
