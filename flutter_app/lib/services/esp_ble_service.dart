import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/vitals_data.dart';

enum BleConnectionStatus {
  disconnected,
  scanning,
  connecting,
  connected,
  reconnecting,
}

class EspBleService {
  EspBleService._internal();
  static final EspBleService instance = EspBleService._internal();
  factory EspBleService() => instance;

  // ──────────────────────────────────────────────────────────────────────────
  //  ESP32 identification
  // ──────────────────────────────────────────────────────────────────────────
  /// Expected advertised BLE name.
  static const String targetDeviceName = 'ESP32_BLE';

  /// Optional alternate name prefix used by older firmware builds.
  static const String legacyNamePrefix = 'PediaSense';

  // ──────────────────────────────────────────────────────────────────────────
  //  UUID placeholders (IMPORTANT: update to match your ESP32 firmware)
  // ──────────────────────────────────────────────────────────────────────────
  /// The primary GATT service that exposes sensor data.
  /// TODO: Replace with your ESP32 service UUID.
  static final Guid serviceUuid = Guid('12345678-1234-1234-1234-1234567890ab');

  /// Characteristic that streams newline-delimited JSON sensor samples.
  /// TODO: Replace with your ESP32 characteristic UUID.
  static final Guid sensorDataUuid = Guid(
    'abcd1234-5678-1234-5678-abcdef123456',
  );

  /// Backwards-compatible alias (older code refers to `dataUuid`).
  static Guid get dataUuid => sensorDataUuid;

  /// Set to true once your ESP32 advertises `serviceUuid` in scan results.
  /// If false, scanning is name-based and does not require service UUID.
  static const bool useServiceUuidScanFilter = false;

  final _vitalsController = StreamController<VitalsData>.broadcast();
  final _connectedController = StreamController<bool>.broadcast();
  final _statusController = StreamController<BleConnectionStatus>.broadcast();
  final _scanResultsController = StreamController<List<ScanResult>>.broadcast();

  Stream<VitalsData> get vitalsStream => _vitalsController.stream;
  Stream<bool> get connectedStream => _connectedController.stream;
  Stream<BleConnectionStatus> get statusStream => _statusController.stream;
  Stream<List<ScanResult>> get scanResultsStream =>
      _scanResultsController.stream;

  VitalsData? _latest;
  VitalsData? get latestVitals => _latest;

  BluetoothDevice? _device;
  BluetoothDevice? get connectedDevice => _device;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  final List<StreamSubscription<List<int>>> _notifySubs = [];

  String _rxBuffer = '';
  bool _isStarting = false;
  bool _shouldReconnect = true;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  void _log(String msg) {
    // Centralized logging so it can be swapped later.
    // ignore: avoid_print
    print('[EspBleService] $msg');
  }

  Future<void> _ensureBlePermissions() async {
    if (!Platform.isAndroid) return;

    // Android requires runtime permissions for BLE scan/connect on most versions.
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final granted = statuses.values.every((s) => s.isGranted || s.isLimited);
    if (!granted) {
      throw Exception('Bluetooth permissions not granted');
    }
  }

  Future<void> start() async {
    if (_isStarting) return;
    _isStarting = true;

    try {
      await _ensureBlePermissions();

      _shouldReconnect = true;
      _reconnectAttempt = 0;
      _reconnectTimer?.cancel();

      await FlutterBluePlus.stopScan();

      _statusController.add(BleConnectionStatus.scanning);

      await _scanAndAutoConnect(timeout: const Duration(seconds: 12));
    } finally {
      _isStarting = false;
    }
  }

  Future<void> _scanAndAutoConnect({required Duration timeout}) async {
    await _scanSub?.cancel();

    _log(
      'Scanning for $targetDeviceName (filter=${useServiceUuidScanFilter ? 'serviceUuid' : 'name'})...',
    );

    _scanSub = FlutterBluePlus.scanResults.listen((results) async {
      _scanResultsController.add(results);

      for (final result in results) {
        if (_isTarget(result)) {
          final name = _displayName(result);
          _log('Found target device: $name (${result.device.remoteId.str})');
          await FlutterBluePlus.stopScan();
          try {
            _statusController.add(BleConnectionStatus.connecting);
            await _connect(result.device);
          } catch (e) {
            _log('Auto-connect failed: $e');
            _statusController.add(BleConnectionStatus.reconnecting);
            _scheduleReconnect();
          }
          return;
        }
      }
    });

    if (useServiceUuidScanFilter) {
      await FlutterBluePlus.startScan(
        withServices: [serviceUuid],
        timeout: timeout,
        androidUsesFineLocation: true,
      );
    } else {
      await FlutterBluePlus.startScan(
        timeout: timeout,
        androidUsesFineLocation: true,
      );
    }
  }

