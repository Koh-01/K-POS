import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../shared/utils/error_utils.dart';

final _loginLogsProvider =
    FutureProvider.autoDispose<List<dynamic>>((ref) async {
  final res =
      await ApiClient.instance.get('/admin/login-logs?limit=50&page=1');
  return res.data as List<dynamic>;
});

class LoginLogsScreen extends ConsumerWidget {
  const LoginLogsScreen({super.key});

  String _formatDt(String? raw) {
    if (raw == null) return '';
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return raw;
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}'
        ' ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logsAsync = ref.watch(_loginLogsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Login Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(_loginLogsProvider),
          ),
        ],
      ),
      body: logsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(loadError(e))),
        data: (logs) => logs.isEmpty
            ? const Center(child: Text('No login logs'))
            : ListView.separated(
                itemCount: logs.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final log = logs[i] as Map<String, dynamic>;
                  final success = log['success'] as bool? ?? false;
                  final ip = log['ip_address'] as String?;
                  return ListTile(
                    leading: Icon(
                      success ? Icons.check_circle : Icons.cancel,
                      color: success
                          ? const Color(0xFF10B981)
                          : const Color(0xFFEF4444),
                    ),
                    title: Text(log['username'] as String? ?? ''),
                    subtitle: Text(_formatDt(log['created_at'] as String?)),
                    trailing: ip != null && ip.isNotEmpty
                        ? Text(ip,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey))
                        : null,
                  );
                },
              ),
      ),
    );
  }
}
