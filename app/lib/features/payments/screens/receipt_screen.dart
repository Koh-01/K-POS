import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/models/payment.dart';
import '../../../core/models/order_item.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../../settings/providers/settings_provider.dart';
import '../../auth/providers/auth_provider.dart';
import '../services/receipt_pdf_service.dart';
import '../services/receipt_printer.dart';
import '../../../shared/utils/toast.dart';

class ReceiptScreen extends ConsumerWidget {
  final Payment payment;
  final List<OrderItem> items;
  const ReceiptScreen({
    super.key,
    required this.payment,
    this.items = const [],
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Receipt'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.home),
            tooltip: 'Back to Home',
            onPressed: () => context.go('/cashier'),
          ),
        ],
      ),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, st) =>
            _ReceiptBody(payment: payment, items: items, storeName: ''),
        data: (settings) => _ReceiptBody(
          payment: payment,
          items: items,
          storeName: settings.storeName,
          storeAddress: settings.storeAddress,
          storePhone: settings.storePhone,
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.print),
              label: const Text('Print Receipt'),
              onPressed: () async {
                try {
                  final settings = ref.read(settingsProvider).value;
                  final user = ref.read(authProvider).user;
                  await ReceiptPrinter.print(
                    payment: payment,
                    items: items,
                    storeName: settings?.storeName ?? '',
                    storeAddress: settings?.storeAddress,
                    storePhone: settings?.storePhone,
                    settings: settings,
                    employeeName: user?.fullName.isNotEmpty == true
                        ? user!.fullName
                        : user?.username,
                    posName: user?.username,
                  );
                } catch (e) {
                  if (context.mounted) {
                    showToast(
                      context,
                      'Print failed. Make sure the printer is connected and try again.',
                      error: true,
                    );
                  }
                }
              },
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('Export PDF'),
              onPressed: () async {
                try {
                  final settings = ref.read(settingsProvider).value;
                  await ReceiptPdfService.share(
                    payment: payment,
                    items: items,
                    storeName: settings?.storeName ?? '',
                    storeAddress: settings?.storeAddress,
                    storePhone: settings?.storePhone,
                    settings: settings,
                  );
                } catch (e) {
                  if (context.mounted) {
                    showToast(
                      context,
                      'Could not generate PDF. Please try again.',
                      error: true,
                    );
                  }
                }
              },
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => context.go('/cashier'),
              child: const Text('New Order'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceiptBody extends StatelessWidget {
  final Payment payment;
  final List<OrderItem> items;
  final String storeName;
  final String? storeAddress;
  final String? storePhone;

  const _ReceiptBody({
    required this.payment,
    required this.items,
    required this.storeName,
    this.storeAddress,
    this.storePhone,
  });

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          children: [
            const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 60),
            const SizedBox(height: 12),
            const Text(
              'Payment Successful',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  if (storeName.trim().isNotEmpty)
                    Text(
                      storeName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  if (storeAddress?.trim().isNotEmpty ?? false)
                    Text(
                      storeAddress!,
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  if (storePhone != null)
                    Text(
                      storePhone!,
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  const SizedBox(height: 16),
                  const Divider(),
                  _Row('Order #', '${payment.orderId}'),
                  _Row('Method', switch (payment.paymentMethod) {
                    'cash' => 'Cash',
                    'duitnow' => 'DuitNow QR',
                    'card' => 'Card',
                    _ => payment.paymentMethod,
                  }),
                  if (items.isNotEmpty) ...[
                    const Divider(),
                    ...items.map(
                      (item) => _Row(
                        '${item.productName} x${item.quantity}',
                        formatRM(item.subtotal),
                      ),
                    ),
                  ],
                  const Divider(),
                  _Row('Subtotal', formatRM(payment.subtotal)),
                  if (payment.serviceCharge > 0)
                    _Row('Service Charge', formatRM(payment.serviceCharge)),
                  if (payment.sst > 0) _Row('SST', formatRM(payment.sst)),
                  if (payment.discount > 0)
                    _Row(
                      'Discount',
                      '- ${formatRM(payment.discount)}',
                      valueColor: Colors.green,
                    ),
                  const Divider(),
                  _Row(
                    'TOTAL',
                    formatRM(payment.grandTotal),
                    bold: true,
                    fontSize: 18,
                  ),
                  if (payment.cashReceived != null) ...[
                    const SizedBox(height: 4),
                    _Row('Cash Received', formatRM(payment.cashReceived!)),
                    _Row('Change', formatRM(payment.changeGiven ?? 0)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final double fontSize;
  final Color? valueColor;

  const _Row(
    this.label,
    this.value, {
    this.bold = false,
    this.fontSize = 13,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              fontSize: fontSize,
            ),
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
