class Suggestion {
  final String id;
  final String condition;
  final String severity; // 'normal', 'monitor', 'urgent'
  final List<String> clinicalSignals;
  final List<String> immediateActions;
  final List<String> hospitalCriteria;
  final String whoReference;

  Suggestion({
    required this.id,
    required this.condition,
    required this.severity,
    required this.clinicalSignals,
    required this.immediateActions,
    required this.hospitalCriteria,
    required this.whoReference,
  });

  static List<Suggestion> getMockSuggestions() {
    return [
      Suggestion(
        id: '1',
        condition: 'Hydration Monitoring',
        severity: 'normal',
        clinicalSignals: [
          'Urine gap within normal range (< 3 hours)',
          'Adequate wet diaper frequency (6+ per day)',
          'Normal skin turgor',
        ],
        immediateActions: [
          'Continue normal feeding schedule',
          'Ensure breast milk or formula every 2-3 hours',
          'Monitor for decreased urine output',
        ],
        hospitalCriteria: [
          'No wet diaper for more than 6 hours',
          'Sunken fontanelle (soft spot on head)',
          'Dry mouth and lips',
          'Lethargy or extreme fussiness',
        ],
        whoReference: 'WHO IMCI Chart Booklet - Assess for Dehydration',
      ),
      Suggestion(
        id: '2',
        condition: 'Respiratory Health',
        severity: 'normal',
        clinicalSignals: [
          'Breathing rate: 25-35 breaths/min (normal for age)',
          'No chest indrawing observed',
          'Clear breath sounds',
        ],
        immediateActions: [
          'Maintain upright position during feeding',
          'Keep sleeping area clear of pillows and soft bedding',
          'Monitor for any changes in breathing pattern',
        ],
        hospitalCriteria: [
          'Breathing rate > 50 breaths/min',
          'Chest indrawing (ribs pulling in with each breath)',
          'Grunting sounds with breathing',
          'Blue/gray color around lips or face',
          'Flaring nostrils',
        ],
        whoReference:
            'WHO IMCI - Assess and Classify Cough or Difficult Breathing',
      ),
      Suggestion(
        id: '3',
        condition: 'Temperature Regulation',
        severity: 'normal',
        clinicalSignals: [
          'Skin temperature: 36.5-37.5°C (normal)',
          'Normal activity level',
          'Good feeding behavior',
        ],
        immediateActions: [
          "Dress baby in one more layer than you're wearing",
          'Keep room temperature at 20-22°C (68-72°F)',
          'Check temperature if baby feels unusually warm or cold',
        ],
        hospitalCriteria: [
          'Temperature > 38°C (100.4°F) or < 36°C (96.8°F)',
          'Temperature with lethargy or poor feeding',
          'Fever with rash',
          'Fever lasting more than 24 hours',
        ],
        whoReference: 'WHO IMCI - Check for General Danger Signs',
      ),
    ];
  }
}
