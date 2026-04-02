import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme/app_theme.dart';
import 'screens/login_screen.dart';
import 'screens/caregiver_setup_screen.dart';
import 'screens/device_connection_screen.dart';
import 'screens/main_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
        '/setup': (context) => const CaregiverSetupScreen(),
        '/device': (context) => const DeviceConnectionScreen(),
        '/home': (context) => const MainShell(),
      },
    );
  }
}

/// Checks SharedPreferences for saved profile.
/// If it exists, the user has completed setup before → go straight to /home.
/// Otherwise, show LoginScreen as the first-time flow.
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
    final prefs = await SharedPreferences.getInstance();
    final hasProfile = prefs.getString('babyProfile') != null;

    if (!mounted) return;

    if (hasProfile) {
      // Profile exists — go straight to dashboard (simulator provides vitals on emulator)
      Navigator.pushReplacementNamed(context, '/home');
    } else {
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Brief splash while checking prefs
    return Scaffold(
      backgroundColor: AppTheme.backgroundDefault,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.monitor_heart, size: 64, color: AppTheme.primaryMain),
            const SizedBox(height: 16),
            Text('PediaSense', style: Theme.of(context).textTheme.headlineLarge),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
