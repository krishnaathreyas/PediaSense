import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/vitals_data.dart';

class EspBleService {
  EspBleService._internal();
  static final EspBleService instance = EspBleService._internal();
  factory EspBleService() => instance;

  static final Guid serviceUuid = Guid('12345678-1234-1234-1234-1234567890ab');
  static final Guid dataUuid = Guid('abcd1234-5678-1234-5678-abcdef123456');

  final _vitalsController = StreamController<VitalsData>.broadcast();
  final _connectedController = StreamController<bool>.broadcast();
  final _scanResultsController = StreamController<List<ScanResult>>.broadcast();

  Stream<VitalsData> get vitalsStream => _vitalsController.stream;
  Stream<bool> get connectedStream => _connectedController.stream;
  Stream<List<ScanResult>> get scanResultsStream =>
      _scanResultsController.stream;

  VitalsData _latest = VitalsData(
    spo2: 0,
    heartRate: 0,
    breathingRate: 0,
    skinTemp: 0,
    urineGap: 2.5,
    wetDiaperCount: 6,
    riskLevel: RiskLevel.normal,
  );

  BluetoothDevice? _device;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  final List<StreamSubscription<List<int>>> _notifySubs = [];
  Timer? _publishTimer;

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
    await _ensureBlePermissions();
    await FlutterBluePlus.stopScan();

    _publishTimer?.cancel();
    _publishTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _vitalsController.add(_latest);
    });

    _scanSub = FlutterBluePlus.scanResults.listen((results) async {
      _scanResultsController.add(results);
      for (final result in results) {
        final hasService = result.advertisementData.serviceUuids.contains(
          serviceUuid,
        );
        final deviceName = result.device.platformName.toLowerCase();
        final localName = result.advertisementData.advName.toLowerCase();
        final looksLikePediaSense =
            deviceName.contains('pediasense') ||
            localName.contains('pediasense');

        if (hasService || looksLikePediaSense) {
          await FlutterBluePlus.stopScan();
          await _connect(result.device);
          return;
        }
      }
    });

    await FlutterBluePlus.startScan(
      withServices: [serviceUuid],
      timeout: const Duration(seconds: 12),
      androidUsesFineLocation: true,
    );
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
    await _connect(result.device);
  }

  Future<void> _connect(BluetoothDevice device) async {
    _device = device;

    _connectionSub = device.connectionState.listen((state) {
      final connected = state == BluetoothConnectionState.connected;
      _connectedController.add(connected);

      if (!connected) {
        _cancelNotifySubs();
      }
    });

    await device.connect(autoConnect: false);
    await device.requestMtu(185);

    final services = await device.discoverServices();
    for (final service in services) {
      if (service.uuid != serviceUuid) continue;

      for (final ch in service.characteristics) {
        if (ch.uuid == dataUuid) {
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
  }

  void _decodeAndPublish(Guid uuid, List<int> bytes) {
    if (uuid != dataUuid || bytes.isEmpty) return;

    try {
      final text = utf8
          .decode(bytes, allowMalformed: true)
          .replaceAll('\u0000', '')
          .trim();
      if (text.isEmpty) return;
      final json = jsonDecode(text) as Map<String, dynamic>;

      final hr = (json['hr'] as num?)?.toDouble() ?? _latest.heartRate;
      final spo2 = (json['spo2'] as num?)?.toDouble() ?? _latest.spo2;
      final br = (json['br'] as num?)?.toDouble() ?? _latest.breathingRate;
      final skinTemp = (json['temp'] as num?)?.toDouble() ?? _latest.skinTemp;

      final risk = (spo2 < 92 || hr > 155 || br > 50)
          ? RiskLevel.urgent
          : (spo2 < 95 || hr > 140 || br > 38)
          ? RiskLevel.monitor
          : RiskLevel.normal;

      _latest = _latest.copyWith(
        heartRate: hr,
        spo2: spo2,
        breathingRate: br,
        skinTemp: skinTemp,
        riskLevel: risk,
      );

      // Push immediately on new valid sample (timer remains as a safety net).
      _vitalsController.add(_latest);
    } catch (_) {
      // Ignore malformed packets and keep last valid sample.
    }
  }

  Future<void> stop() async {
    await FlutterBluePlus.stopScan();
    _publishTimer?.cancel();
    _publishTimer = null;
    await _scanSub?.cancel();
    await _connectionSub?.cancel();
    _cancelNotifySubs();
    if (_device != null) {
      await _device!.disconnect();
    }
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
