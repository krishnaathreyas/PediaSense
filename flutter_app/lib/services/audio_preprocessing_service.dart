import 'dart:math' as math;
import 'dart:typed_data';

class MelSpectrogramConfig {
  final int sampleRate;
  final int nFft;
  final int winLength;
  final int hopLength;
  final int nMels;
  final double fMin;
  final double fMax;

  const MelSpectrogramConfig({
    required this.sampleRate,
    this.nFft = 512,
    this.winLength = 400, // 25ms @ 16k
    this.hopLength = 160, // 10ms @ 16k
    this.nMels = 64,
    this.fMin = 50,
    double? fMax,
  }) : fMax = fMax ?? (sampleRate / 2);
}

/// Preprocessing pipeline placeholder-ready but fully functional:
/// PCM16 -> float -> STFT -> Mel filterbank -> log-mel -> resize -> normalize -> tensor
class AudioPreprocessingService {
  AudioPreprocessingService._internal();
  static final AudioPreprocessingService instance =
      AudioPreprocessingService._internal();
  factory AudioPreprocessingService() => instance;

  Float32List pcm16leToFloat32(Uint8List pcm16le) {
    final bd = ByteData.sublistView(pcm16le);
    final out = Float32List(pcm16le.length ~/ 2);
    for (int i = 0; i < out.length; i++) {
      final v = bd.getInt16(i * 2, Endian.little);
      out[i] = (v / 32768.0).clamp(-1.0, 1.0);
    }
    return out;
  }

  /// Returns power spectrogram [frames][(nFft/2)+1]
  List<List<double>> stftPower(Float32List audio, MelSpectrogramConfig cfg) {
    final window = _hann(cfg.winLength);

    final frames = ((audio.length - cfg.winLength) / cfg.hopLength).floor() + 1;
    final nFreq = (cfg.nFft ~/ 2) + 1;

    final spec = List.generate(frames, (_) => List<double>.filled(nFreq, 0));

    for (int frame = 0; frame < frames; frame++) {
      final start = frame * cfg.hopLength;
      final re = Float64List(cfg.nFft);
      final im = Float64List(cfg.nFft);

      for (int i = 0; i < cfg.winLength; i++) {
        final s = audio[start + i];
        re[i] = s * window[i];
      }

      _fftRadix2(re, im);

      for (int k = 0; k < nFreq; k++) {
        final p = re[k] * re[k] + im[k] * im[k];
        spec[frame][k] = p;
      }
    }

    return spec;
  }

  List<List<double>> melSpectrogram(
    Float32List audio,
    MelSpectrogramConfig cfg,
  ) {
    final power = stftPower(audio, cfg);
    final fb = _melFilterbank(cfg);

    final frames = power.length;
    final nMels = cfg.nMels;
    final mel = List.generate(frames, (_) => List<double>.filled(nMels, 0));

    for (int t = 0; t < frames; t++) {
      for (int m = 0; m < nMels; m++) {
        double sum = 0;
        final f = fb[m];
        for (int k = 0; k < f.length; k++) {
          sum += power[t][k] * f[k];
        }
        mel[t][m] = sum;
      }
    }

    return mel;
  }

  List<List<double>> logMelSpectrogram(
    Float32List audio,
    MelSpectrogramConfig cfg, {
    double eps = 1e-10,
  }) {
    final mel = melSpectrogram(audio, cfg);
    for (int t = 0; t < mel.length; t++) {
      for (int m = 0; m < mel[t].length; m++) {
        mel[t][m] = math.log(mel[t][m] + eps);
      }
    }
    return mel;
  }

  /// Bilinear resize for a 2D matrix shaped [T][M] to [outH][outW].
  List<List<double>> resize2d(List<List<double>> input, int outH, int outW) {
    final inH = input.length;
    final inW = input.isEmpty ? 0 : input[0].length;
    if (inH == 0 || inW == 0) {
      return List.generate(outH, (_) => List<double>.filled(outW, 0));
    }

    final out = List.generate(outH, (_) => List<double>.filled(outW, 0));

    for (int y = 0; y < outH; y++) {
      final gy = (y * (inH - 1)) / math.max(1, outH - 1);
      final y0 = gy.floor();
      final y1 = math.min(inH - 1, y0 + 1);
      final wy = gy - y0;

      for (int x = 0; x < outW; x++) {
        final gx = (x * (inW - 1)) / math.max(1, outW - 1);
        final x0 = gx.floor();
        final x1 = math.min(inW - 1, x0 + 1);
        final wx = gx - x0;

        final v00 = input[y0][x0];
        final v01 = input[y0][x1];
        final v10 = input[y1][x0];
        final v11 = input[y1][x1];

        final v0 = v00 * (1 - wx) + v01 * wx;
        final v1 = v10 * (1 - wx) + v11 * wx;
        out[y][x] = v0 * (1 - wy) + v1 * wy;
      }
    }

    return out;
  }

