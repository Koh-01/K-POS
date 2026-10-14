import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../shared/utils/error_utils.dart';
import '../../../shared/utils/toast.dart';

class AdminToolsScreen extends ConsumerStatefulWidget {
  const AdminToolsScreen({super.key});

  @override
  ConsumerState<AdminToolsScreen> createState() => _AdminToolsScreenState();
}

class _AdminToolsScreenState extends ConsumerState<AdminToolsScreen> {
  bool _backingUp = false;
  Map<String, dynamic>? _drive;
  String? _driveError;
  bool _reportRunning = false;
  int _reportYear = DateTime.now().year;
  int _reportMonth = DateTime.now().month == 1
      ? 12
      : DateTime.now().month - 1; // default: previous month

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  @override
  void initState() {
    super.initState();
    _loadDriveStatus();
  }

  Future<void> _loadDriveStatus() async {
    try {
      final res = await ApiClient.instance.get('/admin/google-drive/status');
      if (mounted) {
        setState(() {
          _drive = res.data as Map<String, dynamic>?;
          _driveError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _driveError = friendlyError(e));
    }
  }

  bool get _driveConnected => _drive?['connected'] == true;

  Widget _driveStatus() {
    if (_driveError != null) {
      return Text(_driveError!, style: const TextStyle(color: Colors.red));
    }
    final drive = _drive;
    if (drive == null) return const LinearProgressIndicator();
    if (_driveConnected) {
      final lastError = drive['last_error'] as String?;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Connected: ${drive['google_email'] ?? 'Google account'}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (lastError != null) ...[
            const SizedBox(height: 6),
            Text(
              'Last upload failed: $lastError',
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ],
        ],
      );
    }
    final settingsUrl = drive['settings_url'] as String? ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.cloud_off, color: Colors.orange, size: 18),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                'Google Drive not connected',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Sign in to Web Admin → Settings → Google Drive on a computer '
          'or phone browser to connect your own Google account.',
          style: TextStyle(color: Colors.grey),
        ),
        if (settingsUrl.isNotEmpty)
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: Text(settingsUrl, overflow: TextOverflow.ellipsis),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: settingsUrl));
              showToast(context, 'Link copied');
            },
          ),
      ],
    );
  }

  Future<void> _runBackup() async {
    setState(() => _backingUp = true);
    try {
      final res = await ApiClient.instance.post(
        '/admin/backup',
        options: Options(receiveTimeout: const Duration(minutes: 3)),
      );
      if (mounted) {
        final filename =
            (res.data as Map<String, dynamic>?)?['filename'] ?? 'done';
        showToast(context, 'Backup complete: $filename');
      }
    } catch (e) {
      if (mounted) {
        showToast(context, friendlyError(e), error: true);
      }
    } finally {
      if (mounted) setState(() => _backingUp = false);
      _loadDriveStatus();
    }
  }

  Future<void> _runMonthlyReport() async {
    setState(() => _reportRunning = true);
    try {
      final res = await ApiClient.instance.post(
        '/admin/monthly-report?year=$_reportYear&month=$_reportMonth',
        options: Options(receiveTimeout: const Duration(minutes: 3)),
      );
      if (mounted) {
        final filename =
            (res.data as Map<String, dynamic>?)?['filename'] ?? 'done';
        showToast(context, 'Report uploaded: $filename');
      }
    } catch (e) {
      if (mounted) {
        showToast(context, friendlyError(e), error: true);
      }
    } finally {
      if (mounted) setState(() => _reportRunning = false);
      _loadDriveStatus();
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
              _driveStatus(),
              const SizedBox(height: 12),
              const Text(
                'Back up this restaurant to your own Google Drive. '
                'A backup also runs automatically every day at 12:00.',
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
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.backup),
                  label: Text(_backingUp ? 'Backing up…' : 'Run Backup Now'),
                  onPressed: _backingUp || !_driveConnected ? null : _runBackup,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Monthly Report',
            children: [
              const Text(
                'Generate the monthly sales report and save it to your own '
                'Google Drive. Last month\'s report is also saved automatically '
                'on the 1st of each month.',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Year',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        DropdownButton<int>(
                          isExpanded: true,
                          value: _reportYear,
                          items: years
                              .map(
                                (y) => DropdownMenuItem(
                                  value: y,
                                  child: Text('$y'),
                                ),
                              )
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
                        const Text(
                          'Month',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        DropdownButton<int>(
                          isExpanded: true,
                          value: _reportMonth,
                          items: List.generate(
                            12,
                            (i) => DropdownMenuItem(
                              value: i + 1,
                              child: Text(_months[i]),
                            ),
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
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.summarize),
                  label: Text(
                    _reportRunning ? 'Generating…' : 'Generate Report',
                  ),
                  onPressed: _reportRunning || !_driveConnected
                      ? null
                      : _runMonthlyReport,
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
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
}
