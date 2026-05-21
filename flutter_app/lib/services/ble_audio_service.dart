import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'esp_ble_service.dart';

enum BleAudioStage {
  idle,
  sendingStart,
  streaming,
  completed,
  cancelled,
  error,
}

class BleAudioCaptureUpdate {
  final BleAudioStage stage;
  final double progress; // 0..1 best-effort
  final int bytesReceived;
  final int? expectedBytes;
  final String? message;

  const BleAudioCaptureUpdate({
    required this.stage,
    required this.progress,
    required this.bytesReceived,
    this.expectedBytes,
    this.message,
  });
}

class BleAudioCaptureResult {
  final Uint8List pcm16le;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  const BleAudioCaptureResult({
    required this.pcm16le,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
  });
}

/// BLE audio transport for cry capture.
///
/// BLE command protocol placeholders:
/// - Write UTF-8 command `START_CRY_CAPTURE` to [cryCommandUuid]
/// - ESP32 streams audio to [cryAudioUuid]
///
/// Recommended audio packet format (binary over notify):
/// - Start: 0x01 | u32 sampleRateLE | u8 channels | u8 bitsPerSample | u32 expectedBytesLE
/// - Data:  0x02 | u16 seqLE | payload...
/// - End:   0x03 | u16 lastSeqLE
///
/// This implementation also supports a simpler fallback where the ESP32 sends
/// raw PCM bytes only; completion is then determined by reaching expected bytes
/// (computed from duration) or by inactivity timeout.
class BleAudioService {
  BleAudioService._internal();
  static final BleAudioService instance = BleAudioService._internal();
  factory BleAudioService() => instance;

  /// Command characteristic — write START/STOP commands.
  static final Guid cryCommandUuid = Guid(
    'c8d2f3a1-2b74-4f2e-bab1-3e9fc3e2e567',
  );

  /// Audio characteristic — receives PCM chunks via notify.
  static final Guid cryAudioUuid = Guid(
    'd1e2f3a4-5b6c-7d8e-9f0a-1b2c3d4e5f60',
  );

  // Commands
  static const String startCryCaptureCmd = 'START_CRY_CAPTURE';
  static const String stopCryCaptureCmd = 'STOP_CRY_CAPTURE';

  StreamSubscription<List<int>>? _audioSub;
  BluetoothCharacteristic? _audioCh;
  BluetoothCharacteristic? _cmdCh;

  bool _cancelled = false;

  void _log(String msg) {
    // ignore: avoid_print
    print('[BleAudioService] $msg');
  }

  Future<BleAudioCaptureResult> captureCryAudio({
    Duration duration = const Duration(seconds: 5),
    int expectedSampleRate = 16000,
    int expectedChannels = 1,
    int expectedBitsPerSample = 16,
    void Function(BleAudioCaptureUpdate update)? onUpdate,
  }) async {
    _cancelled = false;

    final device = EspBleService.instance.connectedDevice;
    if (device == null) {
      throw Exception('No connected BLE device');
    }

    onUpdate?.call(
      const BleAudioCaptureUpdate(
        stage: BleAudioStage.sendingStart,
        progress: 0,
        bytesReceived: 0,
        expectedBytes: null,
      ),
    );

    final chars = await _resolveCryCharacteristics(device);
    _cmdCh = chars.$1;
    _audioCh = chars.$2;

    // Subscribe to audio notify first (avoid missing early packets)
    await _audioCh!.setNotifyValue(true);

    final assembler = _BleAudioAssembler(
      fallbackExpectedBytes:
          expectedSampleRate *
          duration.inSeconds *
          (expectedBitsPerSample ~/ 8),
      inactivityTimeout: const Duration(milliseconds: 900),
    );

    final completer = Completer<BleAudioCaptureResult>();

    _audioSub?.cancel();
    _audioSub = _audioCh!.onValueReceived.listen((chunk) {
      if (_cancelled) return;

      final update = assembler.push(chunk);
      if (update != null) {
        onUpdate?.call(update);
      }

      final result = assembler.tryComplete();
      if (result != null && !completer.isCompleted) {
        _log('Audio capture complete: ${result.pcm16le.length} bytes');
        completer.complete(result);
      }
    });

    // Send START command
    final cmdBytes = Uint8List.fromList(startCryCaptureCmd.codeUnits);
    await _cmdCh!.write(cmdBytes, withoutResponse: false);

    // If the ESP32 doesn't send an END packet, assembler will also complete
    // once it reaches expected bytes or after inactivity.
    final result = await completer.future.timeout(
      Duration(seconds: duration.inSeconds + 8),
      onTimeout: () {
        throw TimeoutException('Timed out waiting for audio stream');
      },
    );

    await _cleanupNotify();

    return BleAudioCaptureResult(
      pcm16le: result.pcm16le,
      sampleRate: result.sampleRate,
      channels: result.channels,
      bitsPerSample: result.bitsPerSample,
    );
  }

