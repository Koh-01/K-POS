import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/models/payment_detail.dart';
import '../../../core/models/order_item.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../../settings/providers/settings_provider.dart';
import '../providers/payment_provider.dart';
import '../services/receipt_pdf_service.dart';
import '../services/receipt_printer.dart';
import '../../../shared/utils/error_utils.dart';

class PaymentDetailScreen extends ConsumerStatefulWidget {
  final int paymentId;
  const PaymentDetailScreen({super.key, required this.paymentId});

  @override
  ConsumerState<PaymentDetailScreen> createState() =>
      _PaymentDetailScreenState();
}

class _PaymentDetailScreenState extends ConsumerState<PaymentDetailScreen> {
  PaymentDetail? _detail;
  bool _loading = true;
  String? _error;
  bool _submitting = false;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.instance
          .get('/payments/${widget.paymentId}/detail');
      setState(() {
        _detail =
            PaymentDetail.fromJson(res.data as Map<String, dynamic>);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ── Print ──────────────────────────────────────────────────────────────────

  Future<void> _print() async {
    final detail = _detail!;
    setState(() => _printing = true);
    try {
      final settings = ref.read(settingsProvider).value;
      await ReceiptPrinter.print(
        payment: detail,
        items: detail.items,
        storeName: settings?.storeName ?? 'My Restaurant',
        storeAddress: settings?.storeAddress,
        storePhone: settings?.storePhone,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Receipt printed')),
        );
      }
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Printer Error'),
            content: const Text('Print failed. Make sure the printer is connected and try again.'),
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

  // ── PDF ────────────────────────────────────────────────────────────────────

  Future<void> _exportPdf() async {
    final detail = _detail!;
    try {
      final settings = ref.read(settingsProvider).value;
      await ReceiptPdfService.share(
        payment: detail,
        items: detail.items,
        storeName: settings?.storeName ?? 'My Restaurant',
        storeAddress: settings?.storeAddress,
        storePhone: settings?.storePhone,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not generate PDF. Please try again.')));
      }
    }
  }

  // ── Edit ───────────────────────────────────────────────────────────────────

  Future<void> _openEditSheet() async {
    final detail = _detail!;
    final result = await showModalBottomSheet<_EditResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _EditSheet(items: detail.items),
    );
    if (result != null && mounted) {
      await _submitEdit(result, detail);
    }
  }

  Future<void> _submitEdit(_EditResult result, PaymentDetail detail) async {
    setState(() => _submitting = true);
    try {
      final items = detail.items.asMap().entries.map((e) {
        final idx = e.key;
        final item = e.value;
        if (item.weight != null) {
          return {
            'product_id': item.productId,
            'quantity': 1,
            'weight_kg': result.weights[idx] ?? item.weight!,
            if (item.notes != null) 'notes': item.notes,
          };
        } else {
          return {
            'product_id': item.productId,
            'quantity': result.qtys[idx],
            if (item.notes != null) 'notes': item.notes,
          };
        }
      }).toList();

      await ApiClient.instance.put(
        '/payments/${widget.paymentId}',
        data: {
          'items': items,
          'discount_percent': detail.discountPercent,
          'discount_amount':
              detail.discountPercent > 0 ? 0 : detail.discount,
          'reason': result.reason,
        },
      );
      ref.invalidate(paymentsListProvider);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Receipt updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final canManagePayment = ref.watch(authProvider).user?.canManagePayment ?? false;
    final detail = _detail;

    return Scaffold(
      appBar: AppBar(
        title: Text(detail != null
            ? '${detail.locationLabel} — Receipt'
            : 'Receipt Detail'),
        actions: [
          if (detail != null && canManagePayment && !detail.isVoided)
            _submitting
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Edit Receipt',
                    onPressed: _openEditSheet,
                  ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline,
                            size: 48, color: Colors.red),
                        const SizedBox(height: 12),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.grey)),
                        const SizedBox(height: 16),
                        ElevatedButton(
                            onPressed: _load,
                            child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : _ReceiptBody(detail: detail!),
      bottomNavigationBar: detail == null || detail.isVoided
          ? null
          : SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _printing ? null : _print,
                        icon: _printing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.print_outlined),
                        label:
                            Text(_printing ? 'Printing…' : 'Print Receipt'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _exportPdf,
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: const Text('Export PDF'),
                        style: ElevatedButton.styleFrom(
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

// ── Receipt body ──────────────────────────────────────────────────────────────

class _ReceiptBody extends StatelessWidget {
  final PaymentDetail detail;
  const _ReceiptBody({required this.detail});

  @override
  Widget build(BuildContext context) {
    final date = detail.createdAt;
    final dateStr =
        '${date.day}/${date.month}/${date.year}  ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final methodLabel = switch (detail.paymentMethod) {
      'cash' => 'Cash',
      'duitnow' => 'DuitNow QR',
      'card' => 'Card',
      _ => detail.paymentMethod,
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status badges
              if (detail.isVoided)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: const Text('VOIDED',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1)),
                ),
              if (detail.wasEdited && !detail.isVoided)
                Container(
                  padding: const EdgeInsets.symmetric(
                      vertical: 6, horizontal: 12),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.edit_note,
                          size: 14, color: Colors.orange),
                      SizedBox(width: 6),
                      Text('Receipt has been edited',
                          style: TextStyle(
                              color: Colors.orange, fontSize: 12)),
                    ],
                  ),
                ),

              // Receipt card
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.shade200),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header info
                      _Row('Location', detail.locationLabel),
                      if (detail.orderNumber != null)
                        _Row('Order #', detail.orderNumber!),
                      _Row('Receipt #', '${detail.id}'),
                      _Row('Date', dateStr),
                      _Row('Method', methodLabel),
                      const Divider(height: 24),

                      // Items
                      if (detail.items.isEmpty)
                        Text('No items',
                            style: TextStyle(color: Colors.grey.shade500))
                      else ...[
                        ...detail.items.map((item) => Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      item.productName,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                  Text(
                                    item.weight != null
                                        ? '${item.weight!.toStringAsFixed(3)} kg'
                                        : '×${item.quantity}',
                                    style: TextStyle(
                                        color: Colors.grey.shade600),
                                  ),
                                  const SizedBox(width: 16),
                                  Text(formatRM(item.subtotal),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w500)),
                                ],
                              ),
                            )),
                      ],
                      const Divider(height: 24),

                      // Totals
                      _Row('Subtotal', formatRM(detail.subtotal)),
                      if (detail.serviceCharge > 0)
                        _Row('Service Charge',
                            formatRM(detail.serviceCharge)),
                      if (detail.sst > 0)
                        _Row('SST', formatRM(detail.sst)),
                      if (detail.discount > 0)
                        _Row('Discount',
                            '− ${formatRM(detail.discount)}',
                            valueColor: Colors.green),
                      const Divider(height: 16),
                      _Row('TOTAL', formatRM(detail.grandTotal),
                          bold: true,
                          fontSize: 20,
                          valueColor: const Color(0xFF1E6FD9)),

                      // Cash details
                      if (detail.cashReceived != null) ...[
                        const SizedBox(height: 8),
                        _Row('Cash Received',
                            formatRM(detail.cashReceived!)),
                        _Row('Change',
                            formatRM(detail.changeGiven ?? 0)),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final double fontSize;
  final Color? valueColor;

  const _Row(this.label, this.value,
      {this.bold = false, this.fontSize = 13, this.valueColor});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: fontSize,
                      fontWeight:
                          bold ? FontWeight.bold : FontWeight.normal,
                      color: Colors.grey.shade700)),
            ),
            Text(value,
                style: TextStyle(
                    fontSize: fontSize,
                    fontWeight:
                        bold ? FontWeight.bold : FontWeight.normal,
                    color: valueColor)),
          ],
        ),
      );
}

