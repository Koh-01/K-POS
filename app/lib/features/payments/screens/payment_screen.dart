import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../providers/payment_provider.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/db/local_db.dart';
import '../../../core/models/order.dart';
import '../../../core/models/payment.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../../../shared/utils/error_utils.dart';
import '../../cashier/providers/cashier_provider.dart';
import '../../auth/providers/auth_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../services/receipt_printer.dart';

class PaymentScreen extends ConsumerStatefulWidget {
  final int orderId;
  final int? promotionId;
  final String? promoCode;

  /// Non-null when operating in offline mode (order has no server ID yet).
  final Order? offlineOrder;
  const PaymentScreen({
    super.key,
    required this.orderId,
    this.promotionId,
    this.promoCode,
    this.offlineOrder,
  });

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  // ── Data loading ────────────────────────────────────────────────────────────
  bool _loading = true;
  String? _loadError;
  Order? _order;
  CheckoutSummary? _summary;

  // ── Payment choices ─────────────────────────────────────────────────────────
  String _method = 'cash';
  final _cashCtrl = TextEditingController();
  bool _paying = false;

  // ── Post-payment state ───────────────────────────────────────────────────────
  Payment? _completedPayment;
  bool _hasPrinted = false;
  bool _printing = false;
  bool _printingBill = false;
  bool _paymentPendingSync = false;

  // True when this order already has a real server ID but couldn't be
  // reached over the network — we fell back to the local open-orders cache
  // and need to queue the payment instead of posting it directly.
  bool _offlineRealOrder = false;

  @override
  void initState() {
    super.initState();
    // Explicitly reset state on every init (guards against hot-reload state reuse)
    _loading = true;
    _loadError = null;
    _order = null;
    _summary = null;
    _cashCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _cashCtrl.dispose();
    super.dispose();
  }

  bool get _isOffline => widget.offlineOrder != null || _offlineRealOrder;

  // ── Offline helpers ──────────────────────────────────────────────────────────

  // ── Loaders ─────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });

    // Offline mode: compute totals locally from cached settings
    if (_isOffline) {
      final settings = await ref.read(settingsProvider.future);
      final summary = calculateOfflineCheckout(
        widget.offlineOrder!.items,
        settings,
      );
      if (mounted) {
        setState(() {
          _order = widget.offlineOrder;
          _summary = summary;
          _loading = false;
        });
      }
      return;
    }

    try {
      Order? order;
      CheckoutSummary? summary;
      await Future.wait([
        OrderService.fetchOrder(widget.orderId).then((o) => order = o),
        _fetchPreview(
          promotionId: widget.promotionId,
          promoCode: widget.promoCode,
        ).then((s) => summary = s),
      ]);
      if (!mounted) return;
      setState(() {
        _order = order;
        _summary = summary;
        _loading = false;
      });
    } catch (e) {
      if (!ApiException.isOfflineFailure(e)) {
        if (!mounted) return;
        setState(() {
          _loadError = friendlyError(e);
          _loading = false;
        });
        return;
      }
      // Network unreachable: this order already synced before we lost
      // connectivity, so it should still be sitting in the local
      // open-orders cache — fall back to it and switch to offline-pay mode
      // instead of just showing an error the cashier can't act on.
      final cached = await LocalDb.getCachedOrderById(widget.orderId);
      if (cached != null) {
        final settings = await ref.read(settingsProvider.future);
        final summary = calculateOfflineCheckout(cached.items, settings);
        if (!mounted) return;
        setState(() {
          _order = cached;
          _summary = summary;
          _offlineRealOrder = true;
          _loading = false;
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _loading = false;
      });
    }
  }

