import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/log_entry.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final List<LogEntry> _logs = [
    LogEntry(
      id: '1',
      timestamp: DateTime.now().subtract(const Duration(hours: 2)),
      type: LogType.diaper,
      data: {'wetness': 'wet', 'stool': 'normal'},
    ),
    LogEntry(
      id: '2',
      timestamp: DateTime.now().subtract(const Duration(hours: 4)),
      type: LogType.feeding,
      data: {'type': 'breast', 'duration': 25},
    ),
  ];

  // Form state
  String _diaperWetness = 'wet';
  String _diaperStool = 'none';
  String _feedingType = 'breast';
  final _feedingDurationController = TextEditingController();
  String _symptomType = 'diarrhea';
  String _symptomSeverity = 'mild';
  final _symptomNotesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _feedingDurationController.dispose();
    _symptomNotesController.dispose();
    super.dispose();
  }

  List<LogEntry> get _filteredLogs {
    final types = [LogType.diaper, LogType.feeding, LogType.symptom];
    return _logs.where((log) => log.type == types[_tabController.index]).toList();
  }

  void _addLog() {
    LogEntry? newLog;
    final currentTab = _tabController.index;

    if (currentTab == 0) {
      newLog = LogEntry(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        timestamp: DateTime.now(),
        type: LogType.diaper,
        data: {'wetness': _diaperWetness, 'stool': _diaperStool},
      );
      _diaperWetness = 'wet';
      _diaperStool = 'none';
    } else if (currentTab == 1) {
      newLog = LogEntry(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        timestamp: DateTime.now(),
        type: LogType.feeding,
        data: {
          'type': _feedingType,
          'duration': int.tryParse(_feedingDurationController.text) ?? 0,
        },
      );
      _feedingDurationController.clear();
    } else {
      newLog = LogEntry(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        timestamp: DateTime.now(),
        type: LogType.symptom,
        data: {
          'type': _symptomType,
          'severity': _symptomSeverity,
          'notes': _symptomNotesController.text,
        },
      );
      _symptomType = 'diarrhea';
      _symptomSeverity = 'mild';
      _symptomNotesController.clear();
    }

    setState(() {
      _logs.insert(0, newLog!);
    });
  }

  void _deleteLog(String id) {
    setState(() {
      _logs.removeWhere((log) => log.id == id);
    });
  }

  IconData _getLogIcon(LogType type) {
    switch (type) {
      case LogType.diaper:
        return Icons.baby_changing_station;
      case LogType.feeding:
        return Icons.restaurant;
      case LogType.symptom:
        return Icons.medication;
    }
  }

  void _showAddDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDialogState) {
          final tabIndex = _tabController.index;
          final titles = ['Add Diaper Change', 'Add Feeding', 'Add Symptom'];

          return AlertDialog(
            title: Text(titles[tabIndex]),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tabIndex == 0) ...[
                    DropdownButtonFormField<String>(
                      initialValue: _diaperWetness,
                      decoration:
                          const InputDecoration(labelText: 'Wetness'),
                      items: const [
                        DropdownMenuItem(value: 'wet', child: Text('Wet')),
                        DropdownMenuItem(value: 'dry', child: Text('Dry')),
                        DropdownMenuItem(
                            value: 'very-wet', child: Text('Very Wet')),
                      ],
                      onChanged: (v) =>
                          setDialogState(() => _diaperWetness = v!),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: _diaperStool,
                      decoration: const InputDecoration(labelText: 'Stool'),
                      items: const [
                        DropdownMenuItem(value: 'none', child: Text('None')),
                        DropdownMenuItem(
                            value: 'normal', child: Text('Normal')),
                        DropdownMenuItem(
                            value: 'loose', child: Text('Loose')),
                        DropdownMenuItem(value: 'hard', child: Text('Hard')),
                        DropdownMenuItem(
                            value: 'watery',
                            child: Text('Watery (Diarrhea)')),
                      ],
                      onChanged: (v) =>
                          setDialogState(() => _diaperStool = v!),
                    ),
                  ] else if (tabIndex == 1) ...[
                    DropdownButtonFormField<String>(
                      initialValue: _feedingType,
                      decoration:
                          const InputDecoration(labelText: 'Feeding Type'),
                      items: const [
                        DropdownMenuItem(
                            value: 'breast', child: Text('Breast Milk')),
                        DropdownMenuItem(
                            value: 'formula', child: Text('Formula')),
                        DropdownMenuItem(
                            value: 'mixed', child: Text('Mixed')),
                      ],
                      onChanged: (v) =>
                          setDialogState(() => _feedingType = v!),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _feedingDurationController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Duration (minutes)',
                      ),
                    ),
                  ] else ...[
                    DropdownButtonFormField<String>(
                      initialValue: _symptomType,
                      decoration:
                          const InputDecoration(labelText: 'Symptom Type'),
                      items: const [
                        DropdownMenuItem(
                            value: 'diarrhea', child: Text('Diarrhea')),
                        DropdownMenuItem(
                            value: 'vomiting', child: Text('Vomiting')),
                        DropdownMenuItem(
                            value: 'cough', child: Text('Cough')),
                        DropdownMenuItem(value: 'rash', child: Text('Rash')),
                        DropdownMenuItem(
                            value: 'fever', child: Text('Fever')),
                        DropdownMenuItem(
                            value: 'congestion',
                            child: Text('Congestion')),
                      ],
                      onChanged: (v) =>
                          setDialogState(() => _symptomType = v!),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: _symptomSeverity,
                      decoration:
                          const InputDecoration(labelText: 'Severity'),
                      items: const [
                        DropdownMenuItem(value: 'mild', child: Text('Mild')),
                        DropdownMenuItem(
                            value: 'moderate', child: Text('Moderate')),
                        DropdownMenuItem(
                            value: 'severe', child: Text('Severe')),
                      ],
                      onChanged: (v) =>
                          setDialogState(() => _symptomSeverity = v!),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _symptomNotesController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Notes',
                        hintText: 'Additional observations...',
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  _addLog();
                  Navigator.pop(ctx);
                },
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(100, 40),
                ),
                child: const Text('Add Entry'),
              ),
            ],
          );
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Care Logs',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 4),
              Text(
                "Track your baby's daily activities and symptoms",
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Tabs
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 20),
          child: TabBar(
            controller: _tabController,
            onTap: (_) => setState(() {}),
            labelColor: AppTheme.primaryMain,
            unselectedLabelColor: AppTheme.textSecondary,
            indicatorColor: AppTheme.primaryMain,
            tabs: const [
              Tab(text: 'Diaper'),
              Tab(text: 'Feeding'),
              Tab(text: 'Symptoms'),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Add Entry Button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ElevatedButton.icon(
            onPressed: _showAddDialog,
            icon: const Icon(Icons.add),
            label: const Text('Add New Entry'),
          ),
        ),
        const SizedBox(height: 16),

        // Log entries
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recent Entries',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _filteredLogs.isEmpty
                          ? Center(
                              child: Text(
                                'No entries yet. Add your first entry above.',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            )
                          : ListView.builder(
                              itemCount: _filteredLogs.length,
                              itemBuilder: (context, index) {
                                final log = _filteredLogs[index];
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  decoration: BoxDecoration(
                                    color: AppTheme.backgroundDefault,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: ListTile(
                                    leading: Icon(
                                      _getLogIcon(log.type),
                                      color: AppTheme.primaryMain,
                                    ),
                                    title: Text(
                                      log.formattedData,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w500),
                                    ),
                                    subtitle: Text(
                                      '${log.timestamp.day}/${log.timestamp.month}/${log.timestamp.year} ${log.timestamp.hour}:${log.timestamp.minute.toString().padLeft(2, '0')}',
                                    ),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.delete,
                                          color: Colors.grey),
                                      onPressed: () =>
                                          _deleteLog(log.id),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 80),
      ],
    );
  }
}
