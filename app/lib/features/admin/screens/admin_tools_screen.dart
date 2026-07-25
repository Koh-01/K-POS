import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../shared/utils/error_utils.dart';

class AdminToolsScreen extends ConsumerStatefulWidget {
  const AdminToolsScreen({super.key});

  @override
  ConsumerState<AdminToolsScreen> createState() => _AdminToolsScreenState();
}

class _AdminToolsScreenState extends ConsumerState<AdminToolsScreen> {
  bool _backingUp = false;
  bool _reportRunning = false;
  int _reportYear = DateTime.now().year;
  int _reportMonth = DateTime.now().month == 1
      ? 12
      : DateTime.now().month - 1; // default: previous month

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  Future<void> _runBackup() async {
    setState(() => _backingUp = true);
    try {
      final res = await ApiClient.instance.post('/admin/backup');
      if (mounted) {
        final filename = (res.data as Map<String, dynamic>?)?['filename'] ?? 'done';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup complete: $filename')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  Future<void> _runMonthlyReport() async {
    setState(() => _reportRunning = true);
    try {
      final res = await ApiClient.instance
          .post('/admin/monthly-report?year=$_reportYear&month=$_reportMonth');
      if (mounted) {
        final filename =
            (res.data as Map<String, dynamic>?)?['filename'] ?? 'done';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Report uploaded: $filename')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _reportRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final years = List.generate(5, (i) => now.year - i);

    return Scaffold(
      appBar: AppBar(title: const Text('Admin Tools')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section(
            title: 'Google Drive Backup',
            children: [
              const Text(
                'Manually trigger a full database backup to Google Drive.',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: _backingUp
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.backup),
                  label: Text(_backingUp ? 'Backing up…' : 'Run Backup Now'),
                  onPressed: _backingUp ? null : _runBackup,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Monthly Report',
            children: [
              const Text(
                'Generate and upload the monthly sales report to Google Drive.',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Year',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                        DropdownButton<int>(
                          isExpanded: true,
                          value: _reportYear,
                          items: years
                              .map((y) => DropdownMenuItem(
                                  value: y, child: Text('$y')))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _reportYear = v);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Month',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                        DropdownButton<int>(
                          isExpanded: true,
                          value: _reportMonth,
                          items: List.generate(
                            12,
                            (i) => DropdownMenuItem(
                                value: i + 1, child: Text(_months[i])),
                          ),
                          onChanged: (v) {
                            if (v != null) setState(() => _reportMonth = v);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: _reportRunning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.summarize),
                  label: Text(
                      _reportRunning ? 'Generating…' : 'Generate Report'),
                  onPressed: _reportRunning ? null : _runMonthlyReport,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.toUpperCase(),
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                    letterSpacing: 0.8),
              ),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      );
}
