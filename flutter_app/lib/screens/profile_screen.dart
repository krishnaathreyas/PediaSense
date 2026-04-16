import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart';
import '../models/baby_profile.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _notifications = true;
  bool _criticalAlerts = true;
  BabyProfile _profile = BabyProfile.defaultProfile();

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final profile = await BabyProfile.load();
    if (mounted) {
      setState(() {
        _profile = profile;
      });
    }
  }

  void _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.errorMain),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    await Supabase.instance.client.auth.signOut();
    if (mounted) {
      Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Text('Profile', style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(height: 4),
          Text(
            "Manage your account and baby's information",
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),

          // User Profile Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: AppTheme.primaryMain,
                    child: const Icon(
                      Icons.person,
                      size: 40,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Caregiver',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        Text(
                          Supabase.instance.client.auth.currentUser?.email ??
                              'Not signed in',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.edit, size: 16),
                    label: const Text('Edit'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Baby Information Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Baby Information',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          await Navigator.pushNamed(context, '/setup');
                          await _loadProfile();
                        },
                        icon: const Icon(Icons.edit, size: 16),
                        label: const Text('Edit'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _infoTile(
                    Icons.baby_changing_station,
                    'Name',
                    _profile.babyName,
                  ),
                  _infoTile(
                    Icons.cake,
                    'Age',
                    '${_profile.ageMonths} months old',
                  ),
                  _infoTile(Icons.scale, 'Weight', '${_profile.weight} kg'),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.warning,
                      color: _profile.isLowBirthWeight
                          ? AppTheme.warningMain
                          : Colors.grey.shade400,
                    ),
                    title: const Text('Low Birth Weight'),
                    trailing: Chip(
                      label: Text(
                        _profile.isLowBirthWeight ? 'Yes' : 'No',
                        style: TextStyle(
                          color: _profile.isLowBirthWeight
                              ? Colors.white
                              : AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      backgroundColor: _profile.isLowBirthWeight
                          ? AppTheme.warningMain
                          : Colors.grey.shade200,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Notifications Settings
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Notifications',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(
                      Icons.notifications,
                      color: AppTheme.primaryMain,
                    ),
                    title: const Text('Push Notifications'),
                    subtitle: const Text('Receive alerts for health updates'),
                    value: _notifications,
                    onChanged: (v) => setState(() => _notifications = v),
                  ),
                  const Divider(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(
                      Icons.warning,
                      color: AppTheme.errorMain,
                    ),
                    title: const Text('Critical Alerts'),
                    subtitle: const Text('High-priority health warnings'),
                    value: _criticalAlerts,
                    activeThumbColor: AppTheme.errorMain,
                    onChanged: (v) => setState(() => _criticalAlerts = v),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Settings Menu
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Settings',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  _settingsTile(
                    Icons.security,
                    'Privacy & Security',
                    'Manage your data and privacy',
                  ),
                  _settingsTile(Icons.language, 'Language', 'English (US)'),
                  _settingsTile(
                    Icons.help,
                    'Help & Support',
                    'FAQs and contact support',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // About Section
          Card(
            color: AppTheme.backgroundDefault,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'About PediaSense',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Version 1.0.0',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'PediaSense uses WHO IMCI (Integrated Management of Childhood Illness) guidelines to provide evidence-based health monitoring for toddlers aged 12-24 months.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '© 2026 PediaSense. All rights reserved.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Logout Button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _handleLogout,
              icon: const Icon(Icons.logout),
              label: const Text('Logout'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.errorMain,
                side: const BorderSide(color: AppTheme.errorMain),
                minimumSize: const Size(double.infinity, 48),
              ),
            ),
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _infoTile(IconData icon, String title, String subtitle) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: AppTheme.primaryMain),
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }

  Widget _settingsTile(IconData icon, String title, String subtitle) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: AppTheme.primaryMain),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: () {},
    );
  }
}