  Future<void> cancelCapture() async {
    _cancelled = true;

    try {
      final ch = _cmdCh;
      if (ch != null) {
        await ch.write(
          Uint8List.fromList(stopCryCaptureCmd.codeUnits),
          withoutResponse: true,
        );
      }
    } catch (e) {
      _log('Cancel write failed: $e');
    }

    await _cleanupNotify();
  }

  Future<void> _cleanupNotify() async {
    await _audioSub?.cancel();
    _audioSub = null;

    try {
      if (_audioCh != null) {
        await _audioCh!.setNotifyValue(false);
      }
    } catch (_) {
      // ignore
    }

    _audioCh = null;
    _cmdCh = null;
  }

  Future<(BluetoothCharacteristic, BluetoothCharacteristic)>
  _resolveCryCharacteristics(BluetoothDevice device) async {
    final services = await device.discoverServices();
    BluetoothCharacteristic? cmd;
    BluetoothCharacteristic? audio;

    final targetService = EspBleService.serviceUuid.str.toLowerCase();
    final targetCmd = cryCommandUuid.str.toLowerCase();
    final targetAudio = cryAudioUuid.str.toLowerCase();

    _log('Looking for cmd=$targetCmd, audio=$targetAudio in service=$targetService');

    for (final s in services) {
      if (s.uuid.str.toLowerCase() != targetService) continue;
      _log('Found PediaSense service with ${s.characteristics.length} characteristics');
      for (final ch in s.characteristics) {
        final chUuid = ch.uuid.str.toLowerCase();
        _log('  Characteristic: $chUuid');
        if (chUuid == targetCmd) cmd = ch;
        if (chUuid == targetAudio) audio = ch;
      }
    }

    if (cmd == null) {
      throw Exception(
        'Cry command characteristic not found (expected UUID: $targetCmd)',
      );
    }
    if (audio == null) {
      throw Exception(
        'Cry audio characteristic not found (expected UUID: $targetAudio)',
      );
    }

    _log('Resolved cmd=${cmd.uuid.str}, audio=${audio.uuid.str}');
    return (cmd, audio);
  }
}

class _BleAudioAssembler {
  _BleAudioAssembler({
    required this.fallbackExpectedBytes,
    required this.inactivityTimeout,
  });

  final int fallbackExpectedBytes;
  final Duration inactivityTimeout;

  BytesBuilder _buf = BytesBuilder(copy: false);
  int? _expectedBytes;

  int _sampleRate = 16000;
  int _channels = 1;
  int _bitsPerSample = 16;

  int _lastSeq = -1;
  DateTime _lastRx = DateTime.now();
  bool _sawEnd = false;

