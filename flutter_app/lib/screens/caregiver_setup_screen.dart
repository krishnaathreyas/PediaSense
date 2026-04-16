import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/baby_profile.dart';

class CaregiverSetupScreen extends StatefulWidget {
  const CaregiverSetupScreen({super.key});

  @override
  State<CaregiverSetupScreen> createState() => _CaregiverSetupScreenState();
}

class _CaregiverSetupScreenState extends State<CaregiverSetupScreen> {
  int _activeStep = 0;
  final _babyNameController = TextEditingController();
  String _ageMonths = '12';
  final _weightController = TextEditingController();
  bool _isLowBirthWeight = false;
  bool _isLoadingProfile = true;

  final List<String> _steps = ['Baby Information', 'Health Settings'];

  @override
  void initState() {
    super.initState();
    _checkExistingProfileAndRoute();
  }

  @override
  void dispose() {
    _babyNameController.dispose();
    _weightController.dispose();
    super.dispose();
  }

  bool get _isStepValid {
    if (_activeStep == 0) {
      final parsedAge = int.tryParse(_ageMonths);
      final parsedWeight = double.tryParse(_weightController.text);
      return _babyNameController.text.trim().isNotEmpty &&
          parsedAge != null &&
          parsedAge >= 12 &&
          parsedAge <= 24 &&
          parsedWeight != null &&
          parsedWeight > 0 &&
          parsedWeight <= 30;
    }
    return true;
  }

  Future<void> _checkExistingProfileAndRoute() async {
    final hasProfile = await BabyProfile.existsForCurrentUser();
    if (!mounted) return;

    if (hasProfile) {
      Navigator.pushReplacementNamed(context, '/home');
      return;
    }

    setState(() {
      _isLoadingProfile = false;
    });
  }

  void _handleNext() async {
    if (_activeStep == _steps.length - 1) {
      // Save profile
      final profile = BabyProfile(
        babyName: _babyNameController.text.trim(),
        ageMonths: int.parse(_ageMonths),
        weight: double.tryParse(_weightController.text) ?? 10.0,
        isLowBirthWeight: _isLowBirthWeight,
      );
      await BabyProfile.save(profile);
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/device');
      }
    } else {
      setState(() {
        _activeStep++;
      });
    }
  }

  void _handleBack() {
    setState(() {
      _activeStep--;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingProfile) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Header
                Icon(
                  Icons.baby_changing_station,
                  size: 64,
                  color: AppTheme.primaryMain,
                ),
                const SizedBox(height: 16),
                Text(
                  'Caregiver Setup',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  "Let's set up your baby's profile",
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),

                // Card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        // Stepper indicators
                        Row(
                          children: List.generate(_steps.length, (index) {
                            final isActive = index <= _activeStep;
                            return Expanded(
                              child: Row(
                                children: [
                                  Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: isActive
                                          ? AppTheme.primaryMain
                                          : Colors.grey.shade300,
                                    ),
                                    child: Center(
                                      child: index < _activeStep
                                          ? const Icon(
                                              Icons.check,
                                              size: 16,
                                              color: Colors.white,
                                            )
                                          : Text(
                                              '${index + 1}',
                                              style: TextStyle(
                                                color: isActive
                                                    ? Colors.white
                                                    : Colors.grey.shade600,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 12,
                                              ),
                                            ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _steps[index],
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: isActive
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: isActive
                                            ? AppTheme.textPrimary
                                            : AppTheme.textSecondary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ),
                        const SizedBox(height: 24),
                        const Divider(),
                        const SizedBox(height: 24),

                        // Step content
                        if (_activeStep == 0) _buildStep0(),
                        if (_activeStep == 1) _buildStep1(),

                        const SizedBox(height: 32),

                        // Navigation Buttons
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            OutlinedButton(
                              onPressed: _activeStep > 0 ? _handleBack : null,
                              child: const Text('Back'),
                            ),
                            ElevatedButton(
                              onPressed: _isStepValid ? _handleNext : null,
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size(140, 48),
                              ),
                              child: Text(
                                _activeStep == _steps.length - 1
                                    ? 'Complete Setup'
                                    : 'Next',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStep0() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Baby Information',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 24),
        TextFormField(
          controller: _babyNameController,
          decoration: const InputDecoration(labelText: "Baby's Name"),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 20),
        DropdownButtonFormField<String>(
          initialValue: _ageMonths,
          decoration: const InputDecoration(labelText: 'Age (months)'),
          items: List.generate(13, (i) => i + 12)
              .map(
                (month) => DropdownMenuItem(
                  value: month.toString(),
                  child: Text('$month months'),
                ),
              )
              .toList(),
          onChanged: (value) {
            setState(() {
              _ageMonths = value ?? '12';
            });
          },
        ),
        const SizedBox(height: 20),
        TextFormField(
          controller: _weightController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Weight (kg)'),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  Widget _buildStep1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Health Settings',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 24),

        // Low Birth Weight toggle
        Card(
          color: _isLowBirthWeight
              ? AppTheme.warningLight.withValues(alpha: 0.15)
              : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade300),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  title: const Text('Low Birth Weight (LBW)'),
                  value: _isLowBirthWeight,
                  onChanged: (value) {
                    setState(() {
                      _isLowBirthWeight = value;
                    });
                  },
                  activeThumbColor: AppTheme.warningMain,
                  contentPadding: EdgeInsets.zero,
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Text(
                    'Enable this to adjust risk thresholds for babies born with low birth weight. This will make the monitoring more sensitive to potential health concerns.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),

        // Info box
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.primaryLight.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.primaryLight),
          ),
          child: RichText(
            text: TextSpan(
              style: TextStyle(fontSize: 14, color: AppTheme.primaryDark),
              children: const [
                TextSpan(
                  text: 'Note: ',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(
                  text:
                      'PediaSense uses WHO IMCI guidelines to provide evidence-based health monitoring. The system will continuously adapt to your baby\'s growth patterns.',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