  Future<CheckoutSummary> _fetchPreview({
    int? promotionId,
    String? promoCode,
  }) async {
    double discountPct = 0;
    double discountAmt = 0;
    int? resolvedPromoId;
    String? resolvedCode;

    if (promotionId != null || (promoCode?.isNotEmpty ?? false)) {
      final body = <String, dynamic>{'order_id': widget.orderId};
      if (promotionId != null) body['promotion_id'] = promotionId;
      if (promoCode?.isNotEmpty ?? false) body['promo_code'] = promoCode;
      final pr = await ApiClient.instance.post('/promotions/apply', data: body);
      final pd = pr.data as Map<String, dynamic>;
      discountPct = double.parse(pd['discount_percent'].toString());
      discountAmt = double.parse(pd['discount_amount'].toString());
      resolvedPromoId = pd['promotion_id'] as int?;
      resolvedCode = promoCode;
    }

    final qp = <String, dynamic>{};
    if (discountPct > 0) qp['discount_percent'] = discountPct;
    if (discountAmt > 0) qp['discount_amount'] = discountAmt;

    final res = await ApiClient.instance.get(
      '/orders/${widget.orderId}/payment-preview',
      queryParameters: qp,
    );
    final d = res.data as Map<String, dynamic>;
    return CheckoutSummary(
      subtotal: double.parse(d['subtotal'].toString()),
      serviceCharge: double.parse(d['service_charge_amount'].toString()),
      serviceChargeRate: double.parse(d['service_charge_rate'].toString()),
      sst: double.parse(d['sst_amount'].toString()),
      sstRate: double.parse(d['sst_rate'].toString()),
      discount: double.parse(d['discount_amount'].toString()),
      discountPercent: double.parse(d['discount_percent'].toString()),
      grandTotal: double.parse(d['grand_total'].toString()),
      promotionId: resolvedPromoId,
      promoCode: resolvedCode,
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  String _checkoutTitle() {
    final order = _order;
    if (order == null) return 'Checkout';
    if (order.orderType == OrderTypes.takeAway) return 'Takeaway — Checkout';
    final name = order.tableName ?? '';
    return name.isNotEmpty ? '$name — Checkout' : 'Checkout';
  }

  // ── Payment ─────────────────────────────────────────────────────────────────

  Future<void> _queueOfflinePayment({
    required String offlineRef,
    required Order order,
    required CheckoutSummary summary,
    required double cashReceived,
  }) async {
    final knownServerOrder = order.id != null;
    final change = _method == 'cash' ? cashReceived - summary.grandTotal : 0.0;

    await LocalDb.savePendingPayment({
      'offline_ref': offlineRef,
      'order_offline_ref': order.offlineRef ?? '',
      if (knownServerOrder) 'order_id': order.id,
      'payment_method': _method,
      if (summary.promotionId != null) 'promotion_id': summary.promotionId,
      'subtotal': summary.subtotal,
      'discount_percent': summary.discountPercent,
      'discount_amount': summary.discount,
      'service_charge_rate': summary.serviceChargeRate,
      'service_charge_amount': summary.serviceCharge,
      'sst_rate': summary.sstRate,
      'sst_amount': summary.sst,
      'grand_total': summary.grandTotal,
      if (_method == 'cash') 'cash_tendered': cashReceived,
      if (_method == 'cash') 'change_amount': change,
      'items_json': jsonEncode(
        order.items
            .map(
              (i) => {
                'product_id': i.productId,
                'quantity': i.quantity,
                'unit_price': i.unitPrice,
                if (i.weight != null) 'weight_kg': i.weight,
              },
            )
            .toList(),
      ),
      'table_name': order.tableName,
      'order_type': order.orderType,
      'created_at': DateTime.now().toIso8601String(),
      'synced': 0,
      'retry_count': 0,
    });

    if (knownServerOrder) {
      await LocalDb.removeCachedOpenOrder(order.id!);
    } else if (order.offlineRef != null) {
      await LocalDb.markOrderPaidLocally(order.offlineRef!);
    }
    ref.read(cartProvider.notifier).clear();
    ref.invalidate(openOrdersProvider);
    ref.invalidate(pendingSyncCountProvider);
    if (!mounted) return;
    setState(() {
      _paymentPendingSync = true;
      _completedPayment = Payment(
        id: -1,
        orderId: order.id ?? -1,
        offlineRef: offlineRef,
        paymentMethod: _method,
        subtotal: summary.subtotal,
        serviceCharge: summary.serviceCharge,
        sst: summary.sst,
        discount: summary.discount,
        grandTotal: summary.grandTotal,
        cashReceived: _method == 'cash' ? cashReceived : null,
        changeGiven: _method == 'cash' ? change : null,
        isVoided: false,
        createdAt: DateTime.now(),
      );
    });
  }

  Future<void> _pay() async {
    final summary = _summary!;
    final paymentOfflineRef = const Uuid().v4();
    final cashReceived = _method == 'cash'
        ? (double.tryParse(_cashCtrl.text.trim()) ?? summary.grandTotal)
        : summary.grandTotal;

    if (_method == 'cash' && cashReceived < summary.grandTotal) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Cash received is less than the total.'),
          ),
        );
      return;
    }

