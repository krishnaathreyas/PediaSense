class EspSensorSample {
  final int? deviceTimestampMs;
  final bool? mpuOk;

  /// Acceleration in m/s^2
  final double? ax;
  final double? ay;
  final double? az;

  /// Gyro in rad/s
  final double? gx;
  final double? gy;
  final double? gz;

  final double? temperatureC;
  final double? humidity;

  /// Audio magnitude metrics (unitless)
  final int? micRms;
  final int? micPeak;

  /// When this sample was received/parsed on the phone.
  final DateTime receivedAt;

  const EspSensorSample({
    required this.receivedAt,
    this.deviceTimestampMs,
    this.mpuOk,
    this.ax,
    this.ay,
    this.az,
    this.gx,
    this.gy,
    this.gz,
    this.temperatureC,
    this.humidity,
    this.micRms,
    this.micPeak,
  });

  EspSensorSample copyWith({
    int? deviceTimestampMs,
    bool? mpuOk,
    double? ax,
    double? ay,
    double? az,
    double? gx,
    double? gy,
    double? gz,
    double? temperatureC,
    double? humidity,
    int? micRms,
    int? micPeak,
    DateTime? receivedAt,
  }) {
    return EspSensorSample(
      receivedAt: receivedAt ?? this.receivedAt,
      deviceTimestampMs: deviceTimestampMs ?? this.deviceTimestampMs,
      mpuOk: mpuOk ?? this.mpuOk,
      ax: ax ?? this.ax,
      ay: ay ?? this.ay,
      az: az ?? this.az,
      gx: gx ?? this.gx,
      gy: gy ?? this.gy,
      gz: gz ?? this.gz,
      temperatureC: temperatureC ?? this.temperatureC,
      humidity: humidity ?? this.humidity,
      micRms: micRms ?? this.micRms,
      micPeak: micPeak ?? this.micPeak,
    );
  }

  static double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static bool? _asBool(dynamic v) {
    if (v == null) return null;
    if (v is bool) return v;
    final s = v.toString().toLowerCase();
    if (s == 'true') return true;
    if (s == 'false') return false;
    return null;
  }

  /// Parses the expected ESP32 JSON payload.
  ///
  /// Recommended packet format over BLE: UTF-8, newline-delimited JSON (NDJSON).
  /// Example keys (from firmware):
  ///   t_ms, mpu_ok, ax, ay, az, gx, gy, gz, temp_c, hum, mic_rms, mic_peak
  static EspSensorSample fromJson(Map<String, dynamic> json) {
    return EspSensorSample(
      receivedAt: DateTime.now(),
      deviceTimestampMs: _asInt(json['t_ms']),
      mpuOk: _asBool(json['mpu_ok']),
      ax: _asDouble(json['ax']),
      ay: _asDouble(json['ay']),
      az: _asDouble(json['az']),
      gx: _asDouble(json['gx']),
      gy: _asDouble(json['gy']),
      gz: _asDouble(json['gz']),
      temperatureC: _asDouble(json['temp_c'] ?? json['temp']),
      humidity: _asDouble(json['hum'] ?? json['humidity']),
      micRms: _asInt(json['mic_rms'] ?? json['micRms']),
      micPeak: _asInt(json['mic_peak'] ?? json['micPeak']),
    );
  }
}
