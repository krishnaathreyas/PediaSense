import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/rag_suggestion.dart';
import '../models/vitals_data.dart';

/// Service that calls the Supabase Edge Function `rag-suggest`
/// to get evidence-based caregiver guidance grounded in WHO IMCI
/// and IAP guidelines via RAG (Retrieval-Augmented Generation).
///
/// Supports two modes:
/// 1. Auto-triggered on AMBER/RED vitals transitions
/// 2. User-initiated free-text chat questions
class RagService {
  RagService._();
  static final RagService instance = RagService._();

  final _suggestionController = StreamController<RagSuggestion>.broadcast();

  /// Stream of RAG suggestions. Subscribe from the guidance screen.
  Stream<RagSuggestion> get suggestionStream => _suggestionController.stream;

  /// The most recent suggestion (cached).
  RagSuggestion? _lastSuggestion;
  RagSuggestion? get lastSuggestion => _lastSuggestion;

  /// Current vitals (kept for chat context).
  VitalsData? _currentVitals;
  VitalsData? get currentVitals => _currentVitals;

  /// Track the last risk level we fetched for, to avoid repeat calls.
  String? _lastFetchedRiskLevel;

  /// Debounce timer — prevents rapid-fire API calls on flapping vitals.
  Timer? _debounceTimer;
  static const _debounceDuration = Duration(seconds: 3);

  /// Whether a request is currently in-flight.
  bool _isFetching = false;
  bool get isFetching => _isFetching;

  /// Baby profile info for context.
  int _babyAgeMonths = 12;
  bool _isLBW = false;

  /// Call this whenever vitals update. It will decide whether to fetch.
  void onVitalsUpdate(VitalsData vitals,
      {int babyAgeMonths = 12, bool isLBW = false}) {
    _currentVitals = vitals;
    _babyAgeMonths = babyAgeMonths;
    _isLBW = isLBW;

    final riskLevel = vitals.riskLevelString;

    // Only fetch on AMBER or RED
    if (riskLevel == 'normal') {
      if (_lastFetchedRiskLevel != 'normal') {
        _lastFetchedRiskLevel = 'normal';
        _lastSuggestion = null;
      }
      return;
    }

    // Don't re-fetch if we already have a suggestion for this risk level
    if (riskLevel == _lastFetchedRiskLevel && _lastSuggestion != null) {
      return;
    }

    // Debounce
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, () {
      _fetchSuggestion(vitals, babyAgeMonths: babyAgeMonths, isLBW: isLBW);
    });
  }

  /// Send a user's free-text question to the RAG engine.
  /// Returns the parsed RagSuggestion (also emitted on the stream).
  Future<RagSuggestion> askQuestion(String question) async {
    _isFetching = true;

    try {
      final payload = <String, dynamic>{
        'userQuery': question,
        'babyAgeMonths': _babyAgeMonths,
        'isLBW': _isLBW,
      };

      // Include current vitals for context if available
      if (_currentVitals != null) {
        payload['heartRate'] = _currentVitals!.heartRate;
        payload['spo2'] = _currentVitals!.spo2;
        payload['breathingRate'] = _currentVitals!.breathingRate;
        payload['skinTemp'] = _currentVitals!.skinTemp;
        payload['riskLevel'] = _currentVitals!.riskLevelString;
      }

      final response = await Supabase.instance.client.functions
          .invoke('rag-suggest', body: payload)
          .timeout(const Duration(seconds: 20));

      final data = response.data;
      Map<String, dynamic> json;
      if (data is String) {
        json = jsonDecode(data) as Map<String, dynamic>;
      } else if (data is Map<String, dynamic>) {
        json = data;
      } else {
        throw Exception('Unexpected response type: ${data.runtimeType}');
      }

      final suggestion = RagSuggestion.fromJson(json);
      _lastSuggestion = suggestion;
      // Don't emit on stream — chat screen handles user query responses
      // directly via the returned Future, not via the auto-suggestion stream.
      return suggestion;
    } catch (e) {
      final fallback = RagSuggestion.localFallback(
          _currentVitals?.riskLevelString ?? 'monitor');
      _lastSuggestion = fallback;
      return fallback;
    } finally {
      _isFetching = false;
    }
  }

  Future<void> _fetchSuggestion(
    VitalsData vitals, {
    int babyAgeMonths = 12,
    bool isLBW = false,
  }) async {
    if (_isFetching) return;
    _isFetching = true;

    final riskLevel = vitals.riskLevelString;

    try {
      final payload = {
        'heartRate': vitals.heartRate,
        'spo2': vitals.spo2,
        'breathingRate': vitals.breathingRate,
        'skinTemp': vitals.skinTemp,
        'riskLevel': riskLevel,
        'babyAgeMonths': babyAgeMonths,
        'isLBW': isLBW,
      };

      final response = await Supabase.instance.client.functions
          .invoke('rag-suggest', body: payload)
          .timeout(const Duration(seconds: 15));

      final data = response.data;

      Map<String, dynamic> json;
      if (data is String) {
        json = jsonDecode(data) as Map<String, dynamic>;
      } else if (data is Map<String, dynamic>) {
        json = data;
      } else {
        throw Exception('Unexpected response type: ${data.runtimeType}');
      }

      final suggestion = RagSuggestion.fromJson(json);

      _lastSuggestion = suggestion;
      _lastFetchedRiskLevel = riskLevel;
      _suggestionController.add(suggestion);
    } catch (e) {
      final fallback = RagSuggestion.localFallback(riskLevel);
      _lastSuggestion = fallback;
      _lastFetchedRiskLevel = riskLevel;
      _suggestionController.add(fallback);
    } finally {
      _isFetching = false;
    }
  }

  /// Force a fresh fetch regardless of cache.
  Future<void> refresh(VitalsData vitals,
      {int babyAgeMonths = 12, bool isLBW = false}) async {
    _lastFetchedRiskLevel = null;
    _debounceTimer?.cancel();
    await _fetchSuggestion(vitals,
        babyAgeMonths: babyAgeMonths, isLBW: isLBW);
  }

  void dispose() {
    _debounceTimer?.cancel();
    _suggestionController.close();
  }
}
