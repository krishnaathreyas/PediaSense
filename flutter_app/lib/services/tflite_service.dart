import 'dart:math' as math;
import 'dart:typed_data';

import '../models/cry_prediction.dart';

/// Placeholder-ready TFLite integration.
///
/// Future model path (Flutter asset):
///   assets/models/baby_cry_model.tflite
///
/// Expected input:
///   log-mel spectrogram tensor (normalized), typically shaped:
///   [1, H, W, 1]
///
/// Output (expected):
///   [1, 4] probabilities for:
///     hungry, pain, sleepy, normal
///
/// For now, this service uses a deterministic mock inference so the full
/// architecture and UI flow are production-shaped even before the model exists.
class TfliteService {
  TfliteService._internal();
  static final TfliteService instance = TfliteService._internal();
  factory TfliteService() => instance;

  static const String modelAssetPath = 'assets/models/baby_cry_model.tflite';

  void _log(String msg) {
    // ignore: avoid_print
    print('[TfliteService] $msg');
  }

  Future<void> ensureLoaded() async {
    // TODO: Replace with real interpreter loading when model is available.
    // e.g. tflite_flutter Interpreter.fromAsset(modelAssetPath)
    _log('ensureLoaded(): using mock (model not yet integrated)');
  }

  Future<CryPrediction> predictCry({
    required Float32List normalizedLogMel,
    required int height,
    required int width,
  }) async {
    // Mock: use simple statistics to generate stable output.
    // - Higher overall energy => more likely pain/hungry
    // - Lower energy => sleepy/normal
    double absMean = 0;
    for (final v in normalizedLogMel) {
      absMean += v.abs();
    }
    absMean /= math.max(1, normalizedLogMel.length);

    // Map to pseudo-probabilities
    final pHungry = (0.25 + 0.35 * _sigmoid(absMean - 0.25)).clamp(0.05, 0.85);
    final pPain = (0.20 + 0.45 * _sigmoid(absMean - 0.45)).clamp(0.05, 0.9);
    final pSleepy = (0.25 + 0.35 * _sigmoid(0.35 - absMean)).clamp(0.05, 0.85);
    final pNormal = (0.20 + 0.40 * _sigmoid(0.15 - absMean)).clamp(0.05, 0.9);

    final probs = [pHungry, pPain, pSleepy, pNormal];
    final sum = probs.reduce((a, b) => a + b);
    final norm = probs.map((p) => p / sum).toList();

    int argMax = 0;
    for (int i = 1; i < norm.length; i++) {
      if (norm[i] > norm[argMax]) argMax = i;
    }

    final type = switch (argMax) {
      0 => CryType.hungry,
      1 => CryType.pain,
      2 => CryType.sleepy,
      _ => CryType.normal,
    };

    return CryPrediction(
      type: type,
      confidence: norm[argMax].clamp(0.0, 1.0),
      predictedAt: DateTime.now(),
    );
  }

  double _sigmoid(double x) {
    return 1.0 / (1.0 + math.exp(-6.0 * x));
  }
}
