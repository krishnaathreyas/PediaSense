import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'theme/app_theme.dart';
import 'models/baby_profile.dart';
import 'screens/login_screen.dart';
import 'screens/caregiver_setup_screen.dart';
import 'screens/device_connection_screen.dart';
import 'screens/main_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Supabase init (handles Auth + Edge Functions + pgvector) ──
  await Supabase.initialize(
    url: 'https://kibxztrphyddvwfxnsgl.supabase.co',
    anonKey: 'sb_publishable_Fv80LAJ_F8f7-U4mQl82Tg_DJMsdYxp',
  );

  runApp(const PediaSenseApp());
}

class PediaSenseApp extends StatelessWidget {
  const PediaSenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PediaSense',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const SplashGate(),
      routes: {
        '/login': (context) => const LoginScreen(),
        '/gate': (context) => const SplashGate(),
        '/setup': (context) => const CaregiverSetupScreen(),
        '/device': (context) => const DeviceConnectionScreen(),
        '/home': (context) => const MainShell(),
      },
    );
  }
}

/// Checks both Supabase auth session AND local profile.
///
/// Flow:
///   1. If NOT logged in → /login
///   2. If logged in but NO baby profile → /setup
///   3. If logged in AND has profile → /home
class SplashGate extends StatefulWidget {
  const SplashGate({super.key});

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    // Brief delay for splash feel
    await Future.delayed(const Duration(milliseconds: 800));

    if (!mounted) return;

    // 1. Check Supabase auth session
    final session = Supabase.instance.client.auth.currentSession;

    if (session == null) {
      // Not logged in → login screen
      Navigator.pushReplacementNamed(context, '/login');
      return;
    }

    // 2. Logged in — check if baby profile exists for this user
    final hasProfile = await BabyProfile.existsForCurrentUser();

    if (!mounted) return;

    if (hasProfile) {
      // Profile exists → dashboard
      Navigator.pushReplacementNamed(context, '/home');
    } else {
      // Logged in but no profile → setup
      Navigator.pushReplacementNamed(context, '/setup');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundDefault,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.primaryMain, AppTheme.primaryLight],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.monitor_heart,
                size: 42,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'PediaSense',
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Smart Health Monitoring',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 32),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
