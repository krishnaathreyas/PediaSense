import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/esp_ble_service.dart';
import '../theme/app_theme.dart';

class DeviceConnectionScreen extends StatefulWidget {
  const DeviceConnectionScreen({super.key});

  @override
  State<DeviceConnectionScreen> createState() => _DeviceConnectionScreenState();
}

class _DeviceConnectionScreenState extends State<DeviceConnectionScreen> {
  final EspBleService _bleService = EspBleService();
  StreamSubscription<bool>? _connectedSub;
  StreamSubscription<List<ScanResult>>? _scanSub;

  bool _isConnected = false;
  bool _isScanning = true;
  String _deviceName = '';
  bool _isConnecting = false;
  List<ScanResult> _scanResults = [];
  String _hint = '';

  @override
  void initState() {
    super.initState();

    _connectedSub = _bleService.connectedStream.listen((connected) {
      if (!mounted) return;
      setState(() {
        _isConnected = connected;
        _isScanning = !connected;
        if (!connected) {
          _isConnecting = false;
        }
      });
    });

    _scanSub = _bleService.scanResultsStream.listen((results) {
      if (!mounted) return;
      final dedup = <String, ScanResult>{};
      for (final result in results) {
        dedup[result.device.remoteId.str] = result;
      }
      setState(() {
        _scanResults = dedup.values.toList();
      });
    });

    _initAndScan();
  }

  Future<void> _initAndScan() async {
    final supported = await FlutterBluePlus.isSupported;
    if (!supported) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _hint = 'Bluetooth LE not supported on this device. Use a real phone.';
      });
      return;
    }

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final granted = statuses.values.every((s) => s.isGranted || s.isLimited);
    if (!granted) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _hint = 'Bluetooth permissions are required. Please allow and retry.';
      });
      return;
    }

    _hint = 'Tip: BLE scan works on a physical phone (not Android emulator).';
    await _startScan();
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _isConnecting = false;
    });
    await _bleService.scanNearby();
  }

  Future<void> _connectTo(ScanResult result) async {
    setState(() {
      _isConnecting = true;
      _deviceName = result.device.platformName.isNotEmpty
          ? result.device.platformName
          : result.device.remoteId.str;
    });
    await _bleService.connectToScanResult(result);
    if (!mounted) return;
    setState(() {
      _isConnecting = false;
    });
  }

  @override
  void dispose() {
    _connectedSub?.cancel();
    _scanSub?.cancel();
    _bleService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isConnected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_searching,
                  size: 64,
                  color: _isConnected
                      ? AppTheme.successMain
                      : AppTheme.primaryMain,
                ),
                const SizedBox(height: 16),
                Text(
                  'Device Connection',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  _isConnected
                      ? 'Connected to $_deviceName'
                      : (_isScanning
                            ? 'Scanning nearby BLE devices...'
                            : 'Device not connected'),
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                if (_hint.isNotEmpty)
                  Text(
                    _hint,
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                const SizedBox(height: 28),
                SizedBox(
                  height: 220,
                  child: Card(
                    child: _scanResults.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                _isScanning
                                    ? 'Scanning...'
                                    : 'No nearby BLE devices found.',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(8),
                            itemCount: _scanResults.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final item = _scanResults[index];
                              final name = item.device.platformName.isNotEmpty
                                  ? item.device.platformName
                                  : 'Unknown Device';
                              return ListTile(
                                leading: const Icon(Icons.memory),
                                title: Text(name),
                                subtitle: Text(item.device.remoteId.str),
                                trailing: ElevatedButton(
                                  onPressed: (_isConnected || _isConnecting)
                                      ? null
                                      : () => _connectTo(item),
                                  child: const Text('Connect'),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 24),
                if (!_isConnected)
                  OutlinedButton(
                    onPressed: _isConnecting ? null : _startScan,
                    child: const Text('Retry Scan'),
                  ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _isConnected
                      ? () => Navigator.pushReplacementNamed(context, '/home')
                      : null,
                  child: const Text('Proceed to Dashboard'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
