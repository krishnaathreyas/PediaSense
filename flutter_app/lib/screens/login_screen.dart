import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart';

/// Production-ready login screen using Supabase Auth.
/// Supports email/password sign in and sign up.
/// No custom backend required — Supabase handles everything.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isSignup = false;
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMsg;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  SupabaseClient get _supabase => Supabase.instance.client;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  // ── Email validation ──────────────────────────────────────────────────────
  String? _validateEmail(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter your email';
    }
    final emailRegex = RegExp(r'^[\w\.-]+@[\w\.-]+\.\w{2,}$');
    if (!emailRegex.hasMatch(value.trim())) {
      return 'Please enter a valid email';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter your password';
    }
    if (value.length < 6) {
      return 'Password must be at least 6 characters';
    }
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value != _passwordController.text) {
      return 'Passwords do not match';
    }
    return null;
  }

  // ── Auth handlers ─────────────────────────────────────────────────────────

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text;

      if (_isSignup) {
        // ── Sign Up ──
        final response = await _supabase.auth.signUp(
          email: email,
          password: password,
        );

        if (!mounted) return;

        if (response.user != null) {
          // Check if email confirmation is required
          if (response.user!.emailConfirmedAt == null) {
            setState(() {
              _isLoading = false;
              _errorMsg = null;
            });
            _showSuccessDialog(
              'Account Created!',
              'A confirmation email has been sent to $email. '
                  'Please verify your email and then sign in.',
            );
            setState(() => _isSignup = false); // Switch to login mode
          } else {
            // Auto-confirmed — let gate decide setup vs home
            Navigator.pushReplacementNamed(context, '/gate');
          }
        }
      } else {
        // ── Sign In ──
        await _supabase.auth.signInWithPassword(
          email: email,
          password: password,
        );

        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/gate');
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMsg = _friendlyAuthError(e.message);
      });
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _errorMsg =
            'No internet connection. Please check your network and try again.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMsg = _friendlyAuthError(
          e.toString().replaceFirst('Exception: ', ''),
        );
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _handleForgotPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(
        () => _errorMsg = 'Enter your email first, then tap "Forgot Password"',
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    try {
      await _supabase.auth.resetPasswordForEmail(email);
      if (!mounted) return;
      _showSuccessDialog(
        'Reset Link Sent',
        'A password reset link has been sent to $email.',
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = _friendlyAuthError(e.message));
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _errorMsg =
            'No internet connection. Please check your network and try again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMsg =
            'Failed to send reset email. Check your network and try again.';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Convert Supabase error messages into user-friendly text
  String _friendlyAuthError(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('invalid login credentials')) {
      return 'Invalid email or password. Please try again.';
    }
    if (lower.contains('email not confirmed')) {
      return 'Please confirm your email before signing in.';
    }
    if (lower.contains('user already registered')) {
      return 'An account with this email already exists. Try signing in.';
    }
    if (lower.contains('rate limit')) {
      return 'Too many attempts. Please wait a moment and try again.';
    }
    if (lower.contains('weak password')) {
      return 'Password is too weak. Use at least 6 characters.';
    }
    if (lower.contains('failed host lookup') ||
        lower.contains('socketexception') ||
        lower.contains('no address associated with hostname') ||
        lower.contains('network') ||
        lower.contains('timed out')) {
      return 'Network is unavailable. Please connect to the internet and try again.';
    }
    return message;
  }

  void _showSuccessDialog(String title, String body) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.check_circle, color: AppTheme.successMain),
            const SizedBox(width: 10),
            Text(title, style: const TextStyle(fontSize: 18)),
          ],
        ),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═════════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // ── Logo ──
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppTheme.primaryMain, AppTheme.primaryLight],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.primaryMain.withValues(alpha: 0.3),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
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
                const SizedBox(height: 6),
                Text(
                  'Smart Health Monitoring for Your Baby',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),

                // ── Login Card ──
                Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            _isSignup ? 'Create Account' : 'Welcome Back',
                            style: Theme.of(context).textTheme.headlineMedium,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _isSignup
                                ? 'Sign up to start monitoring'
                                : 'Sign in to your account',
                            style: Theme.of(context).textTheme.bodySmall,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),

                          // ── Error banner ──
                          if (_errorMsg != null) ...[
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppTheme.errorMain.withValues(
                                  alpha: 0.08,
                                ),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: AppTheme.errorMain.withValues(
                                    alpha: 0.3,
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.error_outline,
                                    size: 18,
                                    color: AppTheme.errorMain,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _errorMsg!,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: AppTheme.errorMain,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],

                          // ── Email field ──
                          TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: 'Email',
                              prefixIcon: Icon(Icons.email_outlined, size: 20),
                            ),
                            validator: _validateEmail,
                          ),
                          const SizedBox(height: 16),

                          // ── Password field ──
                          TextFormField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            textInputAction: _isSignup
                                ? TextInputAction.next
                                : TextInputAction.done,
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(
                                Icons.lock_outlined,
                                size: 20,
                              ),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 20,
                                ),
                                onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword,
                                ),
                              ),
                            ),
                            validator: _validatePassword,
                            onFieldSubmitted: _isSignup
                                ? null
                                : (_) => _handleSubmit(),
                          ),

                          // ── Confirm password (sign up only) ──
                          if (_isSignup) ...[
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _confirmPasswordController,
                              obscureText: true,
                              textInputAction: TextInputAction.done,
                              decoration: const InputDecoration(
                                labelText: 'Confirm Password',
                                prefixIcon: Icon(Icons.lock_outlined, size: 20),
                              ),
                              validator: _validateConfirmPassword,
                              onFieldSubmitted: (_) => _handleSubmit(),
                            ),
                          ],

                          // ── Forgot password (sign in only) ──
                          if (!_isSignup) ...[
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: _isLoading
                                    ? null
                                    : _handleForgotPassword,
                                child: const Text(
                                  'Forgot Password?',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),

                          // ── Submit button ──
                          ElevatedButton(
                            onPressed: _isLoading ? null : _handleSubmit,
                            child: _isLoading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(
                                    _isSignup ? 'Create Account' : 'Sign In',
                                  ),
                          ),
                          const SizedBox(height: 16),

                          // ── Toggle sign in / sign up ──
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _isSignup
                                    ? 'Already have an account?'
                                    : "Don't have an account?",
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              TextButton(
                                onPressed: _isLoading
                                    ? null
                                    : () => setState(() {
                                        _isSignup = !_isSignup;
                                        _errorMsg = null;
                                      }),
                                child: Text(
                                  _isSignup ? 'Sign In' : 'Sign Up',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // ── Terms ──
                Text(
                  "By continuing, you agree to PediaSense's\nTerms of Service and Privacy Policy",
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
