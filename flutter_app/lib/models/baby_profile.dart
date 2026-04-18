import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  static SupabaseClient get _db => Supabase.instance.client;

  static String _cacheKey(String userId) => 'babyProfile_$userId';

  static String? _currentUserId() => _db.auth.currentUser?.id;

  static Future<void> save(BabyProfile profile) async {
    final userId = _currentUserId();
    if (userId == null) {
      throw Exception('No authenticated user found. Please sign in again.');
    }

    try {
      await _db
          .from('baby_profiles')
          .upsert({
            'user_id': userId,
            'baby_name': profile.babyName,
            'age_months': profile.ageMonths,
            'weight_kg': profile.weight,
            'is_low_birth_weight': profile.isLowBirthWeight,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Fail silently on timeout/network error; local cache is already updated below.
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey(userId), jsonEncode(profile.toJson()));
  }

  static Future<BabyProfile> load() async {
    final userId = _currentUserId();
    if (userId == null) {
      return BabyProfile.defaultProfile();
    }

    final prefs = await SharedPreferences.getInstance();

    try {
      final row = await _db
          .from('baby_profiles')
          .select('baby_name, age_months, weight_kg, is_low_birth_weight')
          .eq('user_id', userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));

      if (row != null) {
        final profile = BabyProfile(
          babyName: (row['baby_name'] as String?) ?? 'Baby',
          ageMonths: (row['age_months'] as num?)?.toInt() ?? 12,
          weight: (row['weight_kg'] as num?)?.toDouble() ?? 10.0,
          isLowBirthWeight: (row['is_low_birth_weight'] as bool?) ?? false,
        );

        await prefs.setString(_cacheKey(userId), jsonEncode(profile.toJson()));
        return profile;
      }
    } catch (_) {
      // Fall through to local cache on network/server failures or timeout.
    }

    final data = prefs.getString(_cacheKey(userId));
    if (data != null) {
      return BabyProfile.fromJson(jsonDecode(data));
    }

    return BabyProfile.defaultProfile();
  }

  static Future<bool> existsForCurrentUser() async {
    final userId = _currentUserId();
    if (userId == null) return false;

    final prefs = await SharedPreferences.getInstance();

    try {
      final row = await _db
          .from('baby_profiles')
          .select('user_id')
          .eq('user_id', userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));
      if (row != null) return true;
    } catch (_) {
      // Fall back to local cache if backend call fails or times out.
    }

    return prefs.getString(_cacheKey(userId)) != null;
  }

  static Future<void> clear() async {
    final userId = _currentUserId();
    if (userId == null) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey(userId));
  }
}
