import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/cry_prediction.dart';

/// Real TFLite inference service for baby cry classification.
///
/// Model:
///   Place your .tflite file at:
///     flutter_app/assets/models/baby_cry_model.tflite
///
/// Expected input shape:
///   [1, H, W, 1]  — single-channel log-mel spectrogram
///
/// Expected output shape:
///   [1, N]  — probabilities for each cry class
///
/// Class mapping (configurable via [classLabels]):
///   Index 0 → hungry
///   Index 1 → pain
///   Index 2 → sleepy
///   Index 3 → normal
///
/// If your model has a different class order, update [classLabels].
class TfliteService {
  TfliteService._internal();
  static final TfliteService instance = TfliteService._internal();
  factory TfliteService() => instance;

  static const String modelAssetPath = 'assets/models/baby_cry_model.tflite';

  /// Map output indices to CryType.
  /// UPDATE THIS if your model's class order differs.
  static const List<CryType> classLabels = [
    CryType.hungry,  // index 0
    CryType.pain,    // index 1
    CryType.sleepy,  // index 2
    CryType.normal,  // index 3
  ];

  Interpreter? _interpreter;
  bool _isLoading = false;

  /// Input tensor shape, read from the model after loading.
  List<int>? _inputShape;
  /// Output tensor shape.
  List<int>? _outputShape;

  void _log(String msg) {
    // ignore: avoid_print
    print('[TfliteService] $msg');
  }

  /// Loads the interpreter from the bundled asset.
  /// Safe to call multiple times — only loads once.
  Future<void> ensureLoaded() async {
    if (_interpreter != null) return;
    if (_isLoading) {
      // Wait for the other load to complete
      while (_isLoading) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return;
    }

    _isLoading = true;
    try {
      _log('Loading model from $modelAssetPath...');

      _interpreter = await Interpreter.fromAsset(modelAssetPath);

      // Read tensor shapes
      _inputShape = _interpreter!.getInputTensor(0).shape;
      _outputShape = _interpreter!.getOutputTensor(0).shape;

      _log('Model loaded successfully.');
      _log('  Input shape:  $_inputShape');
      _log('  Output shape: $_outputShape');
      _log('  Class count:  ${_outputShape!.last}');
    } catch (e) {
      _log('ERROR loading model: $e');
      _interpreter = null;
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// Run inference on a normalized log-mel spectrogram tensor.
  ///
  /// [normalizedLogMel] must be a flattened Float32List of shape [height * width].
  /// It will be reshaped to [1, height, width, 1] for the model.
  Future<CryPrediction> predictCry({
    required Float32List normalizedLogMel,
    required int height,
    required int width,
  }) async {
    await ensureLoaded();

    if (_interpreter == null) {
      throw Exception('TFLite model failed to load — cannot run inference');
    }

    // ── Reshape input to [1, H, W, 1] ──
    final input = _reshapeInput(normalizedLogMel, height, width);

    // ── Prepare output buffer ──
    final numClasses = _outputShape!.last;
    final output = List.generate(1, (_) => List<double>.filled(numClasses, 0));

    _log('Running inference (input: [1, $height, $width, 1], classes: $numClasses)...');
    final stopwatch = Stopwatch()..start();

    // ── Run ──
    _interpreter!.run(input, output);

    stopwatch.stop();
    _log('Inference completed in ${stopwatch.elapsedMilliseconds} ms');

    // ── Parse output ──
    final probs = output[0];
    _log('Raw output: $probs');

    // Apply softmax if outputs don't sum to ~1 (some models output logits)
    final probabilities = _maybeSoftmax(probs);

    // Find argmax
    int argMax = 0;
    for (int i = 1; i < probabilities.length; i++) {
      if (probabilities[i] > probabilities[argMax]) {
        argMax = i;
      }
    }

    // Map to CryType
    final CryType type;
    if (argMax < classLabels.length) {
      type = classLabels[argMax];
    } else {
      _log('WARNING: Model output index $argMax exceeds classLabels length ${classLabels.length}');
      type = CryType.unknown;
    }

    final confidence = probabilities[argMax].clamp(0.0, 1.0);

    _log('Prediction: ${type.name} (confidence: ${(confidence * 100).toStringAsFixed(1)}%)');

    return CryPrediction(
      type: type,
      confidence: confidence,
      predictedAt: DateTime.now(),
    );
  }

  /// Reshapes a flat [H*W] tensor into [1][H][W][1] for TFLite.
  List<List<List<List<double>>>> _reshapeInput(
    Float32List flat,
    int height,
    int width,
  ) {
    assert(flat.length == height * width,
        'Tensor length ${flat.length} != $height * $width');

    return List.generate(1, (_) {
      return List.generate(height, (y) {
        return List.generate(width, (x) {
          return [flat[y * width + x].toDouble()];
        });
      });
    });
  }

  /// Applies softmax if the values don't already sum to approximately 1.
  List<double> _maybeSoftmax(List<double> logits) {
    double sum = 0;
    for (final v in logits) {
      sum += v;
    }

    // If already normalized (sum ≈ 1), return as-is
    if ((sum - 1.0).abs() < 0.1 && logits.every((v) => v >= 0)) {
      return logits;
    }

    // Apply softmax
    final maxVal = logits.reduce((a, b) => a > b ? a : b);
    final exps = logits.map((v) => math.exp(v - maxVal)).toList();
    final expSum = exps.reduce((a, b) => a + b);
    return exps.map((v) => v / expSum).toList();
  }

  /// Disposes the interpreter and frees resources.
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _log('Interpreter disposed.');
  }
}