// ── Edit sheet ────────────────────────────────────────────────────────────────

class _EditResult {
  final List<int> qtys;
  final List<double?> weights;
  final String reason;
  const _EditResult(
      {required this.qtys, required this.weights, required this.reason});
}

class _EditSheet extends StatefulWidget {
  final List<OrderItem> items;
  const _EditSheet({required this.items});

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late List<int> _qtys;
  late List<TextEditingController?> _weightCtrls;
  final _reasonCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _qtys = widget.items.map((i) => i.quantity).toList();
    _weightCtrls = widget.items.map((i) {
      if (i.weight == null) return null;
      final text = i.weight!
          .toStringAsFixed(3)
          .replaceAll(RegExp(r'0+$'), '')
          .replaceAll(RegExp(r'\.$'), '');
      return TextEditingController(text: text);
    }).toList();
  }

  @override
  void dispose() {
    for (final c in _weightCtrls) {
      c?.dispose();
    }
    _reasonCtrl.dispose();
    super.dispose();
  }

  void _save() {
    if (_reasonCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a reason')),
      );
      return;
    }
    final weights = _weightCtrls
        .map((c) => c == null ? null : double.tryParse(c.text.trim()))
        .toList();
    Navigator.pop(
      context,
      _EditResult(
        qtys: List.of(_qtys),
        weights: weights,
        reason: _reasonCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text('Edit Receipt Items',
                style:
                    TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Adjust quantities. Totals are recalculated automatically.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
            const SizedBox(height: 16),
            ...widget.items.asMap().entries.map((e) {
              final idx = e.key;
              final item = e.value;
              final isWeight = item.weight != null;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.productName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w500)),
                          Text(
                            isWeight
                                ? '${formatRM(item.unitPrice)} / kg'
                                : '${formatRM(item.unitPrice)} each',
                            style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade600),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (isWeight)
                      SizedBox(
                        width: 90,
                        child: TextField(
                          controller: _weightCtrls[idx],
                          keyboardType:
                              const TextInputType.numberWithOptions(
                                  decimal: true),
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(
                            suffixText: 'kg',
                            isDense: true,
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 8, vertical: 10),
                          ),
                        ),
                      )
                    else
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(
                                Icons.remove_circle_outline),
                            color: const Color(0xFF1E6FD9),
                            iconSize: 22,
                            visualDensity: VisualDensity.compact,
                            onPressed: _qtys[idx] > 1
                                ? () => setState(() => _qtys[idx]--)
                                : null,
                          ),
                          SizedBox(
                            width: 32,
                            child: Text(
                              '${_qtys[idx]}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16),
                            ),
                          ),
                          IconButton(
                            icon:
                                const Icon(Icons.add_circle_outline),
                            color: const Color(0xFF1E6FD9),
                            iconSize: 22,
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                setState(() => _qtys[idx]++),
                          ),
                        ],
                      ),
                  ],
                ),
              );
            }),
            const Divider(height: 24),
            TextField(
              controller: _reasonCtrl,
              decoration: const InputDecoration(
                labelText: 'Reason for edit *',
                hintText:
                    'e.g. Customer ordered 1 teh, cashier entered 2',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1E6FD9),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Save Changes',
                  style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}
