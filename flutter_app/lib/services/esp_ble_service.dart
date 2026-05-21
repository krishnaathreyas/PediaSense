import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
  //  BLE UUIDs (MUST match ESP32 firmware exactly)
  // ──────────────────────────────────────────────────────────────────────────
  /// The primary GATT service that exposes sensor data.
  static final Guid serviceUuid = Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');

  /// Characteristic that streams JSON sensor samples via notify.
  static final Guid sensorDataUuid = Guid(
    'beb5483e-36e1-4688-b7f5-ea07361b26a8',
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
    // Always print BLE debug logs for troubleshooting
    debugPrint('[EspBleService] $msg');
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
    _log('BLE permissions granted');
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

  // ════════════════════════════════════════════════════════════════════════════
  //  CONNECT + SERVICE DISCOVERY (core BLE handshake)
  // ════════════════════════════════════════════════════════════════════════════

  Future<void> _connect(BluetoothDevice device) async {
    _device = device;
    _rxBuffer = '';
    _cancelNotifySubs();
    await _connectionSub?.cancel();

    _log('╔══════════════════════════════════════════════════╗');
    _log('║  CONNECTING to ${device.platformName} (${device.remoteId.str})');
    _log('╚══════════════════════════════════════════════════╝');

    // Listen for connection state changes
    _connectionSub = device.connectionState.listen((state) {
      final connected = state == BluetoothConnectionState.connected;
      _connectedController.add(connected);

      if (!connected) {
        _log('⚡ Disconnected from ${device.platformName}');
        _statusController.add(
          _shouldReconnect
              ? BleConnectionStatus.reconnecting
              : BleConnectionStatus.disconnected,
        );
        _cancelNotifySubs();
        if (_shouldReconnect) {
          _scheduleReconnect();
        }
      }
    });

    // ── Step 1: Connect ──
    _log('Step 1: Calling device.connect()...');
    await device.connect(autoConnect: false, timeout: const Duration(seconds: 15));
    _log('Step 1: ✅ connect() completed');

    // ── Step 2: Request MTU ──
    _log('Step 2: Requesting MTU 185...');
    try {
      final mtu = await device.requestMtu(185);
      _log('Step 2: ✅ MTU negotiated: $mtu');
    } catch (e) {
      _log('Step 2: ⚠️ MTU request failed (non-fatal): $e');
    }

    // ── Step 3: Post-connect delay ──
    // ESP32 BLE stack needs time to stabilise after connection
    _log('Step 3: Waiting 1500ms for ESP32 BLE stack to stabilise...');
    await Future.delayed(const Duration(milliseconds: 1500));

    // ── Step 4: Discover services ──
    _log('Step 4: Discovering services...');
    List<BluetoothService> services;
    try {
      services = await device.discoverServices();
    } catch (e) {
      _log('Step 4: ⚠️ First discovery attempt failed: $e — retrying in 1s');
      await Future.delayed(const Duration(seconds: 1));
      services = await device.discoverServices();
    }

    _log('Step 4: ✅ Found ${services.length} service(s)');

    // ── Step 5: Log ALL discovered services and characteristics ──
    _log('┌─────────────────────────────────────────────────');
    _log('│ DISCOVERED SERVICES');
    _log('├─────────────────────────────────────────────────');
    for (final service in services) {
      _log('│ Service: ${service.uuid.str}');
      for (final ch in service.characteristics) {
        final props = <String>[];
        if (ch.properties.read) props.add('READ');
        if (ch.properties.write) props.add('WRITE');
        if (ch.properties.notify) props.add('NOTIFY');
        if (ch.properties.indicate) props.add('INDICATE');
        _log('│   └─ Char: ${ch.uuid.str}  [${props.join(', ')}]');
      }
    }
    _log('└─────────────────────────────────────────────────');

    // ── Step 6: Find our target service and characteristic ──
    BluetoothCharacteristic? vitalsChar;

    final targetServiceStr = serviceUuid.str.toLowerCase();
    final targetCharStr = sensorDataUuid.str.toLowerCase();

    _log('Step 6: Looking for service=$targetServiceStr, char=$targetCharStr');

    for (final service in services) {
      if (service.uuid.str.toLowerCase() == targetServiceStr) {
        _log('Step 6: ✅ Found PediaSense service!');
        for (final ch in service.characteristics) {
          if (ch.uuid.str.toLowerCase() == targetCharStr) {
            _log('Step 6: ✅ Found vitals characteristic!');
            vitalsChar = ch;
            break;
          }
        }
        break;
      }
    }

    if (vitalsChar == null) {
      _log('Step 6: ❌ VITALS CHARACTERISTIC NOT FOUND!');
      _log('  Expected service UUID:  $targetServiceStr');
      _log('  Expected char UUID:     $targetCharStr');
      _log('  This means ESP32 is not exposing the expected GATT profile.');
      // Still mark as connected so user can see the issue
      _statusController.add(BleConnectionStatus.connected);
      _reconnectAttempt = 0;
      _reconnectTimer?.cancel();
      return;
    }

    // ── Step 7: Enable notifications ──
    _log('Step 7: Enabling notifications on vitals characteristic...');
    try {
      await vitalsChar.setNotifyValue(true);
      _log('Step 7: ✅ setNotifyValue(true) succeeded');
    } catch (e) {
      _log('Step 7: ❌ setNotifyValue FAILED: $e');
      _log('  Retrying after 500ms...');
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        await vitalsChar.setNotifyValue(true);
        _log('Step 7: ✅ setNotifyValue(true) succeeded on retry');
      } catch (e2) {
        _log('Step 7: ❌❌ setNotifyValue FAILED on retry: $e2');
        _statusController.add(BleConnectionStatus.connected);
        return;
      }
    }

    // ── Step 8: Subscribe to value stream ──
    _log('Step 8: Subscribing to onValueReceived stream...');
    final sub = vitalsChar.onValueReceived.listen((bytes) {
      _log('📥 RAW BYTES received: length=${bytes.length}, bytes=$bytes');
      _decodeAndPublish(vitalsChar!.uuid, bytes);
    });
    _notifySubs.add(sub);
    _log('Step 8: ✅ Subscription active');

    // ── Step 9: Try initial read (optional — may not be supported) ──
    if (vitalsChar.properties.read) {
      _log('Step 9: Attempting initial read()...');
      try {
        final current = await vitalsChar.read();
        _log('Step 9: ✅ Initial read: $current');
        if (current.isNotEmpty) {
          _decodeAndPublish(vitalsChar.uuid, current);
        }
      } catch (e) {
        _log('Step 9: ⚠️ Initial read failed (non-fatal): $e');
      }
    } else {
      _log('Step 9: Skipping read — characteristic does not support READ');
    }

    // ── Done ──
    _statusController.add(BleConnectionStatus.connected);
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    _log('════════════════════════════════════════════════════');
    _log('  BLE SETUP COMPLETE — waiting for notifications');
    _log('════════════════════════════════════════════════════');
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

  // ════════════════════════════════════════════════════════════════════════════
  //  DECODE + PUBLISH (BLE bytes → VitalsData)
  // ════════════════════════════════════════════════════════════════════════════

  void _decodeAndPublish(Guid uuid, List<int> bytes) {
    if (bytes.isEmpty) {
      _log('⚠️ Empty bytes received — skipping');
      return;
    }

    try {
      // Decode raw bytes to UTF-8 string
      final chunk = utf8.decode(bytes, allowMalformed: true);
      _log('📝 Decoded UTF-8: "$chunk"');

      // Append to buffer (handle partial packets)
      _rxBuffer += chunk.replaceAll('\u0000', '');

      // ── Strategy 1: Newline-delimited JSON ──
      while (true) {
        final idx = _rxBuffer.indexOf('\n');
        if (idx < 0) break;
        final line = _rxBuffer.substring(0, idx).trim();
        _rxBuffer = _rxBuffer.substring(idx + 1);
        if (line.isEmpty) continue;
        _handleJsonLine(line);
      }

      // ── Strategy 2: Single JSON object without newline ──
      final trimmed = _rxBuffer.trim();
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        _handleJsonLine(trimmed);
        _rxBuffer = '';
      }
    } catch (e) {
      _log('❌ Decode error: $e');
    }
  }

  void _handleJsonLine(String line) {
    _log('🔍 Parsing JSON line: "$line"');

    try {
      final json = jsonDecode(line) as Map<String, dynamic>;
      _log('✅ JSON parsed: keys=${json.keys.toList()}, values=$json');

      // Parse into VitalsData
      final vitals = VitalsData.tryFromJsonMap(json);
      if (vitals == null) {
        _log('⚠️ VitalsData.tryFromJsonMap returned null — packet dropped');
        _log('  hr=${json['hr']} (${json['hr'].runtimeType})');
        _log('  spo2=${json['spo2']} (${json['spo2'].runtimeType})');
        _log('  br=${json['br']} (${json['br'].runtimeType})');
        _log('  skin_temp=${json['skin_temp']} (${json['skin_temp'].runtimeType})');
        return;
      }

      _log('✅ VitalsData: hr=${vitals.hr}, spo2=${vitals.spo2}, '
          'br=${vitals.br}, skinTemp=${vitals.skinTemp}');

      _latest = vitals;
      _vitalsController.add(vitals);
      _log('✅ Published to vitalsStream');
    } catch (e) {
      _log('❌ JSON parse error (dropping line): $e');
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
      try {
        await _device!.disconnect();
      } catch (_) {}
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
