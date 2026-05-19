class VitalsData {
  final int hr;
  final int spo2;
  final int br;
  final double skinTemp;

  const VitalsData({
    required this.hr,
    required this.spo2,
    required this.br,
    required this.skinTemp,
  });

  /// Parse the FINAL ESP32 payload:
  /// {"hr":115,"spo2":98,"br":32,"skin_temp":36.7}
  ///
  /// Returns null if required fields are missing or malformed.
  static VitalsData? tryFromJsonMap(Map<String, dynamic> json) {
    final hrN = json['hr'];
    final spo2N = json['spo2'];
    final brN = json['br'];
    final skinTempN = json['skin_temp'];

    if (hrN is! num || spo2N is! num || brN is! num || skinTempN is! num) {
      return null;
    }

    final hr = hrN.round();
    final spo2 = spo2N.round();
    final br = brN.round();
    final skinTemp = skinTempN.toDouble();

    // Basic sanity bounds (drop obviously corrupt packets)
    if (hr < 20 || hr > 250) return null;
    if (spo2 < 0 || spo2 > 100) return null;
    if (br < 0 || br > 120) return null;
    if (skinTemp < 20 || skinTemp > 45) return null;

    return VitalsData(hr: hr, spo2: spo2, br: br, skinTemp: skinTemp);
  }
}
