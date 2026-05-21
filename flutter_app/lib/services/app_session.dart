import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';


import '../models/baby_profile.dart';

/// Global singleton that holds the authenticated user context and the active
/// baby profile.  **Must** be initialised via [init] before the app navigates
/// past the splash gate – every downstream screen, service, and Supabase query
/// can rely on [babyId] and [babyProfile] being non-null when [isReady] is
/// true.
class AppSession extends ChangeNotifier {
  AppSession._();
  static final AppSession instance = AppSession._();

  // ── State ──────────────────────────────────────────────────────────────────

  BabyProfile? _babyProfile;
  String? _babyId;
  String? _userId;
  bool _ready = false;

  /// The loaded baby profile (non-null after [init] succeeds).
  BabyProfile? get babyProfile => _babyProfile;

  /// A stable identifier for the current baby, used as the foreign key in
  /// `hourly_vitals`, `care_logs`, etc.
  ///
  /// Current strategy: we use the authenticated **user id** as the baby id
  /// (1:1 mapping).  When multi-baby support is added, this will be replaced
  /// by an actual UUID from the `baby_profiles` table.
  String? get babyId => _babyId;

  /// Supabase user id.
  String? get userId => _userId;

  /// True once auth + baby profile have been resolved.
  bool get isReady => _ready;

  // ── Initialisation ─────────────────────────────────────────────────────────

  /// Call this at startup (from the splash gate) after Supabase is initialised.
  ///
  /// Returns the navigation route the app should go to next:
  ///   • `/login`  – no valid session
  ///   • `/setup`  – logged in but no baby profile
  ///   • `/device` – fully initialised → device connection screen
  Future<String> init() async {
    final session = Supabase.instance.client.auth.currentSession;

    if (session == null) {
      _reset();
      return '/login';
    }

    _userId = session.user.id;

    // ── Attempt to load baby profile (Supabase-first, local-cache fallback) ──
    final profile = await BabyProfile.load();

    // Check whether a profile actually exists (load() returns a default if
    // nothing is found, so we also check the dedicated exists method).
    final exists = await BabyProfile.existsForCurrentUser();

    if (!exists) {
      _reset();
      _userId = session.user.id; // keep userId so setup can save
      return '/setup';
    }

    // ── Profile found — activate session ──
    _babyProfile = profile;
    _babyId = _userId; // 1:1 mapping (see doc above)
    _ready = true;
    notifyListeners();

    return '/device';
  }

  /// Call after the caregiver setup screen saves a new baby profile.
  /// Re-loads the profile and marks the session as ready.
  Future<void> activateAfterSetup() async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return;

    _userId = session.user.id;
    _babyProfile = await BabyProfile.load();
    _babyId = _userId;
    _ready = true;
    notifyListeners();
  }

  /// Re-fetch the baby profile from Supabase / local cache (e.g. after edit).
  Future<void> refreshProfile() async {
    _babyProfile = await BabyProfile.load();
    notifyListeners();
  }

  /// Full sign-out: clears all session state.
  Future<void> signOut() async {
    await Supabase.instance.client.auth.signOut();
    _reset();
    notifyListeners();
  }

  void _reset() {
    _babyProfile = null;
    _babyId = null;
    _userId = null;
    _ready = false;
  }
}
