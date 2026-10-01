import 'dart:async';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/cashier_provider.dart';
import '../../../core/db/local_db.dart';
import '../../../core/models/product.dart';
import '../../../core/models/order_item.dart';
import '../../../core/models/order.dart';
import '../../../core/models/promotion.dart';
import '../../../core/models/restaurant_table.dart';
import '../../../features/payments/providers/payment_provider.dart';
import '../../../features/payments/screens/payment_screen.dart';
import '../../../features/payments/services/receipt_printer.dart';
import '../../../features/products/providers/products_provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../features/settings/providers/settings_provider.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../../../shared/utils/error_utils.dart';
import '../../../shared/utils/grid_utils.dart';
import '../../../shared/utils/natural_compare.dart';

class OrderScreen extends ConsumerStatefulWidget {
  final int? orderId;
  // Set when reopening an order that was created offline and hasn't synced
  // to the server yet (so it has no orderId to look up by).
  final String? offlineRef;
  const OrderScreen({super.key, this.orderId, this.offlineRef});

  @override
  ConsumerState<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends ConsumerState<OrderScreen> {
  bool _loading = false;
  bool _saving = false;
  bool _printingBill = false;
  int? _selectedCategoryId;
  String _search = '';
  // The persisted order id — null until the first auto-save creates it.
  int? _orderId;
  // If created while offline, the queued order's local ref — kept so
  // repeated auto-saves update the *same* pending order instead of
  // creating a new one each time (that new one never gets an id, so
  // _orderId alone can't track it).
  String? _offlineOrderRef;
  Timer? _autoSaveDebounce;
  bool _suppressNextAutoSave = false;

  @override
  void initState() {
    super.initState();
    _orderId = widget.orderId;
    _offlineOrderRef = widget.offlineRef;
    if (_orderId != null) {
      _loadExistingOrder();
    } else if (_offlineOrderRef != null) {
      _loadOfflineOrder(_offlineOrderRef!);
    }
  }

  Future<void> _loadOfflineOrder(String offlineRef) async {
    setState(() => _loading = true);
    try {
      final order = await LocalDb.getPendingOrderByRef(offlineRef);
      if (order != null) {
        _suppressNextAutoSave = true;
        ref.read(cartProvider.notifier).loadFromOrder(order);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _autoSaveDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadExistingOrder() async {
    setState(() => _loading = true);
    try {
      final order = await OrderService.fetchOrder(_orderId!);
      _suppressNextAutoSave = true;
      ref.read(cartProvider.notifier).loadFromOrder(order);
    } catch (e) {
      // Offline: fall back to whatever's cached locally for this order —
      // prefers a not-yet-synced edit over the last-known-from-server
      // snapshot, so reopening the screen doesn't discard queued changes.
      final cached = await LocalDb.getCachedOrderById(_orderId!);
      if (cached != null) {
        _suppressNextAutoSave = true;
        ref.read(cartProvider.notifier).loadFromOrder(cached);
      } else if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _scheduleAutoSave() {
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 600), _autoSave);
  }

  // Coalesces overlapping auto-saves: if one is already in flight (e.g.
  // stuck waiting on a dead connection) and another edit comes in, we don't
  // fire a second, fully-parallel save — that's what was causing "saved
  // but then clobbered by an older, slower save" and duplicate offline
  // records. Instead we just mark that another save is needed and it runs
  // right after the current one finishes, by which point _orderId/
  // _offlineOrderRef are already correctly set.
  Future<void>? _autoSaveFuture;
  bool _autoSaveQueued = false;

  Future<void> _autoSave() {
    _autoSaveDebounce?.cancel();
    if (_autoSaveFuture != null) {
      _autoSaveQueued = true;
      return _autoSaveFuture!;
    }
    final future = _runAutoSave();
    _autoSaveFuture = future;
    return future;
  }

  Future<void> _runAutoSave() async {
    final cart = ref.read(cartProvider);
    if (cart.items.isNotEmpty) {
      if (mounted) setState(() => _saving = true);
      try {
        final order = await OrderService.createOrUpdate(
          cart,
          existingOrderId: _orderId,
          offlineRef: _offlineOrderRef,
        );
        _orderId = order.id ?? _orderId;
        _offlineOrderRef = order.offlineRef ?? _offlineOrderRef;
        ref.invalidate(openOrdersProvider);
        if (cart.tableId != null) ref.invalidate(tablesProvider);
      } catch (_) {
        // Silent: offline edits are queued locally and retried on the next
        // change, a snackbar on every edit would be noisy for auto-save.
      } finally {
        if (mounted) setState(() => _saving = false);
      }
    }
    _autoSaveFuture = null;
    if (_autoSaveQueued) {
      _autoSaveQueued = false;
      await _autoSave();
    }
  }

  Future<void> _saveAndExit() async {
    await _autoSave();
    // Always land on the open-orders list (not just "whatever pushed this
    // screen"), regardless of how this order screen was reached.
    if (mounted) context.go('/cashier');
  }

  Future<void> _printBill() async {
    if (_printingBill) return;
    final initialCart = ref.read(cartProvider);
    if (initialCart.items.isEmpty) return;

    setState(() => _printingBill = true);
    try {
      // Flush the debounce first so the bill corresponds to a durable open
      // order, while still allowing the same flow to work in offline mode.
      await _autoSave();
      final cart = ref.read(cartProvider);
      final settings = await ref.read(settingsProvider.future);
      final order = Order(
        id: _orderId,
        offlineRef: _offlineOrderRef,
        tableId: cart.tableId,
        tableName: cart.tableName,
        orderType: cart.orderType,
        status: 'open',
        notes: cart.notes,
        items: cart.items,
      );
      final summary = calculateOfflineCheckout(cart.items, settings);
      final user = ref.read(authProvider).user;

      if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
        throw Exception(
          'Bluetooth thermal printing is available only in the Android POS app.',
        );
      }
      await ReceiptPrinter.printBill(
        order: order,
        summary: summary,
        placeLabel: orderPlaceLabel(
          orderType: order.orderType,
          tableName: order.tableName,
          tableId: order.tableId,
          tables: ref.read(tablesProvider).valueOrNull,
        ),
        storeName: settings.storeName,
        storeAddress: settings.storeAddress,
        storePhone: settings.storePhone,
        settings: settings,
        employeeName: user?.fullName.isNotEmpty == true
            ? user!.fullName
            : user?.username,
        posName: user?.username,
      );
    } catch (e) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Printer Error'),
            content: Text(
              'Failed to print bill.\n\n$e\n\n'
              'Pair the thermal printer in Android Bluetooth settings, then '
              'connect it from POS Settings and try again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _printingBill = false);
    }
  }

  Future<void> _proceedToPayment({int? promotionId, String? promoCode}) async {
    final cart = ref.read(cartProvider);
    if (cart.items.isEmpty) return;
    final extra = <String, dynamic>{};
    if (promotionId != null) extra['promotionId'] = promotionId;
    if (promoCode != null && promoCode.isNotEmpty) {
      extra['promoCode'] = promoCode;
    }

    _autoSaveDebounce?.cancel();
    // Let any auto-save already in flight finish first (and pick up its
    // resulting _orderId/_offlineOrderRef) instead of racing it with our
    // own save of what might be the same cart state.
    if (_autoSaveFuture != null) await _autoSaveFuture;
    setState(() => _loading = true);
    try {
      final order = await OrderService.createOrUpdate(
        cart,
        existingOrderId: _orderId,
        offlineRef: _offlineOrderRef,
      );
      _orderId = order.id ?? _orderId;
      _offlineOrderRef = order.offlineRef ?? _offlineOrderRef;
      if (mounted) {
        ref.invalidate(openOrdersProvider);
        if (cart.tableId != null) ref.invalidate(tablesProvider);
        if (order.id != null) {
          context.push(
            '/cashier/payment/${order.id}',
            extra: extra.isEmpty ? null : extra,
          );
        } else {
          // Offline order: go to payment screen with local calculation
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PaymentScreen(orderId: -1, offlineOrder: order),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Saves the cart and returns the order as the server now has it (fresh
  /// item ids — every save recreates the lines). Null when offline.
  Future<Order?> _serverOrder(String action) async {
    _autoSaveDebounce?.cancel();
    await _autoSave();
    final orderId = _orderId;
    if (orderId == null) {
      _showMessage('Connect to the internet to $action.');
      return null;
    }
    try {
      return await OrderService.fetchOrder(orderId);
    } catch (e) {
      _showMessage(friendlyError(e));
      return null;
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showServerOrder(Order order) {
    _suppressNextAutoSave = true;
    ref.read(cartProvider.notifier).loadFromOrder(order);
    ref.invalidate(openOrdersProvider);
    ref.invalidate(tablesProvider);
  }

  Future<void> _moveTable() async {
    final order = await _serverOrder('move tables');
    if (order == null || !mounted) return;
    ref.invalidate(tablesProvider);
    final List<RestaurantTable> tables;
    try {
      tables = await ref.read(tablesProvider.future);
    } catch (e) {
      _showMessage(friendlyError(e));
      return;
    }
    final free =
        tables.where((t) => !t.isOccupied && t.id != order.tableId).toList()
          ..sort((a, b) => naturalCompare(a.name, b.name));
    if (!mounted) return;
    final target = await showDialog<RestaurantTable>(
      context: context,
      builder: (_) => _MoveTableDialog(tables: free),
    );
    if (target == null || !mounted) return;
    setState(() => _loading = true);
    try {
      final moved = await OrderService.moveTable(order.id!, target.id);
      _showServerOrder(moved);
      _showMessage('Moved to ${target.name}');
    } catch (e) {
      _showMessage(friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _splitBill() async {
    final order = await _serverOrder('split the bill');
    if (order == null || !mounted) return;
    if (order.items.length < 2 && order.items.every((i) => i.quantity < 2)) {
      _showMessage('Add at least two items before splitting the bill.');
      return;
    }
    final selection = await showModalBottomSheet<Map<int, int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SplitBillSheet(order: order),
    );
    if (selection == null || selection.isEmpty || !mounted) return;
    setState(() => _loading = true);
    try {
      final result = await OrderService.splitOrder(order.id!, selection);
      _showServerOrder(result.source);
      if (mounted) context.push('/cashier/payment/${result.newOrder.id}');
    } catch (e) {
      _showMessage(friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
    final productsAsync = ref.watch(productsProvider);

    // Auto-save on every cart edit (add/remove/qty/notes/table) instead of
    // requiring an explicit Save tap. Skip the one triggered by loading an
    // existing order into the cart — that's already what's on the server.
    ref.listen<CartState>(cartProvider, (previous, next) {
      if (_suppressNextAutoSave) {
        _suppressNextAutoSave = false;
        return;
      }
      _scheduleAutoSave();
    });

    final place = orderPlaceLabel(
      orderType: cart.orderType,
      tableName: cart.tableName,
      tableId: cart.tableId,
      tables: ref.watch(tablesProvider).valueOrNull,
    );
    final title = place == 'No table' ? 'New Order' : place;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _saveAndExit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: [
            if (cart.items.isNotEmpty)
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert, color: Colors.white),
                enabled: !_loading && !_printingBill,
                onSelected: (action) => switch (action) {
                  'move' => _moveTable(),
                  'split' => _splitBill(),
                  _ => null,
                },
                itemBuilder: (_) => [
                  if (cart.orderType != OrderTypes.takeAway)
                    const PopupMenuItem(
                      value: 'move',
                      child: ListTile(
                        leading: Icon(Icons.swap_horiz),
                        title: Text('Move Table'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'split',
                    child: ListTile(
                      leading: Icon(Icons.call_split),
                      title: Text('Split Bill'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            if (cart.items.isNotEmpty)
              TextButton.icon(
                onPressed: _saving || _printingBill ? null : _printBill,
                icon: _printingBill
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white70,
                        ),
                      )
                    : const Icon(Icons.print_outlined),
                label: Text(_printingBill ? 'Printing…' : 'Print Bill'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
              ),
            if (_saving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white70,
                    ),
                  ),
                ),
              )
            else if (cart.items.isNotEmpty)
              TextButton.icon(
                onPressed: _printingBill ? null : _saveAndExit,
                icon: const Icon(Icons.save, color: Colors.white),
                label: const Text(
                  'Save',
                  style: TextStyle(color: Colors.white),
                ),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(
                builder: (_, constraints) {
                  final isWide = constraints.maxWidth >= 680;
                  final catalog = productsAsync.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text(loadError(e))),
                    data: (data) => _ProductCatalog(
                      products: data.products,
                      categories: data.categories,
                      selectedCategoryId: _selectedCategoryId,
                      onCategorySelected: (id) =>
                          setState(() => _selectedCategoryId = id),
                      search: _search,
                      onSearchChanged: (v) => setState(() => _search = v),
                    ),
                  );

                  if (isWide) {
                    return Row(
                      children: [
                        Expanded(flex: 3, child: catalog),
                        Container(
                          width: 300,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            border: Border(
                              left: BorderSide(
                                color: Theme.of(
                                  context,
                                ).colorScheme.outlineVariant,
                              ),
                            ),
                          ),
                          child: _CartPanel(
                            cart: cart,
                            onCheckout: ({promotionId, promoCode}) =>
                                _proceedToPayment(
                                  promotionId: promotionId,
                                  promoCode: promoCode,
                                ),
                          ),
                        ),
                      ],
                    );
                  }

                  return Stack(
                    children: [
                      catalog,
                      if (cart.items.isNotEmpty)
                        Positioned(
                          bottom: 12,
                          left: 16,
                          right: 16,
                          child: ElevatedButton.icon(
                            onPressed: () => _showCartSheet(context),
                            icon: const Icon(Icons.shopping_cart),
                            label: Text(
                              '${cart.totalItems} items · ${formatRM(cart.subtotal)}',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1E6FD9),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  void _showCartSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        // Watch the cart live: the sheet is a separate route, so a snapshot
        // passed in at open time would go stale as items are added/edited
        // without closing and reopening it.
        child: Consumer(
          builder: (context, ref, _) => _CartPanel(
            cart: ref.watch(cartProvider),
            onCheckout: ({promotionId, promoCode}) {
              Navigator.pop(context);
              _proceedToPayment(promotionId: promotionId, promoCode: promoCode);
            },
          ),
        ),
      ),
    );
  }
}

class ProductsData {
  final List<Product> products;
  final List<dynamic> categories;
  const ProductsData({required this.products, required this.categories});
}

class _ProductCatalog extends ConsumerStatefulWidget {
  final List<Product> products;
  final List<dynamic> categories;
  final int? selectedCategoryId;
  final ValueChanged<int?> onCategorySelected;
  final String search;
  final ValueChanged<String> onSearchChanged;

  const _ProductCatalog({
    required this.products,
    required this.categories,
    required this.selectedCategoryId,
    required this.onCategorySelected,
    required this.search,
    required this.onSearchChanged,
  });

  @override
  ConsumerState<_ProductCatalog> createState() => _ProductCatalogState();
}

class _ProductCatalogState extends ConsumerState<_ProductCatalog> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.products.where((p) {
      final matchCat =
          widget.selectedCategoryId == null ||
          p.categoryId == widget.selectedCategoryId;
      final matchSearch =
          widget.search.isEmpty ||
          p.name.toLowerCase().contains(widget.search.toLowerCase());
      return matchCat && matchSearch;
    }).toList();
    if (widget.selectedCategoryId == null) {
      filtered.sort((a, b) => naturalCompare(a.name, b.name));
    }

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search...',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: widget.search.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        _searchCtrl.clear();
                        widget.onSearchChanged('');
                      },
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onChanged: widget.onSearchChanged,
          ),
        ),
        // Category filter dropdown
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: DropdownButtonFormField<int?>(
            initialValue: widget.selectedCategoryId,
            isExpanded: true,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              prefixIcon: const Icon(Icons.filter_list_rounded, size: 18),
            ),
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('All Categories'),
              ),
              ...widget.categories.map(
                (c) => DropdownMenuItem(
                  value: c.id as int,
                  child: Text(c.name as String),
                ),
              ),
            ],
            onChanged: widget.onCategorySelected,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const gridPadding = EdgeInsets.all(10);
              return GridView.builder(
                padding: gridPadding,
                gridDelegate: responsiveGridDelegate(
                  constraints: constraints,
                  padding: gridPadding,
                ),
                itemCount: filtered.length,
                itemBuilder: (ctx, i) => _ProductTile(product: filtered[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ProductTile extends ConsumerWidget {
  final Product product;
  const _ProductTile({required this.product});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    final cartItem = cart.items
        .where((i) => i.productId == product.id)
        .firstOrNull;
    final qty = cartItem?.quantity ?? 0;
    final inCart = cartItem != null;

    Future<void> askWeight() async {
      final ctrl = TextEditingController(
        text: cartItem?.weight != null
            ? cartItem!.weight!.toStringAsFixed(3)
            : '',
      );
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(inCart ? 'Update Weight' : 'Enter Weight'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${product.name}  ·  ${formatRM(product.price)}/kg',
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Weight',
                  suffixText: 'kg',
                ),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
            ],
          ),
          actions: [
            if (inCart)
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx, false);
                  ref.read(cartProvider.notifier).updateQuantity(product.id, 0);
                },
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Remove'),
              ),
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
        final weight = double.tryParse(ctrl.text.trim());
        if (weight != null && weight > 0) {
          ref.read(cartProvider.notifier).addWeightProduct(product, weight);
        }
      }
    }

    return GestureDetector(
      onTap: () {
        if (product.soldByWeight) {
          askWeight();
        } else {
          ref.read(cartProvider.notifier).addProduct(product);
        }
      },
      child: Card(
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Center(
                      child: product.imageUrl != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.network(
                                product.imageUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const Icon(
                                  Icons.restaurant,
                                  size: 36,
                                  color: Colors.grey,
                                ),
                              ),
                            )
                          : Icon(
                              product.soldByWeight
                                  ? Icons.scale
                                  : Icons.restaurant,
                              size: 36,
                              color: product.soldByWeight
                                  ? Colors.teal
                                  : Colors.grey,
                            ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    product.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      Text(
                        product.soldByWeight
                            ? '${formatRM(product.price)}/kg'
                            : formatRM(product.price),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF1E6FD9),
                        ),
                      ),
                      if (product.soldByWeight) ...[
                        const SizedBox(width: 3),
                        const Icon(Icons.scale, size: 10, color: Colors.teal),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (inCart)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Color(0xFF1E6FD9),
                    shape: BoxShape.circle,
                  ),
                  child: product.soldByWeight
                      ? const Icon(Icons.check, size: 11, color: Colors.white)
                      : Text(
                          '$qty',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CartPanel extends ConsumerStatefulWidget {
  final CartState cart;
  final void Function({int? promotionId, String? promoCode}) onCheckout;
  const _CartPanel({required this.cart, required this.onCheckout});

  @override
  ConsumerState<_CartPanel> createState() => _CartPanelState();
}

class _CartPanelState extends ConsumerState<_CartPanel> {
  Promotion? _selectedPromo;
  final _promoCodeCtrl = TextEditingController();

  @override
  void dispose() {
    _promoCodeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cart = widget.cart;
    final canPromo = ref.watch(authProvider).user?.canManagePromotion ?? true;
    final promosAsync = canPromo ? ref.watch(activePromotionsProvider) : null;
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          color: colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              Icon(
                Icons.shopping_cart_outlined,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                'ORDER (${cart.totalItems})',
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (cart.items.isNotEmpty)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 0),
                    foregroundColor: Colors.red,
                  ),
                  onPressed: () => ref.read(cartProvider.notifier).clear(),
                  child: const Text('Clear'),
                ),
            ],
          ),
        ),
        Expanded(
          child: cart.items.isEmpty
              ? Center(
                  child: Text(
                    'No items yet',
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  itemCount: cart.items.length,
                  itemBuilder: (ctx, i) =>
                      _buildCartItem(context, ref, cart.items[i]),
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Subtotal row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Subtotal',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  Text(
                    formatRM(cart.subtotal),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Promotion dropdown — hidden when cashier has no promotion permission
              if (canPromo)
                promosAsync!.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (promos) {
                    final listPromos = promos
                        .where((p) => p.type != 'promo_code')
                        .toList();
                    if (listPromos.isEmpty && _promoCodeCtrl.text.isEmpty) {
                      return _promoCodeField();
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (listPromos.isNotEmpty)
                          DropdownButtonFormField<Promotion?>(
                            initialValue: _selectedPromo,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                              labelText: 'Promotion',
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: null,
                                child: Text('None'),
                              ),
                              ...listPromos.map(
                                (p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(
                                    p.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: (p) => setState(() {
                              _selectedPromo = p;
                              _promoCodeCtrl.clear();
                            }),
                          ),
                        const SizedBox(height: 6),
                        _promoCodeField(),
                      ],
                    );
                  },
                ),
              const SizedBox(height: 10),
              // Checkout button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: cart.items.isEmpty
                      ? null
                      : () => widget.onCheckout(
                          promotionId: _selectedPromo?.id,
                          promoCode: _promoCodeCtrl.text.trim().isEmpty
                              ? null
                              : _promoCodeCtrl.text.trim(),
                        ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Checkout', style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _promoCodeField() => TextField(
    controller: _promoCodeCtrl,
    decoration: const InputDecoration(
      isDense: true,
      border: OutlineInputBorder(),
      labelText: 'Promo code (optional)',
      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    ),
    onChanged: (v) {
      if (v.isNotEmpty && _selectedPromo != null) {
        setState(() => _selectedPromo = null);
      }
    },
  );

  Widget _buildCartItem(BuildContext context, WidgetRef ref, OrderItem item) {
    if (item.weight != null) {
      // Weight-based item
      return ListTile(
        dense: true,
        leading: const Icon(Icons.scale, size: 18, color: Colors.teal),
        title: Text(item.productName, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          '${item.weight!.toStringAsFixed(3)} kg × ${formatRM(item.unitPrice)}/kg',
          style: const TextStyle(fontSize: 11),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatRM(item.subtotal),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => ref
                  .read(cartProvider.notifier)
                  .updateQuantity(item.productId, 0),
              child: const Icon(Icons.close, size: 16, color: Colors.red),
            ),
          ],
        ),
      );
    }

    // Normal quantity-based item
    return ListTile(
      dense: true,
      title: Text(item.productName, style: const TextStyle(fontSize: 13)),
      subtitle: Text(
        formatRM(item.unitPrice),
        style: const TextStyle(fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _QtyButton(
            icon: Icons.remove,
            onTap: () => ref
                .read(cartProvider.notifier)
                .updateQuantity(item.productId, item.quantity - 1),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '${item.quantity}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          _QtyButton(
            icon: Icons.add,
            onTap: () => ref
                .read(cartProvider.notifier)
                .updateQuantity(item.productId, item.quantity + 1),
          ),
        ],
      ),
    );
  }
}

class _QtyButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _QtyButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colorScheme.surfaceContainerHighest,
        ),
        child: Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// Picks a free table to move the whole order to.
class _MoveTableDialog extends StatelessWidget {
  final List<RestaurantTable> tables;

  const _MoveTableDialog({required this.tables});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Move to table'),
      content: SizedBox(
        width: 360,
        child: tables.isEmpty
            ? const Text('All other tables are occupied.')
            : Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final table in tables)
                    ActionChip(
                      avatar: const Icon(Icons.table_restaurant, size: 18),
                      label: Text(table.name),
                      onPressed: () => Navigator.pop(context, table),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Chooses which items (and how many of each) go on a separate bill.
/// Returns order item id -> quantity to move.
class _SplitBillSheet extends StatefulWidget {
  final Order order;

  const _SplitBillSheet({required this.order});

  @override
  State<_SplitBillSheet> createState() => _SplitBillSheetState();
}

class _SplitBillSheetState extends State<_SplitBillSheet> {
  final Map<int, int> _moving = {};

  List<OrderItem> get _items =>
      widget.order.items.where((i) => i.id != null).toList();

  double get _newSubtotal => _items.fold(0, (sum, item) {
    final qty = _moving[item.id] ?? 0;
    if (qty == 0) return sum;
    return sum + (item.weight != null ? item.subtotal : item.unitPrice * qty);
  });

  bool get _movesEverything =>
      _items.every((item) => (_moving[item.id] ?? 0) == item.quantity);

  void _set(OrderItem item, int qty) => setState(() {
    if (qty <= 0) {
      _moving.remove(item.id);
    } else {
      _moving[item.id!] = qty;
    }
  });

  @override
  Widget build(BuildContext context) {
    final nothingSelected = _moving.isEmpty;
    final canSplit = !nothingSelected && !_movesEverything;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Split Bill', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Choose what goes on the separate bill. The rest stays on this table\'s bill.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [for (final item in _items) _row(item)],
              ),
            ),
            const Divider(),
            Row(
              children: [
                const Expanded(child: Text('New bill subtotal')),
                Text(
                  formatRM(_newSubtotal),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            if (_movesEverything && !nothingSelected) ...[
              const SizedBox(height: 6),
              Text(
                'Leave at least one item on the original bill.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.call_split),
              label: const Text('Split & Pay'),
              onPressed: canSplit
                  ? () => Navigator.pop(context, Map.of(_moving))
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(OrderItem item) {
    final moving = _moving[item.id] ?? 0;
    final detail = item.weight != null
        ? '${item.weight!.toStringAsFixed(3)} kg · ${formatRM(item.subtotal)}'
        : '${item.quantity} × ${formatRM(item.unitPrice)}';
    if (item.weight != null) {
      return CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: moving > 0,
        title: Text(item.productName),
        subtitle: Text(detail),
        onChanged: (v) => _set(item, v == true ? item.quantity : 0),
      );
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(item.productName),
      subtitle: Text(detail),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: moving > 0 ? () => _set(item, moving - 1) : null,
          ),
          SizedBox(
            width: 48,
            child: Text(
              '$moving / ${item.quantity}',
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: moving < item.quantity
                ? () => _set(item, moving + 1)
                : null,
          ),
        ],
      ),
    );
  }
}
