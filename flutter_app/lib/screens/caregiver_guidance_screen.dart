import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/suggestion.dart';

class CaregiverGuidanceScreen extends StatelessWidget {
  const CaregiverGuidanceScreen({super.key});

  Color _getSeverityColor(String severity) {
    switch (severity) {
      case 'normal':
        return AppTheme.successMain;
      case 'monitor':
        return AppTheme.warningMain;
      case 'urgent':
        return AppTheme.errorMain;
      default:
        return AppTheme.successMain;
    }
  }

  IconData _getSeverityIcon(String severity) {
    switch (severity) {
      case 'normal':
        return Icons.check_circle_outline;
      case 'monitor':
        return Icons.warning_amber;
      case 'urgent':
        return Icons.local_hospital;
      default:
        return Icons.lightbulb;
    }
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = Suggestion.getMockSuggestions();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Text(
            'Caregiver Guidance',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Evidence-based recommendations powered by WHO IMCI guidelines',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),

          // Info Alert
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.infoMain.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppTheme.infoMain.withValues(alpha: 0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lightbulb,
                    color: AppTheme.infoMain, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'These suggestions are based on real-time vitals and WHO Integrated Management of Childhood Illness (IMCI) protocols. Always consult a healthcare provider for medical decisions.',
                    style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.infoMain.withValues(alpha: 0.9)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Suggestion cards
          ...suggestions
              .asMap()
              .entries
              .map((entry) => _buildSuggestionCard(context, entry.value,
                  initiallyExpanded: entry.key == 0)),

          // Emergency Contact Card
          const SizedBox(height: 12),
          Card(
            color: AppTheme.errorMain.withValues(alpha: 0.06),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppTheme.errorMain, width: 2),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.local_hospital,
                          color: AppTheme.errorMain),
                      const SizedBox(width: 8),
                      Text(
                        'Emergency Contacts',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.errorDark,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'If your baby shows any danger signs, call emergency services immediately.',
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      Chip(
                        label: const Text('Emergency: 911',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600)),
                        backgroundColor: AppTheme.errorMain,
                      ),
                      Chip(
                        label: Text('Pediatrician',
                            style: TextStyle(color: AppTheme.errorDark)),
                        backgroundColor: Colors.transparent,
                        side: const BorderSide(color: AppTheme.errorMain),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildSuggestionCard(BuildContext context, Suggestion suggestion,
      {bool initiallyExpanded = false}) {
    final severityColor = _getSeverityColor(suggestion.severity);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Header row
            Row(
              children: [
                Icon(_getSeverityIcon(suggestion.severity),
                    color: severityColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    suggestion.condition,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: severityColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    suggestion.severity.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Clinical Signals
            _buildExpandableSection(
              context,
              icon: Icons.air,
              title: 'Clinical Signals Detected',
              items: suggestion.clinicalSignals,
              itemIcon: Icons.check_circle_outline,
              itemColor: AppTheme.successMain,
              initiallyExpanded: initiallyExpanded,
            ),

            // Immediate Actions
            _buildExpandableSection(
              context,
              icon: Icons.healing,
              title: 'Immediate Care Actions',
              items: suggestion.immediateActions,
              itemIcon: Icons.water_drop,
              itemColor: AppTheme.infoMain,
            ),

            // Hospital Criteria
            _buildExpandableSection(
              context,
              icon: Icons.local_hospital,
              title: 'When to Seek Hospital Care',
              items: suggestion.hospitalCriteria,
              itemIcon: Icons.warning_amber,
              itemColor: AppTheme.errorMain,
              showWarning: true,
            ),

            const Divider(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Reference: ${suggestion.whoReference}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpandableSection(
    BuildContext context, {
    required IconData icon,
    required String title,
    required List<String> items,
    required IconData itemIcon,
    required Color itemColor,
    bool initiallyExpanded = false,
    bool showWarning = false,
  }) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: EdgeInsets.zero,
        leading: Icon(icon, size: 20, color: AppTheme.primaryMain),
        title: Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        children: [
          if (showWarning)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.warningMain.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppTheme.warningMain.withValues(alpha: 0.3)),
              ),
              child: const Text(
                'Seek immediate medical attention if ANY of the following occur:',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.warningDark),
              ),
            ),
          ...items.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(itemIcon, size: 16, color: itemColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
