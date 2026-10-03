import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/cashier_provider.dart';
import '../../../core/models/order.dart';
import '../../../core/api/api_client.dart';
import '../../../core/models/restaurant_table.dart';
import '../../../shared/utils/error_utils.dart';
import '../../../shared/utils/grid_utils.dart';

class TableSelectionScreen extends ConsumerStatefulWidget {
  const TableSelectionScreen({super.key});

  @override
  ConsumerState<TableSelectionScreen> createState() =>
      _TableSelectionScreenState();
}

class _TableSelectionScreenState extends ConsumerState<TableSelectionScreen> {
  @override
  void initState() {
    super.initState();
    // Table status changes on other tablets too; always start from the
    // server's current state rather than a cached "Occupied".
    Future.microtask(() {
      if (mounted) ref.invalidate(tablesProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tablesAsync = ref.watch(tablesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Select Table')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addTable(context),
        tooltip: 'Add table',
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          // Takeaway
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.shopping_bag_outlined),
                label: const Text('Takeaway Order'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 1.5,
                  ),
                  foregroundColor: Theme.of(context).colorScheme.primary,
                ),
                onPressed: () {
                  ref.read(cartProvider.notifier)
                    ..clear()
                    ..setOrderType(OrderTypes.takeAway);
                  context.push('/cashier/order/new');
                },
              ),
            ),
          ),
          // Custom table name
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Custom Table Name'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.secondary,
                    width: 1.5,
                  ),
                  foregroundColor: Theme.of(context).colorScheme.secondary,
                ),
                onPressed: () => _customTable(context),
              ),
            ),
          ),
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'DINE IN — SELECT TABLE',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
          Expanded(
            child: tablesAsync.when(
              // Show the spinner while refreshing instead of stale statuses.
              skipLoadingOnRefresh: false,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text(loadError(e))),
              data: (tables) => tables.isEmpty
                  ? const Center(
                      child: Text(
                        'No tables yet.\nTap + to add one.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        const gridPadding = EdgeInsets.fromLTRB(16, 0, 16, 80);
                        return GridView.builder(
                          padding: gridPadding,
                          gridDelegate: responsiveGridDelegate(
                            constraints: constraints,
                            padding: gridPadding,
                            spacing: 10,
                            narrowAspectRatio: 1.05,
                          ),
                          itemCount: tables.length,
                          itemBuilder: (ctx, i) =>
                              _TableCard(table: tables[i], onRefresh: _refresh),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  void _refresh() => ref.invalidate(tablesProvider);

  Future<void> _addTable(BuildContext context) async {
    final ctrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Table'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Table name (e.g. Table 5)',
          ),
          textCapitalization: TextCapitalization.words,
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (confirmed == true && ctrl.text.trim().isNotEmpty && context.mounted) {
      try {
        await ApiClient.instance.post(
          '/tables',
          data: {'name': ctrl.text.trim()},
        );
        _refresh();
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
        }
      }
    }
  }

  Future<void> _customTable(BuildContext context) async {
    final ctrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Custom Table Name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter a name for this order.\nThis will NOT be saved to the table list.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'e.g. VIP Room, Bar Seat 2',
              ),
              textCapitalization: TextCapitalization.words,
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed == true && ctrl.text.trim().isNotEmpty && context.mounted) {
      ref.read(cartProvider.notifier)
        ..clear()
        ..setCustomTable(ctrl.text.trim());
      context.push('/cashier/order/new');
    }
  }
}

class _TableCard extends ConsumerWidget {
  final RestaurantTable table;
  final VoidCallback onRefresh;

  const _TableCard({required this.table, required this.onRefresh});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final occupied = table.isOccupied;
    return GestureDetector(
      onTap: () {
        if (occupied) {
          final orderId = table.currentOrderId;
          if (orderId == null) {
            // Never fall through to a blank order: that would seat a second,
            // table-less order instead of adding to the existing one.
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Loading ${table.name}\'s order, please try again.',
                ),
              ),
            );
            onRefresh();
            return;
          }
          context.push('/cashier/order/$orderId');
        } else {
          ref.read(cartProvider.notifier)
            ..clear()
            ..setTable(table.id, table.name);
          context.push('/cashier/order/new');
        }
      },
      onLongPress: () => _showManageSheet(context),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: occupied ? Colors.red.shade100 : Colors.green.shade100,
          border: Border.all(
            color: occupied ? Colors.red.shade300 : Colors.green.shade300,
            width: 1.5,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.table_restaurant,
              size: 30,
              color: occupied ? Colors.red : Colors.green.shade700,
            ),
            const SizedBox(height: 4),
            Text(
              table.name,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            Text(
              occupied ? 'Occupied' : 'Free',
              style: TextStyle(
                fontSize: 11,
                color: occupied ? Colors.red.shade700 : Colors.green.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showManageSheet(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text('Rename "${table.name}"'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(context);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: table.isOccupied ? Colors.grey : Colors.red,
              ),
              title: Text(
                table.isOccupied
                    ? 'Cannot delete (occupied)'
                    : 'Delete "${table.name}"',
                style: TextStyle(
                  color: table.isOccupied ? Colors.grey : Colors.red,
                ),
              ),
              onTap: table.isOccupied
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      _delete(context);
                    },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final ctrl = TextEditingController(text: table.name);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Table'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Table Name'),
          textCapitalization: TextCapitalization.words,
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed == true && ctrl.text.trim().isNotEmpty && context.mounted) {
      try {
        await ApiClient.instance.put(
          '/tables/${table.id}',
          data: {'name': ctrl.text.trim()},
        );
        onRefresh();
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
        }
      }
    }
  }

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Table'),
        content: Text('Delete "${table.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      try {
        await ApiClient.instance.delete('/tables/${table.id}');
        onRefresh();
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
        }
      }
    }
  }
}