    setState(() => _paying = true);
    try {
      final localFirst =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

      // Android checkout is local-first even while online. The cashier only
      // waits for the durable SQLite write; network upload runs independently.
      if (localFirst || _isOffline) {
        await _queueOfflinePayment(
          offlineRef: paymentOfflineRef,
          order: widget.offlineOrder ?? _order!,
          summary: summary,
          cashReceived: cashReceived,
        );
        unawaited(_syncCheckoutInBackground(paymentOfflineRef));
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  _isOffline
                      ? 'Payment saved offline and will sync automatically.'
                      : 'Payment completed. Syncing in the background.',
                ),
              ),
            );
        }
        return;
      }

      // Browser checkout keeps the direct API path because sqflite is not
      // available there; the backend website remains unchanged.
      final payment = await ref
          .read(paymentProvider.notifier)
          .checkout(
            orderId: widget.orderId,
            offlineRef: paymentOfflineRef,
            paymentMethod: _method,
            cashReceived: cashReceived,
            promotionId: summary.promotionId,
            promoCode: summary.promoCode,
          );
      ref.read(cartProvider.notifier).clear();
      ref.invalidate(openOrdersProvider);
      if (!mounted) return;
      setState(() => _completedPayment = payment);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(friendlyError(e)),
              duration: const Duration(seconds: 4),
            ),
          );
      }
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  Future<void> _syncCheckoutInBackground(String paymentOfflineRef) async {
    try {
      await OrderService.syncPendingCheckoutQueue();
      final stillPending = await LocalDb.isPaymentPending(paymentOfflineRef);
      if (!mounted) return;
      ref.invalidate(openOrdersProvider);
      ref.invalidate(tablesProvider);
      ref.invalidate(pendingSyncCountProvider);
      setState(() => _paymentPendingSync = stillPending);
    } catch (_) {
      // The durable queue remains pending and the app-level timer/connectivity
      // listener will retry it. Never surface an async sync error to checkout.
    }
  }

  Future<void> _printBill() async {
    final order = _order;
    final summary = _summary;
    if (order == null || summary == null) return;
    setState(() => _printingBill = true);
    try {
      final settings = ref.read(settingsProvider).value;
      final user = ref.read(authProvider).user;
      await ReceiptPrinter.printBill(
        order: order,
        summary: summary,
        storeName: settings?.storeName ?? 'My Restaurant',
        storeAddress: settings?.storeAddress,
        storePhone: settings?.storePhone,
        settings: settings,
        employeeName: user?.fullName.isNotEmpty == true
            ? user!.fullName
            : user?.username,
        posName: user?.username,
      );
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Printer Error'),
            content: Text(
              'Failed to print bill.\n\n$e\n\nCheck the printer connection and try again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
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

  Future<void> _printNow() async {
    setState(() => _printing = true);
    try {
      final settings = ref.read(settingsProvider).value;
      final user = ref.read(authProvider).user;
      await ReceiptPrinter.print(
        payment: _completedPayment!,
        items: _order?.items ?? [],
        storeName: settings?.storeName ?? 'My Restaurant',
        storeAddress: settings?.storeAddress,
        storePhone: settings?.storePhone,
        settings: settings,
        employeeName: user?.fullName.isNotEmpty == true
            ? user!.fullName
            : user?.username,
        posName: user?.username,
      );
      if (mounted) setState(() => _hasPrinted = true);
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Printer Error'),
            content: Text(
              'Failed to print receipt.\n\n$e\n\nCheck the printer connection and try again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  void _done() {
    context.go('/cashier');
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final appBar = AppBar(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_checkoutTitle()),
          if (_isOffline || _paymentPendingSync) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.orange,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _isOffline ? 'OFFLINE' : 'SYNCING',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );

    if (_loading) {
      return Scaffold(
        appBar: appBar,
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('Loading order...'),
            ],
          ),
        ),
      );
    }

    if (_loadError != null) {
      return Scaffold(
        appBar: appBar,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 56, color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  'Failed to load order',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  _loadError!,
                  style: const TextStyle(color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: _load,
                  style: ElevatedButton.styleFrom(
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                  ),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Null guard: if data somehow absent after loading, show loading
    final order = _order;
    final summary = _summary;
    if (order == null || summary == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
      return Scaffold(
        appBar: appBar,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final qrUrlAsync = ref.watch(duitnowQrUrlProvider);
    final completedPayment = _completedPayment;

    return Scaffold(
      appBar: appBar,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Order Items ──────────────────────────────────────────────────
            _SectionCard(
              title: 'Order Items',
              child: Column(
                children: [
                  ...order.items.map(
                    (item) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.productName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          Text(
                            item.weight != null
                                ? '${item.weight!.toStringAsFixed(3)} kg'
                                : '×${item.quantity}',
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            formatRM(item.subtotal),
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 18),
                  _SummaryRow(
                    'Subtotal',
                    formatRM(summary.subtotal),
                    bold: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // ── Amount Breakdown ─────────────────────────────────────────────
            _SectionCard(
              title: 'Amount',
              child: Column(
                children: [
                  if (summary.serviceCharge > 0)
                    _SummaryRow(
                      'Service Charge',
                      formatRM(summary.serviceCharge),
                    ),
                  if (summary.sst > 0)
                    _SummaryRow('SST', formatRM(summary.sst)),
                  if (summary.discount > 0)
                    _SummaryRow(
                      'Discount',
                      '− ${formatRM(summary.discount)}',
                      valueColor: Colors.green,
                    ),
                  const Divider(height: 14),
                  _SummaryRow(
                    'TOTAL',
                    formatRM(summary.grandTotal),
                    bold: true,
                    fontSize: 22,
                    valueColor: const Color(0xFF1E6FD9),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // ── Payment Method ───────────────────────────────────────────────
            _SectionCard(
              title: 'Payment Method',
              child: Row(
                children: [
                  _MethodButton(
                    label: 'Cash',
                    icon: Icons.payments_outlined,
                    selected: _method == 'cash',
                    onTap: () => setState(() => _method = 'cash'),
                  ),
                  const SizedBox(width: 8),
                  _MethodButton(
                    label: 'DuitNow',
                    icon: Icons.qr_code,
                    selected: _method == 'duitnow',
                    onTap: () => setState(() => _method = 'duitnow'),
                  ),
                  const SizedBox(width: 8),
                  _MethodButton(
                    label: 'Card',
                    icon: Icons.credit_card,
                    selected: _method == 'card',
                    onTap: () => setState(() => _method = 'card'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // ── Cash Section ─────────────────────────────────────────────────
            if (_method == 'cash') ...[
              _SectionCard(
                title: 'Cash Received',
                child: Column(
                  children: [
                    TextField(
                      controller: _cashCtrl,
                      decoration: InputDecoration(
                        labelText: 'Amount received (RM)',
                        hintText: summary.grandTotal.toStringAsFixed(2),
                        prefixText: 'RM ',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _QuickAmounts(
                      total: summary.grandTotal,
                      onSelect: (v) => setState(() {
                        _cashCtrl.text = v % 1 == 0
                            ? v.toInt().toString()
                            : v.toStringAsFixed(2);
                      }),
                    ),
                    const SizedBox(height: 10),
                    _ChangeDisplay(
                      cashText: _cashCtrl.text,
                      grandTotal: summary.grandTotal,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],

            // ── DuitNow Section ──────────────────────────────────────────────
            if (_method == 'duitnow') ...[
              _SectionCard(
                title: 'DuitNow QR',
                child: qrUrlAsync.when(
                  loading: () => const Center(child: LinearProgressIndicator()),
                  error: (_, _) => const Text(
                    'Could not load QR. Check settings.',
                    style: TextStyle(color: Colors.orange),
                    textAlign: TextAlign.center,
                  ),
                  data: (url) => url != null
                      ? Column(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: CachedNetworkImage(
                                imageUrl: url,
                                height: 220,
                                errorWidget: (_, _, _) =>
                                    const Text('QR image unavailable'),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Ask customer to scan — ${formatRM(summary.grandTotal)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        )
                      : const Text(
                          'No QR configured. Upload one in Admin → Settings.',
                          style: TextStyle(color: Colors.orange),
                          textAlign: TextAlign.center,
                        ),
                ),
              ),
              const SizedBox(height: 10),
            ],

            // ── Card Section ─────────────────────────────────────────────────
            if (_method == 'card') ...[
              _SectionCard(
                title: 'Card Payment',
                child: Column(
                  children: [
                    const Icon(
                      Icons.credit_card,
                      size: 48,
                      color: Color(0xFF1E6FD9),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Total: ${formatRM(summary.grandTotal)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Process payment on card terminal,\nthen tap Complete Payment.',
                      style: TextStyle(color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],

            // ── Bottom Action ────────────────────────────────────────────────
            if (completedPayment != null) ...[
              // Post-payment: success banner + print + done
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFF10B981).withValues(alpha: 0.4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _paymentPendingSync
                              ? Icons.cloud_upload_outlined
                              : Icons.check_circle,
                          color: _paymentPendingSync
                              ? Colors.orange
                              : const Color(0xFF10B981),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _paymentPendingSync
                              ? 'Payment completed — syncing in background'
                              : 'Payment Successful!',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: _paymentPendingSync
                                ? Colors.orange
                                : const Color(0xFF10B981),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          formatRM(completedPayment.grandTotal),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF10B981),
                          ),
                        ),
                      ],
                    ),
                    if (_hasPrinted) ...[
                      const SizedBox(height: 4),
                      const Row(
                        children: [
                          Icon(Icons.check, size: 13, color: Color(0xFF10B981)),
                          SizedBox(width: 4),
                          Text(
                            'Receipt printed',
                            style: TextStyle(
                              color: Color(0xFF10B981),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 46,
                            child: OutlinedButton.icon(
                              onPressed: _printing ? null : _printNow,
                              icon: _printing
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.print_outlined),
                              label: Text(
                                _printing
                                    ? 'Printing…'
                                    : _hasPrinted
                                    ? 'Print Again'
                                    : 'Print Receipt',
                              ),
                              style: OutlinedButton.styleFrom(
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                side: const BorderSide(
                                  color: Color(0xFF10B981),
                                ),
                                foregroundColor: const Color(0xFF10B981),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 46,
                            child: ElevatedButton(
                              onPressed: _done,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF10B981),
                                foregroundColor: Colors.white,
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: const Text(
                                'Done',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ] else ...[
              // Pre-payment: Print Bill + Complete Payment
              SizedBox(
                height: 46,
                child: OutlinedButton.icon(
                  onPressed: _printingBill ? null : _printBill,
                  icon: _printingBill
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.print_outlined),
                  label: Text(_printingBill ? 'Printing…' : 'Print Bill'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 54,
                child: ElevatedButton(
                  onPressed: _paying ? null : _pay,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: _paying
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          'Complete Payment — ${formatRM(summary.grandTotal)}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Helper widgets ────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final double fontSize;
  final Color? valueColor;

  const _SummaryRow(
    this.label,
    this.value, {
    this.bold = false,
    this.fontSize = 14,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            fontSize: fontSize,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            fontSize: fontSize,
            color: valueColor,
          ),
        ),
      ],
    ),
  );
}

class _MethodButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _MethodButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Expanded(
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? const Color(0xFF1E6FD9) : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
          color: selected
              ? const Color(0xFF1E6FD9).withValues(alpha: 0.1)
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: selected ? const Color(0xFF1E6FD9) : Colors.grey,
              size: 24,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: selected ? const Color(0xFF1E6FD9) : null,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _QuickAmounts extends StatelessWidget {
  final double total;
  final ValueChanged<double> onSelect;
  const _QuickAmounts({required this.total, required this.onSelect});

  static List<double> _suggestions(double total) {
    final result = <double>[total]; // "Exact" always first
    final seen = <double>{total};
    for (final step in [5.0, 10.0, 20.0, 50.0, 100.0]) {
      final v = (total / step).ceil() * step;
      if (v > total && seen.add(v)) result.add(v);
      if (result.length == 5) break;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = _suggestions(total);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: suggestions
          .map(
            (v) => ActionChip(
              label: Text(
                v == total
                    ? 'Exact'
                    : 'RM ${v % 1 == 0 ? v.toInt() : v.toStringAsFixed(2)}',
              ),
              onPressed: () => onSelect(v),
              backgroundColor: const Color(0xFF1E6FD9).withValues(alpha: 0.08),
              side: const BorderSide(color: Color(0xFF1E6FD9), width: 0.8),
              labelStyle: const TextStyle(
                color: Color(0xFF1E6FD9),
                fontSize: 13,
              ),
            ),
          )
          .toList(),
    );
  }
}

class _ChangeDisplay extends StatelessWidget {
  final String cashText;
  final double grandTotal;
  const _ChangeDisplay({required this.cashText, required this.grandTotal});

  @override
  Widget build(BuildContext context) {
    final received = double.tryParse(cashText.trim());
    if (received == null || cashText.trim().isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Change', style: TextStyle(color: Colors.grey)),
            Text('—', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    final change = received - grandTotal;
    final isShort = change < -0.005;
    final textColor = isShort
        ? const Color(0xFFEF4444)
        : const Color(0xFF10B981);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: textColor.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            isShort ? 'Short by' : 'Change',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: textColor,
              fontSize: 15,
            ),
          ),
          Text(
            isShort
                ? 'RM ${change.abs().toStringAsFixed(2)}'
                : 'RM ${change.toStringAsFixed(2)}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: textColor,
              fontSize: 20,
            ),
          ),
        ],
      ),
    );
  }
}
