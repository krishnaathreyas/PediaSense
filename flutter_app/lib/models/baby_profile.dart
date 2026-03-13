import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class BabyProfile {
  final String babyName;
  final int ageMonths;
  final double weight;
  final bool isLowBirthWeight;

  BabyProfile({
    required this.babyName,
    required this.ageMonths,
    required this.weight,
    required this.isLowBirthWeight,
  });

  Map<String, dynamic> toJson() => {
        'babyName': babyName,
        'ageMonths': ageMonths,
        'weight': weight,
        'isLowBirthWeight': isLowBirthWeight,
      };

  factory BabyProfile.fromJson(Map<String, dynamic> json) {
    return BabyProfile(
      babyName: json['babyName'] ?? 'Baby',
      ageMonths: json['ageMonths'] ?? 12,
      weight: (json['weight'] ?? 10.0).toDouble(),
      isLowBirthWeight: json['isLowBirthWeight'] ?? false,
    );
  }

  factory BabyProfile.defaultProfile() {
    return BabyProfile(
      babyName: 'Baby',
      ageMonths: 12,
      weight: 10.0,
      isLowBirthWeight: false,
    );
  }

  static Future<void> save(BabyProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('babyProfile', jsonEncode(profile.toJson()));
  }

  static Future<BabyProfile> load() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString('babyProfile');
    if (data != null) {
      return BabyProfile.fromJson(jsonDecode(data));
    }
    return BabyProfile.defaultProfile();
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('babyProfile');
  }
}
