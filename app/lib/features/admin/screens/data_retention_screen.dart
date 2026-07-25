import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../shared/utils/error_utils.dart';

class DataRetentionScreen extends ConsumerStatefulWidget {
  const DataRetentionScreen({super.key});

  @override
  ConsumerState<DataRetentionScreen> createState() =>
      _DataRetentionScreenState();
}

class _DataRetentionScreenState extends ConsumerState<DataRetentionScreen> {
  int _years = 2;
  Map<String, dynamic>? _preview;
  bool _loading = false;
  bool _cleaning = false;

  Future<void> _loadPreview() async {
    setState(() {
      _loading = true;
      _preview = null;
    });
    try {
      final res = await ApiClient.instance
          .get('/admin/data-retention/preview?years=$_years');
      setState(() => _preview = res.data as Map<String, dynamic>);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cleanup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Cleanup'),
        content: Text(
            'This will permanently delete records older than $_years year(s). '
            'This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style:
                TextButton.styleFrom(foregroundColor: const Color(0xFFEF4444)),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _cleaning = true);
    try {
      final res = await ApiClient.instance
          .post('/admin/data-retention/cleanup?years=$_years');
      final deleted =
          (res.data as Map<String, dynamic>?)?['deleted'] as Map<String, dynamic>? ?? {};
      setState(() => _preview = null);
      if (mounted) {
        final summary = deleted.entries
            .map((e) => '${e.key}: ${e.value}')
            .join(', ');
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Deleted — $summary')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Data Retention')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'RETENTION PERIOD',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                        letterSpacing: 0.8),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Keep data for at least '),
                      DropdownButton<int>(
                        value: _years,
                        items: [1, 2, 3, 5, 7]
                            .map((y) => DropdownMenuItem(
                                  value: y,
                                  child: Text('$y year${y > 1 ? 's' : ''}'),
                                ))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() {
                              _years = v;
                              _preview = null;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _loading ? null : _loadPreview,
                      child: _loading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Preview Deletions'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_preview != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'RECORDS TO DELETE (before ${_preview!['cutoff_date']})',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                          letterSpacing: 0.8),
                    ),
                    const SizedBox(height: 12),
                    _PreviewRow('Orders', _preview!['orders_to_delete']),
                    _PreviewRow('Payments', _preview!['payments_to_delete']),
                    _PreviewRow(
                        'Cash Records', _preview!['cash_records_to_delete']),
                    _PreviewRow(
                        'Login Logs', _preview!['login_logs_to_delete']),
                    _PreviewRow(
                        'Audit Logs', _preview!['audit_logs_to_delete']),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFEF4444),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: _cleaning ? null : _cleanup,
                        child: _cleaning
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Text('Run Cleanup'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  final String label;
  final dynamic count;
  const _PreviewRow(this.label, this.count);

  @override
  Widget build(BuildContext context) {
    final n = count != null ? int.tryParse(count.toString()) ?? 0 : 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            '$n',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: n > 0 ? const Color(0xFFEF4444) : const Color(0xFF10B981),
            ),
          ),
        ],
      ),
    );
  }
}
