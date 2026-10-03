import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/cashier_provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/products/providers/products_provider.dart';
import '../../../features/settings/providers/settings_provider.dart';
import '../../../core/db/local_db.dart';
import '../../../core/models/order.dart';
import '../../../features/cash/screens/cash_records_screen.dart';
import '../../../shared/utils/error_utils.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/kts_logo.dart';

class CashierHomeScreen extends ConsumerWidget {
  const CashierHomeScreen({super.key});

  Future<void> _showSyncStatus(BuildContext context) async {
    final issues = await LocalDb.getPendingSyncIssues();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Offline sync status'),
        content: SizedBox(
          width: 440,
          child: issues.isEmpty
              ? const Text(
                  'Items are waiting for a network connection and will retry automatically.',
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: issues.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (_, index) {
                    final issue = issues[index];
                    final reference = issue['reference']?.toString() ?? '';
                    final shortRef = reference.length > 12
                        ? reference.substring(0, 12)
                        : reference;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(
                        Icons.error_outline,
                        color: Colors.orange,
                      ),
                      title: Text('${issue['kind']} · $shortRef'),
                      subtitle: Text(issue['last_error']?.toString() ?? ''),
                      trailing: Text('${issue['retry_count']}×'),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    if (user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final ordersAsync = ref.watch(openOrdersProvider);
    // Warm every cache required by the basic sale flow as soon as the cashier
    // reaches home. This closes the window where login succeeds, connectivity
    // drops before the first order screen is opened, and the device otherwise
    // has no catalogue/table/tax snapshot for offline checkout.
    ref.watch(productsProvider);
    ref.watch(tablesProvider);
    ref.watch(settingsProvider);
    final pendingSyncCount = ref.watch(pendingSyncCountProvider).value ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            KtsLogo(size: 32, onDark: true),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'K POS',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
                Text(
                  user.fullName,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ],
        ),
        leading: user.isAdmin
            ? IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Admin Home',
                onPressed: () => context.go('/admin'),
              )
            : null,
        actions: [
          if (pendingSyncCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: ActionChip(
                avatar: const Icon(Icons.cloud_upload_outlined, size: 16),
                label: Text('$pendingSyncCount pending'),
                tooltip: 'View offline sync status',
                onPressed: () => _showSyncStatus(context),
                backgroundColor: Colors.orange.shade100,
                side: BorderSide(color: Colors.orange.shade300),
              ),
            ),
          if (user.canViewCash)
            IconButton(
              icon: const Icon(Icons.account_balance_wallet_outlined),
              tooltip: 'Cash Records',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CashRecordsScreen()),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () {
              ref.invalidate(openOrdersProvider);
              ref.invalidate(tablesProvider);
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'products') context.push('/products');
              if (v == 'categories') context.push('/categories');
              if (v == 'promotions') context.push('/promotions');
              if (v == 'payments') context.push('/payments');
              if (v == 'settings') context.push('/settings');
              if (v == 'logout') ref.read(authProvider.notifier).logout();
            },
            icon: const Icon(Icons.more_vert_rounded),
            itemBuilder: (_) => [
              if (user.canManageCatalog)
                const PopupMenuItem(
                  value: 'products',
                  child: Row(
                    children: [
                      Icon(Icons.inventory_2_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('Products'),
                    ],
                  ),
                ),
              if (user.canManageCatalog)
                const PopupMenuItem(
                  value: 'categories',
                  child: Row(
                    children: [
                      Icon(Icons.category_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('Categories'),
                    ],
                  ),
                ),
              if (user.canManagePromotion)
                const PopupMenuItem(
                  value: 'promotions',
                  child: Row(
                    children: [
                      Icon(Icons.local_offer_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('Promotions'),
                    ],
                  ),
                ),
              const PopupMenuItem(
                value: 'payments',
                child: Row(
                  children: [
                    Icon(Icons.payments_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('Payment History'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('Settings'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(
                      Icons.logout_rounded,
                      size: 18,
                      color: AppTheme.danger,
                    ),
                    SizedBox(width: 10),
                    Text('Logout', style: TextStyle(color: AppTheme.danger)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: ordersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(loadError(e))),
        data: (orders) => _OrderGrid(orders: orders),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/cashier/table-select'),
        icon: const Icon(Icons.add_rounded),
        label: const Text(
          'New Order',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _OrderGrid extends StatelessWidget {
  final List<Order> orders;
  const _OrderGrid({required this.orders});

  @override
  Widget build(BuildContext context) {
    if (orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppTheme.creamDeep,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.receipt_long_outlined,
                size: 36,
                color: AppTheme.textHint,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'No open orders',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Tap + New Order to get started',
              style: TextStyle(fontSize: 13, color: AppTheme.textHint),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final crossCount = w >= 900
            ? 4
            : w >= 600
            ? 3
            : 2;
        final aspect = w >= 900
            ? 1.4
            : w >= 600
            ? 1.35
            : 1.25;

        return GridView.builder(
          padding: EdgeInsets.all(w >= 600 ? 20 : 14),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossCount,
            childAspectRatio: aspect,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: orders.length,
          itemBuilder: (ctx, i) => _OrderCard(order: orders[i]),
        );
      },
    );
  }
}

class _OrderCard extends ConsumerWidget {
  final Order order;
  const _OrderCard({required this.order});

  String _label(WidgetRef ref, {bool watch = true}) => orderPlaceLabel(
    orderType: order.orderType,
    tableName: order.tableName,
    tableId: order.tableId,
    tables: (watch ? ref.watch(tablesProvider) : ref.read(tablesProvider))
        .valueOrNull,
  );

  Future<void> _confirmCancel(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Order?'),
        content: Text(
          'Cancel order for ${_label(ref, watch: false)}? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('Cancel Order'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      if (order.id != null) {
        await OrderService.deleteOrder(order.id!);
      } else if (order.offlineRef != null) {
        await LocalDb.deletePendingOrder(order.offlineRef!);
      }
      // The freed table must not keep showing "Occupied" from the cache.
      ref.invalidate(openOrdersProvider);
      ref.invalidate(tablesProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTakeaway = order.orderType == OrderTypes.takeAway;
    final label = _label(ref);
    final itemCount = order.items.length;
    final accentColor = isTakeaway ? const Color(0xFFE07A3A) : AppTheme.info;

    final isOffline = order.id == null;

    return GestureDetector(
      onTap: () {
        if (order.id != null) {
          context.push('/cashier/order/${order.id}');
        } else if (order.offlineRef != null) {
          context.push('/cashier/order-offline/${order.offlineRef}');
        }
      },
      onLongPress: () => _confirmCancel(context, ref),
      child: Opacity(
        opacity: isOffline ? 0.75 : 1.0,
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isOffline
                  ? AppTheme.warning.withValues(alpha: 0.4)
                  : AppTheme.border,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left accent stripe
                Container(
                  width: 4,
                  color: isOffline ? AppTheme.warning : accentColor,
                ),
                // Content
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: accentColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                isTakeaway
                                    ? Icons.shopping_bag_outlined
                                    : Icons.table_restaurant_rounded,
                                size: 16,
                                color: accentColor,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                label,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  color: AppTheme.textPrimary,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 2,
                              ),
                            ),
                            GestureDetector(
                              onTap: () => _confirmCancel(context, ref),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 16,
                                  color: AppTheme.textHint,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        if (isOffline)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            margin: const EdgeInsets.only(bottom: 4),
                            decoration: BoxDecoration(
                              color: AppTheme.warning.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'Pending sync',
                              style: TextStyle(
                                fontSize: 10,
                                color: AppTheme.warning,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        Text(
                          '$itemCount item${itemCount == 1 ? '' : 's'}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textHint,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'RM ${order.subtotal.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
