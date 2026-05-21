import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'theme/app_theme.dart';
import 'screens/login_screen.dart';
import 'screens/caregiver_setup_screen.dart';
import 'screens/device_connection_screen.dart';
import 'screens/main_shell.dart';
import 'services/app_session.dart';

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
        '/home_sim': (context) => const MainShell(simulated: true),
      },
    );
  }
}

/// Startup gate that ensures the full user context is ready before any
/// downstream screen is shown.
///
/// Flow:
///   1. Initialise [AppSession] (checks auth + loads baby profile)
///   2. Route accordingly:
///      • No session       → /login
///      • No baby profile  → /setup
///      • Fully ready      → /device (connection screen – ALWAYS shown)
///
/// After this gate, [AppSession.instance.isReady] is guaranteed true and
/// [AppSession.instance.babyId] is non-null.  Trends, chat, logs, analytics
/// can safely query Supabase with the baby context.
class SplashGate extends StatefulWidget {
  const SplashGate({super.key});

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Brief delay for splash feel
    await Future.delayed(const Duration(milliseconds: 800));

    if (!mounted) return;

    // AppSession.init() handles:
    //   1. Auth session check
    //   2. Baby profile fetch (Supabase → local cache fallback)
    //   3. baby_id + userId global initialisation
    final route = await AppSession.instance.init();

    if (!mounted) return;
    Navigator.pushReplacementNamed(context, route);
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
