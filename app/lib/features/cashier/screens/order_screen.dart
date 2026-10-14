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
import '../../../shared/theme/app_theme.dart';
import '../../../shared/utils/toast.dart';

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
        showToast(context, friendlyError(e), error: true);
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
        showToast(context, friendlyError(e), error: true);
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
    showToast(context, message, error: true);
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
      builder: (_) => _MoveTableDialog(
        tables: free,
        currentTableName: order.tableName ?? 'Current table',
      ),
    );
    if (target == null || !mounted) return;
    setState(() => _loading = true);
    try {
      final moved = await OrderService.moveTable(order.id!, target.id);
      _showServerOrder(moved);
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
    final selection = await showDialog<Map<int, int>>(
      context: context,
      builder: (_) => _SplitBillDialog(order: order),
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
    final compact = MediaQuery.sizeOf(context).width < 600;

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
                  'print' => _printBill(),
                  'save' => _saveAndExit(),
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
                  if (compact) const PopupMenuDivider(),
                  if (compact)
                    const PopupMenuItem(
                      value: 'print',
                      child: ListTile(
                        leading: Icon(Icons.print_outlined),
                        title: Text('Print Bill'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  if (compact)
                    const PopupMenuItem(
                      value: 'save',
                      child: ListTile(
                        leading: Icon(Icons.save_outlined),
                        title: Text('Save & Close'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                ],
              ),
            if (cart.items.isNotEmpty && !compact)
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
            else if (cart.items.isNotEmpty && !compact)
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
                        Expanded(flex: 5, child: catalog),
                        Container(
                          width: constraints.maxWidth >= 1000 ? 370 : 320,
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

    final narrow = MediaQuery.sizeOf(context).width < 600;
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(10));
    return Column(
      children: [
        // One row: category dropdown on the left (thumb side), search after.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Row(
            children: [
              SizedBox(
                width: narrow ? 140 : 220,
                child: DropdownButtonFormField<int?>(
                  initialValue: widget.selectedCategoryId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: border,
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All')),
                    for (final c in widget.categories)
                      DropdownMenuItem(
                        value: c.id as int,
                        child: Text(
                          c.name as String,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: widget.onCategorySelected,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'Search',
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
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: border,
                  ),
                  onChanged: widget.onSearchChanged,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const gridPadding = EdgeInsets.fromLTRB(12, 2, 12, 24);
              // Size tiles from the height *without* the keyboard, so opening
              // search doesn't squash every tile; the grid just scrolls.
              // Read it from the window: Scaffold strips the keyboard inset
              // from MediaQuery for its body, so that would always be 0.
              final view = View.of(context);
              final keyboard = view.viewInsets.bottom / view.devicePixelRatio;
              return GridView.builder(
                padding: gridPadding,
                gridDelegate: responsiveGridDelegate(
                  constraints: constraints.copyWith(
                    maxHeight: constraints.maxHeight + keyboard,
                  ),
                  padding: gridPadding,
                  narrowColumns: constraints.maxWidth < 430 ? 2 : 3,
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
class _MoveTableDialog extends StatefulWidget {
  final List<RestaurantTable> tables;
  final String currentTableName;

  const _MoveTableDialog({
    required this.tables,
    required this.currentTableName,
  });

  @override
  State<_MoveTableDialog> createState() => _MoveTableDialogState();
}

class _MoveTableDialogState extends State<_MoveTableDialog> {
  RestaurantTable? _selected;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.sizeOf(context).height * .82,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DialogHeader(
              icon: Icons.swap_horiz_rounded,
              title: 'Move to table',
              subtitle: 'Moving from ${widget.currentTableName}',
            ),
            Flexible(
              child: widget.tables.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(40),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.event_busy_outlined,
                            size: 40,
                            color: AppTheme.textHint,
                          ),
                          SizedBox(height: 12),
                          Text(
                            'No free tables available',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'All other tables are currently occupied.',
                            style: TextStyle(color: AppTheme.textHint),
                          ),
                        ],
                      ),
                    )
                  : GridView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(20),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 190,
                            mainAxisExtent: 104,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                      itemCount: widget.tables.length,
                      itemBuilder: (context, index) {
                        final table = widget.tables[index];
                        final selected = _selected?.id == table.id;
                        return InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => setState(() => _selected = table),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: selected
                                  ? const Color(0xFFEDF5FF)
                                  : AppTheme.cream,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: selected
                                    ? AppTheme.primaryBlue
                                    : AppTheme.borderLight,
                                width: selected ? 2 : 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.table_restaurant_rounded,
                                  color: selected
                                      ? AppTheme.primaryBlue
                                      : AppTheme.textSecondary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        table.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      const Text(
                                        'Available',
                                        style: TextStyle(
                                          color: AppTheme.success,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (selected)
                                  const Icon(
                                    Icons.check_circle_rounded,
                                    color: AppTheme.primaryBlue,
                                    size: 20,
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppTheme.borderLight)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _selected == null
                          ? 'Select a destination table'
                          : '${widget.currentTableName}  →  ${_selected!.name}',
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _selected == null
                        ? null
                        : () => Navigator.pop(context, _selected),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: const Text('Move order'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chooses which items (and how many of each) go on a separate bill.
/// Returns order item id -> quantity to move.
class _SplitBillDialog extends StatefulWidget {
  final Order order;

  const _SplitBillDialog({required this.order});

  @override
  State<_SplitBillDialog> createState() => _SplitBillDialogState();
}

class _SplitBillDialogState extends State<_SplitBillDialog> {
  final Map<int, int> _moving = {};
  bool _showNewBill = false;

  List<OrderItem> get _items =>
      widget.order.items.where((i) => i.id != null).toList();

  double get _newSubtotal => _items.fold(0, (sum, item) {
    final qty = _moving[item.id] ?? 0;
    if (qty == 0) return sum;
    return sum + (item.weight != null ? item.subtotal : item.unitPrice * qty);
  });

  double get _originalSubtotal => widget.order.subtotal - _newSubtotal;

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
    final screen = MediaQuery.sizeOf(context);
    final isPhone = screen.width < 600;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SizedBox(
        width: screen.width.clamp(0, 1000).toDouble(),
        height: (screen.height * .86).clamp(480, 760).toDouble(),
        child: Column(
          children: [
            _DialogHeader(
              icon: Icons.call_split,
              title: 'Split bill',
              subtitle: isPhone
                  ? 'Review each bill and move items'
                  : 'Move items between the original and new bill',
            ),
            Expanded(
              child: Container(
                color: AppTheme.cream,
                padding: EdgeInsets.all(isPhone ? 10 : 16),
                child: isPhone
                    ? Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: AppTheme.creamDeep,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: _billTab(
                                    label: 'Original',
                                    amount: _originalSubtotal,
                                    selected: !_showNewBill,
                                    onTap: () =>
                                        setState(() => _showNewBill = false),
                                  ),
                                ),
                                Expanded(
                                  child: _billTab(
                                    label: 'New bill',
                                    amount: _newSubtotal,
                                    selected: _showNewBill,
                                    onTap: () =>
                                        setState(() => _showNewBill = true),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Expanded(
                            child: _billPanel(
                              title: _showNewBill
                                  ? 'New bill'
                                  : 'Original bill',
                              subtitle: _showNewBill
                                  ? 'Continues to payment'
                                  : 'Stays on this table',
                              subtotal: _showNewBill
                                  ? _newSubtotal
                                  : _originalSubtotal,
                              isNewBill: _showNewBill,
                            ),
                          ),
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _billPanel(
                              title: 'Original bill',
                              subtitle: 'Stays on this table',
                              subtotal: _originalSubtotal,
                              isNewBill: false,
                            ),
                          ),
                          Container(
                            width: 42,
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.compare_arrows_rounded,
                              color: AppTheme.primaryBlue,
                            ),
                          ),
                          Expanded(
                            child: _billPanel(
                              title: 'New bill',
                              subtitle: 'Continues to payment',
                              subtotal: _newSubtotal,
                              isNewBill: true,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            Container(
              padding: EdgeInsets.fromLTRB(
                isPhone ? 12 : 18,
                10,
                isPhone ? 12 : 18,
                12,
              ),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppTheme.borderLight)),
              ),
              child: isPhone
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _splitStatus(nothingSelected),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _movesEverything && !nothingSelected
                                ? AppTheme.danger
                                : AppTheme.textSecondary,
                            fontWeight: FontWeight.w500,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Cancel'),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(
                                icon: const Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 18,
                                ),
                                label: const Text('Split & pay'),
                                onPressed: canSplit
                                    ? () => Navigator.pop(
                                        context,
                                        Map.of(_moving),
                                      )
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: Text(
                            _splitStatus(nothingSelected),
                            style: TextStyle(
                              color: _movesEverything && !nothingSelected
                                  ? AppTheme.danger
                                  : AppTheme.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          icon: const Icon(
                            Icons.arrow_forward_rounded,
                            size: 18,
                          ),
                          label: const Text('Split & pay'),
                          onPressed: canSplit
                              ? () => Navigator.pop(context, Map.of(_moving))
                              : null,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _splitStatus(bool nothingSelected) {
    if (_movesEverything && !nothingSelected) {
      return 'Leave at least one item on the original bill.';
    }
    if (nothingSelected) return 'Move at least one item to the new bill.';
    return '${_moving.values.fold<int>(0, (a, b) => a + b)} item(s) moved';
  }

  Widget _billTab({
    required String label,
    required double amount,
    required bool selected,
    required VoidCallback onTap,
  }) => Material(
    color: selected ? Colors.white : Colors.transparent,
    borderRadius: BorderRadius.circular(9),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        child: Column(
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              formatRM(amount),
              style: TextStyle(
                color: selected ? AppTheme.primaryBlue : AppTheme.textHint,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _billPanel({
    required String title,
    required String subtitle,
    required double subtotal,
    required bool isNewBill,
  }) {
    final visible = _items.where((item) {
      final moving = _moving[item.id] ?? 0;
      return isNewBill ? moving > 0 : moving < item.quantity;
    }).toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isNewBill && _moving.isNotEmpty
              ? AppTheme.primaryBlue.withValues(alpha: .55)
              : AppTheme.borderLight,
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isNewBill ? const Color(0xFFEDF5FF) : AppTheme.creamDeep,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(13),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: isNewBill ? AppTheme.primaryBlue : AppTheme.charcoal,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isNewBill
                        ? Icons.receipt_long_outlined
                        : Icons.table_restaurant_outlined,
                    color: Colors.white,
                    size: 19,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textHint,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Text(
                        isNewBill
                            ? 'Items moved here will appear on this bill.'
                            : 'No items remaining.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppTheme.textHint,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const Divider(indent: 14),
                    itemBuilder: (_, index) =>
                        _billItem(visible[index], isNewBill: isNewBill),
                  ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppTheme.borderLight)),
            ),
            child: Row(
              children: [
                const Text(
                  'Subtotal',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
                const Spacer(),
                Text(
                  formatRM(subtotal),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _billItem(OrderItem item, {required bool isNewBill}) {
    final moving = _moving[item.id] ?? 0;
    final shownQty = isNewBill ? moving : item.quantity - moving;
    final amount = item.weight != null
        ? item.subtotal
        : item.unitPrice * shownQty;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      title: Text(
        item.productName,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
      subtitle: Text(
        item.weight != null
            ? '${item.weight!.toStringAsFixed(3)} kg · ${formatRM(amount)}'
            : '$shownQty × ${formatRM(item.unitPrice)} · ${formatRM(amount)}',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: IconButton.filledTonal(
        tooltip: isNewBill ? 'Return to original bill' : 'Move to new bill',
        visualDensity: VisualDensity.compact,
        icon: Icon(
          isNewBill ? Icons.arrow_back_rounded : Icons.arrow_forward_rounded,
          size: 18,
        ),
        onPressed: isNewBill
            ? () => _set(item, item.weight != null ? 0 : moving - 1)
            : () =>
                  _set(item, item.weight != null ? item.quantity : moving + 1),
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _DialogHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(22, 16, 12, 16),
    color: AppTheme.charcoal,
    child: Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded, color: Colors.white),
        ),
      ],
    ),
  );
}
