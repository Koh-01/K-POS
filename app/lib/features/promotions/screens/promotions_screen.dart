import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/models/promotion.dart';
import '../../../shared/utils/error_utils.dart';

final _promotionsProvider =
    FutureProvider.autoDispose<List<Promotion>>((ref) async {
  final res = await ApiClient.instance.get('/promotions');
  return (res.data as List)
      .map((e) => Promotion.fromJson(e as Map<String, dynamic>))
      .toList();
});

class PromotionsScreen extends ConsumerWidget {
  const PromotionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final promosAsync = ref.watch(_promotionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Promotions'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(_promotionsProvider),
          ),
        ],
      ),
      body: promosAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(loadError(e))),
        data: (promos) {
          if (promos.isEmpty) {
            return const Center(child: Text('No promotions configured'));
          }
          return ListView.builder(
            itemCount: promos.length,
            itemBuilder: (ctx, i) =>
                _PromoTile(promo: promos[i], ref: ref),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showForm(context, ref),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _showForm(BuildContext context, WidgetRef ref,
      [Promotion? existing]) async {
    // Fetch active products for B1F1 picker
    List<({int id, String name})> products = [];
    try {
      final res = await ApiClient.instance.get('/products');
      products = (res.data as List)
          .where((p) =>
              (p['status'] as String? ?? 'active') == 'active' &&
              !(p['is_deleted'] as bool? ?? false))
          .map((p) => (id: p['id'] as int, name: p['name'] as String))
          .toList();
    } catch (_) {}

    if (!context.mounted) return;

    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final valueCtrl = TextEditingController(
        text: existing != null && existing.percent > 0
            ? existing.percent.toStringAsFixed(0)
            : '');
    final promoCodeCtrl =
        TextEditingController(text: existing?.promoCode ?? '');
    String type = existing?.type ?? 'discount_pct';
    bool isActive = existing?.isActive ?? true;
    int? b1f1ProductId =
        existing?.conditions['product_id'] as int?;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title:
              Text(existing == null ? 'New Promotion' : 'Edit Promotion'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Name',
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: type,
                  decoration: const InputDecoration(
                      labelText: 'Type',
                      border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(
                        value: 'discount_pct',
                        child: Text('Discount %')),
                    DropdownMenuItem(
                        value: 'b1f1',
                        child: Text('Buy 1 Free 1')),
                    DropdownMenuItem(
                        value: 'happy_hour',
                        child: Text('Happy Hour')),
                    DropdownMenuItem(
                        value: 'promo_code',
                        child: Text('Promo Code')),
                  ],
                  onChanged: (v) => setState(() {
                    type = v!;
                    b1f1ProductId = null; // reset when type changes
                  }),
                ),
                const SizedBox(height: 10),

                // B1F1: product picker
                if (type == 'b1f1') ...[
                  DropdownButtonFormField<int>(
                    value: b1f1ProductId,
                    decoration: const InputDecoration(
                        labelText: 'Product (Buy 1 Free 1)',
                        border: OutlineInputBorder()),
                    hint: const Text('Select product'),
                    items: products
                        .map((p) => DropdownMenuItem<int>(
                              value: p.id,
                              child: Text(p.name),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => b1f1ProductId = v),
                  ),
                ] else ...[
                  // Percent-based types
                  TextField(
                    controller: valueCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Discount % (1–100)',
                        border: OutlineInputBorder()),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                ],

                if (type == 'promo_code') ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: promoCodeCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Promo Code',
                        border: OutlineInputBorder()),
                  ),
                ],
                const SizedBox(height: 8),
                SwitchListTile(
                  title: const Text('Active'),
                  value: isActive,
                  onChanged: (v) => setState(() => isActive = v),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final pct = double.tryParse(valueCtrl.text.trim()) ?? 0;
                final code = promoCodeCtrl.text.trim();

                if (name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Name is required')));
                  return;
                }
                if (type == 'b1f1' && b1f1ProductId == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Please select a product for Buy 1 Free 1')));
                  return;
                }
                if (type != 'b1f1' && (pct <= 0 || pct > 100)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Enter a valid % value (1–100)')));
                  return;
                }
                if (type == 'promo_code' && code.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Promo code cannot be empty')));
                  return;
                }

                Navigator.pop(ctx);

                final Map<String, dynamic> conditions;
                switch (type) {
                  case 'discount_pct':
                    conditions = {'percent': pct, 'product_ids': []};
                  case 'b1f1':
                    conditions = {
                      'product_id': b1f1ProductId!,
                      'product_ids': []
                    };
                  case 'happy_hour':
                    conditions = {
                      'percent': pct,
                      'days': [0, 1, 2, 3, 4, 5, 6],
                      'start_time': '09:00',
                      'end_time': '17:00',
                      'product_ids': [],
                    };
                  case 'promo_code':
                    conditions = {
                      'code': code,
                      'percent': pct,
                      'usage_limit': 0,
                      'min_order': 0,
                    };
                  default:
                    conditions = {};
                }

                final payload = {
                  'name': name,
                  'type': type,
                  'conditions': conditions,
                  'is_active': isActive,
                };
                try {
                  if (existing == null) {
                    await ApiClient.instance
                        .post('/promotions', data: payload);
                  } else {
                    await ApiClient.instance
                        .put('/promotions/${existing.id}', data: payload);
                  }
                  ref.invalidate(_promotionsProvider);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(friendlyError(e))));
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    valueCtrl.dispose();
    promoCodeCtrl.dispose();
  }
}

class _PromoTile extends StatelessWidget {
  final Promotion promo;
  final WidgetRef ref;
  const _PromoTile({required this.promo, required this.ref});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: CircleAvatar(
          backgroundColor: promo.isActive
              ? const Color(0xFFF97316).withValues(alpha: 0.15)
              : Colors.grey.shade200,
          child: Icon(Icons.local_offer_outlined,
              color:
                  promo.isActive ? const Color(0xFFF97316) : Colors.grey),
        ),
        title: Text(promo.name),
        subtitle: Text(promo.summary),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: promo.isActive
                    ? const Color(0xFF10B981).withValues(alpha: 0.15)
                    : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                promo.isActive ? 'Active' : 'Inactive',
                style: TextStyle(
                    fontSize: 11,
                    color: promo.isActive
                        ? const Color(0xFF10B981)
                        : Colors.grey),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () => _delete(context),
            ),
          ],
        ),
      );

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete promotion?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) {
      await ApiClient.instance.delete('/promotions/${promo.id}');
      ref.invalidate(_promotionsProvider);
    }
  }
}
