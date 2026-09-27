import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart' as dio;
import 'package:path_provider/path_provider.dart';
import '../../../core/api/api_client.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../../../shared/utils/error_utils.dart';

final _annualReportProvider = FutureProvider.family
    .autoDispose<Map<String, dynamic>, int>((ref, year) async {
      final res = await ApiClient.instance.get(
        '/reports/sales/annual?year=$year',
      );
      return res.data as Map<String, dynamic>;
    });

class AnnualReportScreen extends ConsumerStatefulWidget {
  const AnnualReportScreen({super.key});

  @override
  ConsumerState<AnnualReportScreen> createState() => _AnnualReportScreenState();
}

class _AnnualReportScreenState extends ConsumerState<AnnualReportScreen> {
  int _year = DateTime.now().year;

  static const _monthNames = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  String _monthLabel(String month) {
    final parts = month.split('-');
    if (parts.length == 2) {
      final m = int.tryParse(parts[1]);
      if (m != null && m >= 1 && m <= 12) {
        return '${_monthNames[m - 1]} ${parts[0]}';
      }
    }
    return month;
  }

  Future<void> _exportCsv(BuildContext context) async {
    try {
      final res = await ApiClient.instance.get(
        '/reports/annual/export/csv?year=$_year',
        options: dio.Options(responseType: dio.ResponseType.bytes),
      );
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/annual_tax_report_$_year.csv');
      await file.writeAsBytes(res.data as List<int>);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text('Saved to ${file.path}'),
              duration: const Duration(seconds: 4),
            ),
          );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(friendlyError(e)),
              backgroundColor: Colors.red,
            ),
          );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final reportAsync = ref.watch(_annualReportProvider(_year));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Annual Report'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Export CSV',
            onPressed: () => _exportCsv(context),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(_annualReportProvider(_year)),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => setState(() => _year--),
                ),
                Text(
                  '$_year',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _year >= DateTime.now().year
                      ? null
                      : () => setState(() => _year++),
                ),
              ],
            ),
          ),
          Expanded(
            child: reportAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text(loadError(e))),
              data: (data) {
                final total = data['total_revenue'] != null
                    ? double.parse(data['total_revenue'].toString())
                    : 0.0;
                final orders = data['total_orders'] as int? ?? 0;
                final rows =
                    (data['monthly_breakdown'] as List<dynamic>?) ?? [];

                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: _SummaryCard(
                              label: 'Total Revenue',
                              value: formatRM(total),
                              color: const Color(0xFF10B981),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _SummaryCard(
                              label: 'Total Orders',
                              value: '$orders',
                              color: const Color(0xFF1E6FD9),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: rows.isEmpty
                          ? const Center(child: Text('No data for this year'))
                          : ListView.separated(
                              itemCount: rows.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (ctx, i) {
                                final row = rows[i] as Map<String, dynamic>;
                                final monthStr = row['month'] as String? ?? '';
                                return ListTile(
                                  title: Text(_monthLabel(monthStr)),
                                  trailing: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        formatRM(
                                          double.parse(
                                            row['revenue'].toString(),
                                          ),
                                        ),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        '${row['orders'] ?? 0} orders',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _SummaryCard({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    ),
  );
}