  bool _isTarget(ScanResult result) {
    final platformName = result.device.platformName.trim();
    final advName = result.advertisementData.advName.trim();

    final name = (platformName.isNotEmpty ? platformName : advName)
        .toLowerCase();
    if (name == targetDeviceName.toLowerCase()) return true;
    if (name.startsWith(legacyNamePrefix.toLowerCase())) return true;

    if (useServiceUuidScanFilter) {
      return result.advertisementData.serviceUuids.contains(serviceUuid);
    }
    return false;
  }

  String _displayName(ScanResult r) {
    final n = r.device.platformName.trim();
    if (n.isNotEmpty) return n;
    final a = r.advertisementData.advName.trim();
    if (a.isNotEmpty) return a;
    return r.device.remoteId.str;
  }

  Future<void> scanNearby({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await _ensureBlePermissions();
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      _scanResultsController.add(results);
    });

    await FlutterBluePlus.startScan(
      timeout: timeout,
      androidUsesFineLocation: true,
    );
  }

  Future<void> connectToScanResult(ScanResult result) async {
    await _ensureBlePermissions();
    await FlutterBluePlus.stopScan();
    _shouldReconnect = true;
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    await _connect(result.device);
  }

  Future<void> _connect(BluetoothDevice device) async {
    _device = device;

    _rxBuffer = '';
    _cancelNotifySubs();
    await _connectionSub?.cancel();

    _log('Connecting to ${device.platformName} (${device.remoteId.str})');

    _connectionSub = device.connectionState.listen((state) {
      final connected = state == BluetoothConnectionState.connected;
      _connectedController.add(connected);

      if (!connected) {
        _log('Disconnected');
        _statusController.add(
          _shouldReconnect
              ? BleConnectionStatus.reconnecting
              : BleConnectionStatus.disconnected,
        );
        _cancelNotifySubs();
        if (_shouldReconnect) {
          _scheduleReconnect();
        }
      } else {
        _log('Connected');
        _statusController.add(BleConnectionStatus.connected);
        _reconnectAttempt = 0;
        _reconnectTimer?.cancel();
      }
    });

    await device.connect(autoConnect: false);
    await device.requestMtu(185);

    final services = await device.discoverServices();
    for (final service in services) {
      if (service.uuid != serviceUuid) continue;

      for (final ch in service.characteristics) {
        if (ch.uuid == sensorDataUuid) {
          await ch.setNotifyValue(true);
          final sub = ch.onValueReceived.listen((bytes) {
            _decodeAndPublish(ch.uuid, bytes);
          });
          _notifySubs.add(sub);

          final current = await ch.read();
          _decodeAndPublish(ch.uuid, current);
        }
      }
    }

    _log('Service/characteristics discovery complete');
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    // Exponential backoff: 1s, 2s, 4s ... max 30s
    final delaySeconds = (1 << _reconnectAttempt).clamp(1, 30);
    _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 10);

    _log('Reconnect scheduled in ${delaySeconds}s');
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      if (!_shouldReconnect) return;
      try {
        await FlutterBluePlus.stopScan();
        await _scanAndAutoConnect(timeout: const Duration(seconds: 10));
      } catch (e) {
        _log('Reconnect scan failed: $e');
        _scheduleReconnect();
      }
    });
  }

  void _decodeAndPublish(Guid uuid, List<int> bytes) {
    if (uuid != sensorDataUuid || bytes.isEmpty) return;

    // Note: payloads are small (~every 3 seconds) so we keep logging minimal.

    try {
      final chunk = utf8.decode(bytes, allowMalformed: true);
      _rxBuffer += chunk.replaceAll('\u0000', '');

      // Preferred: newline-delimited JSON
      while (true) {
        final idx = _rxBuffer.indexOf('\n');
        if (idx < 0) break;
        final line = _rxBuffer.substring(0, idx).trim();
        _rxBuffer = _rxBuffer.substring(idx + 1);
        if (line.isEmpty) continue;
        _handleJsonLine(line);
      }

      // Fallback: single JSON object without newline
      final trimmed = _rxBuffer.trim();
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        _handleJsonLine(trimmed);
        _rxBuffer = '';
      }
    } catch (e) {
      _log('Decode error: $e');
    }
  }

  void _handleJsonLine(String line) {
    try {
      final json = jsonDecode(line) as Map<String, dynamic>;

      // FINAL payload only: {hr, spo2, br, skin_temp}
      final vitals = VitalsData.tryFromJsonMap(json);
      if (vitals == null) {
        _log('Dropping malformed vitals packet: keys=${json.keys.join(',')}');
        return;
      }

      _latest = vitals;
      _vitalsController.add(vitals);
    } catch (e) {
      _log('JSON parse error (dropping line): $e');
    }
  }

  Future<void> stop() async {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    await _connectionSub?.cancel();
    _cancelNotifySubs();
    if (_device != null) {
      await _device!.disconnect();
    }

    _statusController.add(BleConnectionStatus.disconnected);
  }

  void _cancelNotifySubs() {
    for (final sub in _notifySubs) {
      sub.cancel();
    }
    _notifySubs.clear();
  }

  Future<void> dispose() async {
    // Keep controllers open (singleton service reused across screens).
    await stop();
  }
}
