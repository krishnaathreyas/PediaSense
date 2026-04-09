import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../models/log_entry.dart';
import '../services/care_log_service.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _service = CareLogService.instance;

  List<LogEntry> _logs = [];
  bool _isLoading = true;
  String? _error;

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
    _fetchLogs();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _feedingDurationController.dispose();
    _symptomNotesController.dispose();
    super.dispose();
  }

  // ── Fetch today's logs from Supabase ────────────────────────────────────

  Future<void> _fetchLogs() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final logs = await _service.fetchTodayLogs();
      if (!mounted) return;
      setState(() {
        _logs = logs;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Failed to load logs. Pull to retry.';
      });
    }
  }

  // ── Filtered by current tab ─────────────────────────────────────────────

  List<LogEntry> get _filteredLogs {
    final types = [LogType.diaper, LogType.feeding, LogType.symptom];
    return _logs.where((log) => log.type == types[_tabController.index]).toList();
  }

  // ── Add log to Supabase ─────────────────────────────────────────────────

  Future<void> _addLog() async {
    final currentTab = _tabController.index;
    LogType type;
    Map<String, dynamic> value;

    if (currentTab == 0) {
      type = LogType.diaper;
      value = {'wetness': _diaperWetness, 'stool': _diaperStool};
      _diaperWetness = 'wet';
      _diaperStool = 'none';
    } else if (currentTab == 1) {
      type = LogType.feeding;
      value = {
        'type': _feedingType,
        'duration': int.tryParse(_feedingDurationController.text) ?? 0,
      };
      _feedingDurationController.clear();
    } else {
      type = LogType.symptom;
      value = {
        'type': _symptomType,
        'severity': _symptomSeverity,
        'notes': _symptomNotesController.text,
      };
      _symptomType = 'diarrhea';
      _symptomSeverity = 'mild';
      _symptomNotesController.clear();
    }

    try {
      final newLog = await _service.addLog(type: type, value: value);
      if (!mounted) return;
      setState(() {
        _logs.insert(0, newLog); // Optimistic — add to top immediately
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to save log. Please try again.'),
          backgroundColor: AppTheme.errorMain,
        ),
      );
    }
  }

  // ── Delete log from Supabase ────────────────────────────────────────────

  Future<void> _deleteLog(String id) async {
    // Optimistic removal
    final removed = _logs.firstWhere((l) => l.id == id);
    final index = _logs.indexOf(removed);

    setState(() {
      _logs.removeWhere((log) => log.id == id);
    });

    try {
      await _service.deleteLog(id);
    } catch (_) {
      // Revert on failure
      if (!mounted) return;
      setState(() {
        _logs.insert(index, removed);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to delete log.'),
          backgroundColor: AppTheme.errorMain,
        ),
      );
    }
  }

  // ── Icon helper ─────────────────────────────────────────────────────────

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

  Color _getLogColor(LogType type) {
    switch (type) {
      case LogType.diaper:
        return AppTheme.infoMain;
      case LogType.feeding:
        return AppTheme.successMain;
      case LogType.symptom:
        return AppTheme.warningMain;
    }
  }

  // ── Add dialog ──────────────────────────────────────────────────────────

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

  // ═════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═════════════════════════════════════════════════════════════════════════

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
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _buildErrorState()
                  : RefreshIndicator(
                      onRefresh: _fetchLogs,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        "Today's Entries",
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineSmall,
                                      ),
                                    ),
                                    Text(
                                      '${_filteredLogs.length}',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: AppTheme.primaryMain,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Expanded(
                                  child: _filteredLogs.isEmpty
                                      ? _buildEmptyState()
                                      : ListView.builder(
                                          itemCount: _filteredLogs.length,
                                          itemBuilder: (context, index) {
                                            final log = _filteredLogs[index];
                                            return _buildLogTile(log);
                                          },
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
        ),
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _buildLogTile(LogEntry log) {
    final color = _getLogColor(log.type);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(_getLogIcon(log.type), color: color, size: 20),
        ),
        title: Text(
          log.formattedData,
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
        ),
        subtitle: Text(
          '${log.formattedDate} at ${log.formattedTime}',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
        ),
        trailing: IconButton(
          icon: Icon(Icons.delete_outline, color: Colors.grey.shade400, size: 20),
          onPressed: () => _deleteLog(log.id),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.note_add_outlined, size: 48, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text(
            'No entries yet today.\nTap "Add New Entry" to start logging.',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Colors.grey.shade500),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _fetchLogs,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
