import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../../../shared/utils/error_utils.dart';

enum _Period { today, week, month }

String _fmt(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

({String start, String end}) _datesFor(_Period p) {
  final now = DateTime.now();
  final today = _fmt(now);
  return switch (p) {
    _Period.today => (start: today, end: today),
    _Period.week => (
      start: _fmt(now.subtract(Duration(days: now.weekday - 1))),
      end: today,
    ),
    _Period.month => (
      start: _fmt(DateTime(now.year, now.month, 1)),
      end: today,
    ),
  };
}

final _topProductsProvider = FutureProvider.family
    .autoDispose<List<dynamic>, _Period>((ref, period) async {
      final d = _datesFor(period);
      final res = await ApiClient.instance.get(
        '/reports/top-products?start_date=${d.start}&end_date=${d.end}&limit=10',
      );
      final data = res.data as Map<String, dynamic>;
      return (data['products'] as List<dynamic>?) ?? [];
    });

class TopProductsScreen extends ConsumerStatefulWidget {
  const TopProductsScreen({super.key});

  @override
  ConsumerState<TopProductsScreen> createState() => _TopProductsScreenState();
}

class _TopProductsScreenState extends ConsumerState<TopProductsScreen> {
  _Period _period = _Period.month;

  @override
  Widget build(BuildContext context) {
    final productsAsync = ref.watch(_topProductsProvider(_period));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Top Products'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: SegmentedButton<_Period>(
              style: SegmentedButton.styleFrom(
                foregroundColor: Colors.white,
                selectedForegroundColor: Colors.white,
                selectedBackgroundColor: const Color(0xFF1E6FD9),
              ),
              segments: const [
                ButtonSegment(value: _Period.today, label: Text('Today')),
                ButtonSegment(value: _Period.week, label: Text('This Week')),
                ButtonSegment(value: _Period.month, label: Text('This Month')),
              ],
              selected: {_period},
              onSelectionChanged: (s) => setState(() => _period = s.first),
            ),
          ),
        ),
      ),
      body: productsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(loadError(e))),
        data: (products) => products.isEmpty
            ? const Center(child: Text('No data for this period'))
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: products.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final p = products[i] as Map<String, dynamic>;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(
                        0xFF1E6FD9,
                      ).withValues(alpha: 0.1),
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1E6FD9),
                        ),
                      ),
                    ),
                    title: Text(p['product_name'] as String? ?? ''),
                    subtitle: Text(p['category_name'] as String? ?? ''),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          formatRM(
                            double.parse((p['total_revenue'] ?? 0).toString()),
                          ),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${formatQty(p['total_qty'])} sold',
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
    );
  }
}
