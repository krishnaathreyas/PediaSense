import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/vitals_data.dart';

class EspBleService {
  static final Guid serviceUuid = Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');
  static final Guid vitalUuid = Guid('bebe0001-1fb5-459e-8fcc-c5c9c331914b');
  static final Guid motionUuid = Guid('bebe0002-1fb5-459e-8fcc-c5c9c331914b');
  static final Guid audioUuid = Guid('bebe0003-1fb5-459e-8fcc-c5c9c331914b');
  static final Guid riskUuid = Guid('bebe0004-1fb5-459e-8fcc-c5c9c331914b');

  final _vitalsController = StreamController<VitalsData>.broadcast();
  final _connectedController = StreamController<bool>.broadcast();

  Stream<VitalsData> get vitalsStream => _vitalsController.stream;
  Stream<bool> get connectedStream => _connectedController.stream;

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

  Future<void> start() async {
    await FlutterBluePlus.stopScan();

    _scanSub = FlutterBluePlus.scanResults.listen((results) async {
      for (final result in results) {
        final hasService =
          result.advertisementData.serviceUuids.contains(serviceUuid);
        final looksLikePediaSense = result.device.platformName
            .toLowerCase()
            .contains('pediasense');

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
        if (ch.uuid == vitalUuid ||
            ch.uuid == motionUuid ||
            ch.uuid == audioUuid ||
            ch.uuid == riskUuid) {
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
    if (bytes.length < 4) return;

    if (uuid == vitalUuid) {
      final hr = bytes[0].toDouble();
      final spo2 = bytes[1].toDouble();
      final tempRaw = ByteData.sublistView(
        Uint8List.fromList(bytes),
        2,
        4,
      ).getInt16(0, Endian.little);
      final skinTemp = tempRaw / 100.0;

      _latest = _latest.copyWith(heartRate: hr, spo2: spo2, skinTemp: skinTemp);
    } else if (uuid == motionUuid) {
      final breathingRate = bytes[2].toDouble();
      _latest = _latest.copyWith(breathingRate: breathingRate);
    } else if (uuid == riskUuid) {
      final level = bytes[0];
      final risk = switch (level) {
        0 => RiskLevel.normal,
        1 => RiskLevel.monitor,
        _ => RiskLevel.urgent,
      };
      _latest = _latest.copyWith(riskLevel: risk);
    }

    _vitalsController.add(_latest);
  }

  Future<void> stop() async {
    await FlutterBluePlus.stopScan();
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
    await stop();
    await _vitalsController.close();
    await _connectedController.close();
  }
}
