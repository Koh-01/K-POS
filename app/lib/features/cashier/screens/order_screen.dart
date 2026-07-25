import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/cashier_provider.dart';
import '../../../core/models/product.dart';
import '../../../core/models/order_item.dart';
import '../../../core/models/promotion.dart';
import '../../../features/payments/providers/payment_provider.dart';
import '../../../features/payments/screens/payment_screen.dart';
import '../../../features/products/providers/products_provider.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../../../shared/utils/error_utils.dart';
import '../../../shared/utils/grid_utils.dart';

class OrderScreen extends ConsumerStatefulWidget {
  final int? orderId;
  const OrderScreen({super.key, this.orderId});

  @override
  ConsumerState<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends ConsumerState<OrderScreen> {
  bool _loading = false;
  bool _saving = false;
  int? _selectedCategoryId;
  String _search = '';
  // The persisted order id — null until the first auto-save creates it.
  int? _orderId;
  Timer? _autoSaveDebounce;
  bool _suppressNextAutoSave = false;

  @override
  void initState() {
    super.initState();
    _orderId = widget.orderId;
    if (_orderId != null) _loadExistingOrder();
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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _scheduleAutoSave() {
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 600), _autoSave);
  }

  Future<void> _autoSave() async {
    _autoSaveDebounce?.cancel();
    final cart = ref.read(cartProvider);
    if (cart.items.isEmpty) return;
    if (mounted) setState(() => _saving = true);
    try {
      final order =
          await OrderService.createOrUpdate(cart, existingOrderId: _orderId);
      _orderId = order.id ?? _orderId;
      ref.invalidate(openOrdersProvider);
      if (cart.tableId != null) ref.invalidate(tablesProvider);
    } catch (_) {
      // Silent: offline edits are queued locally and retried on the next
      // change, a snackbar on every edit would be noisy for auto-save.
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveAndExit() async {
    await _autoSave();
    // Always land on the open-orders list (not just "whatever pushed this
    // screen"), regardless of how this order screen was reached.
    if (mounted) context.go('/cashier');
  }

  Future<void> _proceedToPayment({int? promotionId, String? promoCode}) async {
    final cart = ref.read(cartProvider);
    if (cart.items.isEmpty) return;
    final extra = <String, dynamic>{};
    if (promotionId != null) extra['promotionId'] = promotionId;
    if (promoCode != null && promoCode.isNotEmpty) extra['promoCode'] = promoCode;

    _autoSaveDebounce?.cancel();
    setState(() => _loading = true);
    try {
      final order =
          await OrderService.createOrUpdate(cart, existingOrderId: _orderId);
      _orderId = order.id ?? _orderId;
      if (mounted) {
        ref.invalidate(openOrdersProvider);
        if (cart.tableId != null) ref.invalidate(tablesProvider);
        if (order.id != null) {
          context.push('/cashier/payment/${order.id}',
              extra: extra.isEmpty ? null : extra);
        } else {
          // Offline order: go to payment screen with local calculation
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PaymentScreen(
                orderId: -1,
                offlineOrder: order,
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
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

    final title = cart.orderType == 'takeaway'
        ? 'Takeaway'
        : (cart.tableName ?? 'New Order');

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
            if (_saving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white70),
                  ),
                ),
              )
            else if (cart.items.isNotEmpty)
              TextButton.icon(
                onPressed: _saveAndExit,
                icon: const Icon(Icons.save, color: Colors.white),
                label: const Text('Save', style: TextStyle(color: Colors.white)),
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
                  return Row(children: [
                    Expanded(flex: 3, child: catalog),
                    Container(
                      width: 300,
                      decoration: BoxDecoration(
                        border: Border(
                            left: BorderSide(color: Colors.grey.shade200)),
                      ),
                      child: _CartPanel(cart: cart, onCheckout: ({promotionId, promoCode}) =>
                          _proceedToPayment(promotionId: promotionId, promoCode: promoCode)),
                    ),
                  ]);
                }

                return Stack(children: [
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
                            '${cart.totalItems} items · ${formatRM(cart.subtotal)}'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1E6FD9),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                ]);
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
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
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
      final matchCat = widget.selectedCategoryId == null ||
          p.categoryId == widget.selectedCategoryId;
      final matchSearch = widget.search.isEmpty ||
          p.name.toLowerCase().contains(widget.search.toLowerCase());
      return matchCat && matchSearch;
    }).toList();

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
            value: widget.selectedCategoryId,
            isExpanded: true,
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              prefixIcon:
                  const Icon(Icons.filter_list_rounded, size: 18),
            ),
            items: [
              const DropdownMenuItem(
                  value: null, child: Text('All Categories')),
              ...widget.categories.map((c) => DropdownMenuItem(
                    value: c.id as int,
                    child: Text(c.name as String),
                  )),
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
    final cartItem =
        cart.items.where((i) => i.productId == product.id).firstOrNull;
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
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
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
                  ref
                      .read(cartProvider.notifier)
                      .updateQuantity(product.id, 0);
                },
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Remove'),
              ),
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Confirm')),
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
                              child: Image.network(product.imageUrl!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const Icon(
                                      Icons.restaurant,
                                      size: 36,
                                      color: Colors.grey)),
                            )
                          : Icon(
                              product.soldByWeight
                                  ? Icons.scale
                                  : Icons.restaurant,
                              size: 36,
                              color: product.soldByWeight
                                  ? Colors.teal
                                  : Colors.grey),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(product.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  Row(
                    children: [
                      Text(
                        product.soldByWeight
                            ? '${formatRM(product.price)}/kg'
                            : formatRM(product.price),
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF1E6FD9)),
                      ),
                      if (product.soldByWeight) ...[
                        const SizedBox(width: 3),
                        const Icon(Icons.scale,
                            size: 10, color: Colors.teal),
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
                      ? const Icon(Icons.check,
                          size: 11, color: Colors.white)
                      : Text('$qty',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
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

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          color: Colors.grey.shade100,
          child: Row(
            children: [
              const Icon(Icons.shopping_cart_outlined, size: 18),
              const SizedBox(width: 6),
              Text('ORDER (${cart.totalItems})',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
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
              ? const Center(
                  child: Text('No items yet',
                      style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: cart.items.length,
                  itemBuilder: (ctx, i) => _buildCartItem(context, ref, cart.items[i]),
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
                  const Text('Subtotal',
                      style: TextStyle(fontWeight: FontWeight.w500)),
                  Text(formatRM(cart.subtotal),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 10),
              // Promotion dropdown — hidden when cashier has no promotion permission
              if (canPromo)
                promosAsync!.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (promos) {
                    final listPromos =
                        promos.where((p) => p.type != 'promo_code').toList();
                    if (listPromos.isEmpty && _promoCodeCtrl.text.isEmpty) {
                      return _promoCodeField();
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (listPromos.isNotEmpty)
                          DropdownButtonFormField<Promotion?>(
                            value: _selectedPromo,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                              labelText: 'Promotion',
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                            ),
                            items: [
                              const DropdownMenuItem(
                                  value: null, child: Text('None')),
                              ...listPromos.map((p) => DropdownMenuItem(
                                    value: p,
                                    child: Text(p.name,
                                        overflow: TextOverflow.ellipsis),
                                  )),
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

  Widget _buildCartItem(
      BuildContext context, WidgetRef ref, OrderItem item) {
    if (item.weight != null) {
      // Weight-based item
      return ListTile(
        dense: true,
        leading: const Icon(Icons.scale, size: 18, color: Colors.teal),
        title: Text(item.productName,
            style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          '${item.weight!.toStringAsFixed(3)} kg × ${formatRM(item.unitPrice)}/kg',
          style: const TextStyle(fontSize: 11),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(formatRM(item.subtotal),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 13)),
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
      title: Text(item.productName,
          style: const TextStyle(fontSize: 13)),
      subtitle: Text(formatRM(item.unitPrice),
          style: const TextStyle(fontSize: 11)),
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
            child: Text('${item.quantity}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
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
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.grey.shade200,
          ),
          child: Icon(icon, size: 14),
        ),
      );
}