  /// Normalize to mean 0 / std 1 (stable for TFLite models).
  Float32List normalizeToTensor(List<List<double>> input, int outH, int outW) {
    final flat = Float32List(outH * outW);
    double sum = 0;
    double sumSq = 0;
    int idx = 0;

    for (int y = 0; y < outH; y++) {
      for (int x = 0; x < outW; x++) {
        final v = input[y][x];
        flat[idx++] = v.toDouble();
        sum += v;
        sumSq += v * v;
      }
    }

    final n = (outH * outW).toDouble();
    final mean = sum / n;
    final var_ = (sumSq / n) - (mean * mean);
    final std = math.sqrt(math.max(var_, 1e-12));

    for (int i = 0; i < flat.length; i++) {
      flat[i] = ((flat[i] - mean) / std).toDouble();
    }

    return flat;
  }

  /// Full pipeline convenience.
  /// Returns a grayscale tensor flattened [outH*outW] (add batch/channel in TFLite service).
  Float32List pcmToLogMelTensor(
    Uint8List pcm16le, {
    required MelSpectrogramConfig cfg,
    required int outH,
    required int outW,
  }) {
    final audio = pcm16leToFloat32(pcm16le);
    final logMel = logMelSpectrogram(audio, cfg);
    final resized = resize2d(logMel, outH, outW);
    return normalizeToTensor(resized, outH, outW);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Internal helpers
  // ──────────────────────────────────────────────────────────────────────────

  List<double> _hann(int n) {
    final w = List<double>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      w[i] = 0.5 - 0.5 * math.cos((2 * math.pi * i) / (n - 1));
    }
    return w;
  }

  static const double _ln10 = 2.302585092994046;
  double _log10(double x) => math.log(x) / _ln10;

  double _hzToMel(double hz) => 2595.0 * _log10(1.0 + hz / 700.0);
  double _melToHz(double mel) => 700.0 * (math.pow(10.0, mel / 2595.0) - 1.0);

  List<List<double>> _melFilterbank(MelSpectrogramConfig cfg) {
    final nFreq = (cfg.nFft ~/ 2) + 1;

    final melMin = _hzToMel(cfg.fMin);
    final melMax = _hzToMel(cfg.fMax);
    final melPoints = List<double>.generate(
      cfg.nMels + 2,
      (i) => melMin + (melMax - melMin) * (i / (cfg.nMels + 1)),
    );

    final hzPoints = melPoints.map(_melToHz).toList();
    final bin = hzPoints
        .map((hz) => ((cfg.nFft + 1) * hz / cfg.sampleRate).floor())
        .map((b) => b.clamp(0, nFreq - 1))
        .toList();

    final fb = List.generate(cfg.nMels, (_) => List<double>.filled(nFreq, 0));

    for (int m = 1; m <= cfg.nMels; m++) {
      final f0 = bin[m - 1];
      final f1 = bin[m];
      final f2 = bin[m + 1];

      for (int k = f0; k < f1; k++) {
        fb[m - 1][k] = (k - f0) / math.max(1, (f1 - f0));
      }
      for (int k = f1; k < f2; k++) {
        fb[m - 1][k] = (f2 - k) / math.max(1, (f2 - f1));
      }

      // Normalize each filter to sum to 1 (helps stability)
      double s = 0;
      for (int k = 0; k < nFreq; k++) {
        s += fb[m - 1][k];
      }
      if (s > 0) {
        for (int k = 0; k < nFreq; k++) {
          fb[m - 1][k] /= s;
        }
      }
    }

    return fb;
  }

  /// In-place radix-2 FFT (Cooley–Tukey). re/im length must be power-of-two.
  void _fftRadix2(Float64List re, Float64List im) {
    final n = re.length;
    if (n <= 1) return;

    // Bit-reversal permutation
    int j = 0;
    for (int i = 1; i < n; i++) {
      int bit = n >> 1;
      while (j & bit != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;

      if (i < j) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }

    for (int len = 2; len <= n; len <<= 1) {
      final ang = -2 * math.pi / len;
      final wLenRe = math.cos(ang);
      final wLenIm = math.sin(ang);

      for (int i = 0; i < n; i += len) {
        double wRe = 1;
        double wIm = 0;

        for (int k = 0; k < len ~/ 2; k++) {
          final uRe = re[i + k];
          final uIm = im[i + k];

          final vRe = re[i + k + len ~/ 2] * wRe - im[i + k + len ~/ 2] * wIm;
          final vIm = re[i + k + len ~/ 2] * wIm + im[i + k + len ~/ 2] * wRe;

          re[i + k] = uRe + vRe;
          im[i + k] = uIm + vIm;
          re[i + k + len ~/ 2] = uRe - vRe;
          im[i + k + len ~/ 2] = uIm - vIm;

          final nextWRe = wRe * wLenRe - wIm * wLenIm;
          final nextWIm = wRe * wLenIm + wIm * wLenRe;
          wRe = nextWRe;
          wIm = nextWIm;
        }
      }
    }
  }
}