  BleAudioCaptureUpdate? push(List<int> chunk) {
    _lastRx = DateTime.now();

    if (chunk.isEmpty) return null;

    // ── Text/marker-based framing from ESP32 ──
    // ESP32 sends:
    //   "AUDIO_START"                  → reset buffer
    //   "AUDIO_CHUNK:" + raw PCM bytes → extract PCM after header
    //   "AUDIO_END"                    → mark complete
    //
    // We check for text markers first, but carefully handle
    // AUDIO_CHUNK: which has binary data after the header.

    // Check for pure text markers (AUDIO_START, AUDIO_END)
    // These are short text-only notifications.
    if (chunk.length < 20) {
      try {
        final text = utf8.decode(chunk).trim();
        if (text == 'AUDIO_START') {
          _buf = BytesBuilder(copy: false);
          _expectedBytes = null;
          _lastSeq = -1;
          _sawEnd = false;
          return BleAudioCaptureUpdate(
            stage: BleAudioStage.streaming,
            progress: 0,
            bytesReceived: 0,
            expectedBytes: _expectedBytes,
            message: 'Audio start ($_sampleRate Hz)',
          );
        }
        if (text == 'AUDIO_END') {
          _sawEnd = true;
          return BleAudioCaptureUpdate(
            stage: BleAudioStage.completed,
            progress: 1,
            bytesReceived: _buf.length,
            expectedBytes: _expectedBytes,
            message: 'Audio end',
          );
        }
      } catch (_) {
        // Not valid UTF-8, treat as binary below
      }
    }

    // Check for AUDIO_CHUNK: header (12 bytes) + binary PCM data
    const chunkHeader = 'AUDIO_CHUNK:';
    final headerBytes = utf8.encode(chunkHeader);
    if (chunk.length > headerBytes.length) {
      bool isChunk = true;
      for (int i = 0; i < headerBytes.length && i < chunk.length; i++) {
        if (chunk[i] != headerBytes[i]) { isChunk = false; break; }
      }
      if (isChunk) {
        // Extract PCM data after the header
        final pcmData = chunk.sublist(headerBytes.length);
        if (pcmData.isNotEmpty) {
          _buf.add(Uint8List.fromList(pcmData));
        }
        final exp = _expectedBytes ?? fallbackExpectedBytes;
        final prog = exp > 0 ? (_buf.length / exp).clamp(0.0, 1.0) : 0.0;
        return BleAudioCaptureUpdate(
          stage: BleAudioStage.streaming,
          progress: prog,
          bytesReceived: _buf.length,
          expectedBytes: _expectedBytes,
          message: 'Receiving audio (${_buf.length} bytes)',
        );
      }
    }

    // Binary framed packets
    final type = chunk[0];
    if (type == 0x01 && chunk.length >= 1 + 4 + 1 + 1 + 4) {
      final b = Uint8List.fromList(chunk);
      _sampleRate = b.buffer.asByteData().getUint32(1, Endian.little);
      _channels = b[5];
      _bitsPerSample = b[6];
      _expectedBytes = b.buffer.asByteData().getUint32(7, Endian.little);
      return BleAudioCaptureUpdate(
        stage: BleAudioStage.streaming,
        progress: 0,
        bytesReceived: _buf.length,
        expectedBytes: _expectedBytes,
        message: 'Audio start ($_sampleRate Hz)',
      );
    }

    if (type == 0x02 && chunk.length >= 1 + 2) {
      final b = Uint8List.fromList(chunk);
      final seq = b.buffer.asByteData().getUint16(1, Endian.little);
      if (_lastSeq != -1 && seq != _lastSeq + 1) {
        // ignore: avoid_print
        print('[BleAudioService] Packet gap: last=$_lastSeq now=$seq');
      }
      _lastSeq = seq;
      _buf.add(b.sublist(3));

      final exp = _expectedBytes ?? fallbackExpectedBytes;
      final prog = exp > 0 ? (_buf.length / exp).clamp(0.0, 1.0) : 0.0;
      return BleAudioCaptureUpdate(
        stage: BleAudioStage.streaming,
        progress: prog,
        bytesReceived: _buf.length,
        expectedBytes: _expectedBytes,
      );
    }

    if (type == 0x03) {
      _sawEnd = true;
      return BleAudioCaptureUpdate(
        stage: BleAudioStage.completed,
        progress: 1,
        bytesReceived: _buf.length,
        expectedBytes: _expectedBytes,
        message: 'Audio end',
      );
    }

    // Fallback: treat whole chunk as PCM bytes
    _buf.add(Uint8List.fromList(chunk));
    final exp = _expectedBytes ?? fallbackExpectedBytes;
    final prog = exp > 0 ? (_buf.length / exp).clamp(0.0, 1.0) : 0.0;
    return BleAudioCaptureUpdate(
      stage: BleAudioStage.streaming,
      progress: prog,
      bytesReceived: _buf.length,
      expectedBytes: _expectedBytes,
    );
  }

  BleAudioCaptureResult? tryComplete() {
    if (_sawEnd) {
      return BleAudioCaptureResult(
        pcm16le: _buf.toBytes(),
        sampleRate: _sampleRate,
        channels: _channels,
        bitsPerSample: _bitsPerSample,
      );
    }

    final exp = _expectedBytes ?? fallbackExpectedBytes;
    if (exp > 0 && _buf.length >= exp) {
      return BleAudioCaptureResult(
        pcm16le: _buf.toBytes(),
        sampleRate: _sampleRate,
        channels: _channels,
        bitsPerSample: _bitsPerSample,
      );
    }

    // Inactivity-based completion (useful if ESP32 just stops notifying)
    if (DateTime.now().difference(_lastRx) > inactivityTimeout &&
        _buf.length > 0) {
      return BleAudioCaptureResult(
        pcm16le: _buf.toBytes(),
        sampleRate: _sampleRate,
        channels: _channels,
        bitsPerSample: _bitsPerSample,
      );
    }

    return null;
  }
}
