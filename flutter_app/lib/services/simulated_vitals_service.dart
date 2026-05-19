import 'dart:async';
import 'dart:math';

import '../models/vitals_data.dart';

class SimulatedVitalsService {
  SimulatedVitalsService._internal();
  static final SimulatedVitalsService instance =
      SimulatedVitalsService._internal();
  factory SimulatedVitalsService() => instance;

  final _controller = StreamController<VitalsData>.broadcast();
  Stream<VitalsData> get stream => _controller.stream;

  Timer? _timer;
  final _rng = Random();
  double _t = 0;

  void start({Duration interval = const Duration(seconds: 1)}) {
    if (_timer != null) return;

    _timer = Timer.periodic(interval, (_) {
      _t += interval.inMilliseconds / 1000.0;

      // Generate smooth, plausible vitals (demo-only)
      final hr = (128 + 12 * sin(_t / 3) + _rng.nextInt(5) - 2).round().clamp(
        80,
        200,
      );
      final spo2 = (97 + 1.2 * sin(_t / 7) + (_rng.nextDouble() - 0.5))
          .round()
          .clamp(90, 100);
      final br = (34 + 4 * sin(_t / 4) + _rng.nextInt(3) - 1).round().clamp(
        20,
        80,
      );
      final skinTemp =
          (36.7 + 0.25 * sin(_t / 10) + (_rng.nextDouble() - 0.5) * 0.06).clamp(
            35.5,
            38.5,
          );

      _controller.add(
        VitalsData(
          hr: hr,
          spo2: spo2,
          br: br,
          skinTemp: double.parse(skinTemp.toStringAsFixed(1)),
        ),
      );
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
