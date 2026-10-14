import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/cashier_provider.dart';
import '../../../core/models/order.dart';
import '../../../core/api/api_client.dart';
import '../../../core/models/restaurant_table.dart';
import '../../../shared/utils/error_utils.dart';
import '../../../shared/utils/grid_utils.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/utils/toast.dart';

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
    // Table status changes on other tablets too: fetch the current state on
    // open. The refresh is silent (the grid stays on screen and updates in
    // place) — the app also refreshes tables every 30 s in the background,
    // and showing a spinner for each of those made the screen flicker.
    Future.microtask(() {
      if (mounted) ref.invalidate(tablesProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tablesAsync = ref.watch(tablesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Start an order')),
      // One "+" for an order at a seat that isn't in the table list (VIP
      // room, bar seat…). Permanent tables are managed in Admin → Tables.
      floatingActionButton: FloatingActionButton(
        onPressed: () => _customTable(context),
        tooltip: 'Other seat',
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: _OrderTypeCard(
              icon: Icons.shopping_bag_outlined,
              title: 'Takeaway',
              accent: const Color(0xFFE07A3A),
              onTap: () {
                ref.read(cartProvider.notifier)
                  ..clear()
                  ..setOrderType(OrderTypes.takeAway);
                context.push('/cashier/order/new');
              },
            ),
          ),
          Expanded(
            child: tablesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text(loadError(e))),
              data: (tables) => tables.isEmpty
                  ? const Center(
                      child: Text(
                        'No tables',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        const gridPadding = EdgeInsets.fromLTRB(16, 0, 16, 88);
                        return GridView.builder(
                          padding: gridPadding,
                          gridDelegate: responsiveGridDelegate(
                            // Ignore the keyboard (seat-name dialog) when
                            // sizing cards, so they don't squash behind it.
                            constraints: constraints.copyWith(
                              maxHeight:
                                  constraints.maxHeight +
                                  View.of(context).viewInsets.bottom /
                                      View.of(context).devicePixelRatio,
                            ),
                            padding: gridPadding,
                            spacing: 12,
                            narrowColumns: constraints.maxWidth < 480 ? 2 : 3,
                            narrowAspectRatio: 2.0,
                            // Compact cards: more tables per screen, no empty
                            // space above the name.
                            wideColumns: 5,
                            wideVisibleRows: 5,
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

  Future<void> _customTable(BuildContext context) async {
    final ctrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Seat name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'VIP Room, Bar 2…'),
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
            child: const Text('Start'),
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

class _OrderTypeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color accent;
  final VoidCallback onTap;

  const _OrderTypeCard({
    required this.icon,
    required this.title,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.borderLight),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_rounded, color: accent, size: 20),
          ],
        ),
      ),
    ),
  );
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
            showToast(
              context,
              'Loading ${table.name}\'s order, please try again.',
              error: true,
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
          borderRadius: BorderRadius.circular(16),
          color: Colors.white,
          border: Border.all(
            color: occupied
                ? AppTheme.danger.withValues(alpha: .45)
                : AppTheme.borderLight,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 5,
                decoration: BoxDecoration(
                  color: occupied ? AppTheme.danger : AppTheme.success,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(15),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.table_restaurant_rounded,
                    size: 22,
                    color: occupied ? AppTheme.danger : AppTheme.success,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      table.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 20,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                  if (occupied)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.danger.withValues(alpha: .09),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'Occupied',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.danger,
                        ),
                      ),
                    ),
                ],
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
          showToast(context, friendlyError(e), error: true);
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
          showToast(context, friendlyError(e), error: true);
        }
      }
    }
  }
}
