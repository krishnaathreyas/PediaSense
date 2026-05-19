import 'dart:async';
import '../models/cry_prediction.dart';
import 'audio_preprocessing_service.dart';
import 'ble_audio_service.dart';
import 'tflite_service.dart';

enum CryDetectionStage {
  idle,
  requestingCapture,
  capturing,
  transferring,
  preprocessing,
  inferring,
  completed,
  cancelled,
  error,
}

class CryDetectionUpdate {
  final CryDetectionStage stage;
  final double progress; // 0..1 best-effort
  final int? secondsRemaining;
  final CryPrediction? prediction;
  final String? message;

  const CryDetectionUpdate({
    required this.stage,
    this.progress = 0,
    this.secondsRemaining,
    this.prediction,
    this.message,
  });
}

class CryDetectionService {
  CryDetectionService._internal();
  static final CryDetectionService instance = CryDetectionService._internal();
  factory CryDetectionService() => instance;

  final BleAudioService _bleAudio = BleAudioService.instance;
  final AudioPreprocessingService _pre = AudioPreprocessingService.instance;
  final TfliteService _tflite = TfliteService.instance;

  void _log(String msg) {
    // ignore: avoid_print
    print('[CryDetectionService] $msg');
  }

  /// Starts a full cry-detection run.
  ///
  /// This returns a stream of updates so the Dashboard can render:
  /// listening -> processing -> result.
  Stream<CryDetectionUpdate> startCryDetection({
    Duration captureDuration = const Duration(seconds: 5),
    int modelH = 128,
    int modelW = 128,
  }) {
    final controller = StreamController<CryDetectionUpdate>();

    () async {
      try {
        controller.add(
          const CryDetectionUpdate(
            stage: CryDetectionStage.requestingCapture,
            message: 'Sending START_CRY_CAPTURE...',
          ),
        );

        controller.add(
          CryDetectionUpdate(
            stage: CryDetectionStage.capturing,
            progress: 0,
            secondsRemaining: captureDuration.inSeconds,
            message: 'Listening...',
          ),
        );

        // Capture audio via BLE
        final captureStart = DateTime.now();
        final audio = await _bleAudio.captureCryAudio(
          duration: captureDuration,
          expectedSampleRate: 16000,
          expectedChannels: 1,
          expectedBitsPerSample: 16,
          onUpdate: (u) {
            final elapsed = DateTime.now().difference(captureStart);
            final secondsLeft = (captureDuration.inSeconds - elapsed.inSeconds)
                .clamp(0, 999);

            controller.add(
              CryDetectionUpdate(
                stage: CryDetectionStage.capturing,
                progress: u.progress,
                secondsRemaining: secondsLeft,
                message: u.message ?? 'Listening...',
              ),
            );
          },
        );

        controller.add(
          const CryDetectionUpdate(
            stage: CryDetectionStage.preprocessing,
            progress: 0,
            message: 'Generating Mel spectrogram...',
          ),
        );

        final cfg = MelSpectrogramConfig(
          sampleRate: audio.sampleRate,
          nFft: 512,
          winLength: 400,
          hopLength: 160,
          nMels: 64,
          fMin: 50,
          fMax: audio.sampleRate / 2,
        );

        final tensor = _pre.pcmToLogMelTensor(
          audio.pcm16le,
          cfg: cfg,
          outH: modelH,
          outW: modelW,
        );

        controller.add(
          const CryDetectionUpdate(
            stage: CryDetectionStage.inferring,
            progress: 0.8,
            message: 'Running on-device model...',
          ),
        );

        await _tflite.ensureLoaded();
        final pred = await _tflite.predictCry(
          normalizedLogMel: tensor,
          height: modelH,
          width: modelW,
        );

        controller.add(
          CryDetectionUpdate(
            stage: CryDetectionStage.completed,
            progress: 1,
            prediction: pred,
            message: 'Done',
          ),
        );
        await controller.close();
      } catch (e) {
        _log('Error: $e');
        controller.add(
          CryDetectionUpdate(
            stage: CryDetectionStage.error,
            progress: 0,
            message: e.toString(),
          ),
        );
        await controller.close();
      }
    }();
    return controller.stream;
  }

  Future<void> cancel() async {
    await _bleAudio.cancelCapture();
  }
}
