import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/payment_provider.dart';
import '../../../core/models/payment.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exception.dart';
import '../../../features/auth/providers/auth_provider.dart';
import 'payment_detail_screen.dart';
import '../../../shared/utils/error_utils.dart';

class PaymentsListScreen extends ConsumerWidget {
  const PaymentsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paymentsAsync = ref.watch(paymentsListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(paymentsListProvider),
          ),
        ],
      ),
      body: paymentsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(loadError(e))),
        data: (payments) {
          if (payments.isEmpty) {
            return const Center(child: Text('No payments yet'));
          }
          return ListView.builder(
            itemCount: payments.length,
            itemBuilder: (ctx, i) =>
                _PaymentTile(payment: payments[i], ref: ref),
          );
        },
      ),
    );
  }
}

class _PaymentTile extends StatelessWidget {
  final Payment payment;
  final WidgetRef ref;
  const _PaymentTile({required this.payment, required this.ref});

  IconData get _methodIcon => switch (payment.paymentMethod) {
    'duitnow' => Icons.qr_code,
    'card' => Icons.credit_card,
    _ => Icons.payments_outlined,
  };

  String get _methodLabel => switch (payment.paymentMethod) {
    'duitnow' => 'DuitNow',
    'card' => 'Card',
    _ => 'Cash',
  };

  @override
  Widget build(BuildContext context) {
    final date = payment.createdAt;
    final dateStr =
        '${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

    return ListTile(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PaymentDetailScreen(paymentId: payment.id),
          ),
        );
        ref.invalidate(paymentsListProvider);
      },
      leading: CircleAvatar(
        backgroundColor: payment.isVoided
            ? Colors.grey.shade200
            : const Color(0xFF10B981).withValues(alpha: 0.15),
        child: Icon(
          _methodIcon,
          color: payment.isVoided ? Colors.grey : const Color(0xFF10B981),
        ),
      ),
      title: Text(
        'Order #${payment.orderId}  •  ${formatRM(payment.grandTotal)}',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          decoration: payment.isVoided ? TextDecoration.lineThrough : null,
          color: payment.isVoided ? Colors.grey : null,
        ),
      ),
      subtitle: Text(
        '$dateStr  •  $_methodLabel${payment.isVoided ? '  • VOIDED' : ''}',
        style: TextStyle(
          color: payment.isVoided ? Colors.grey : null,
          fontSize: 12,
        ),
      ),
      trailing: payment.isVoided
          ? const Icon(Icons.block, color: Colors.grey, size: 18)
          : (ref.watch(authProvider).user?.canManagePayment ?? false)
          ? PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'void') _confirmVoid(context);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'void',
                  child: Text('Void', style: TextStyle(color: Colors.red)),
                ),
              ],
            )
          : null,
    );
  }

  Future<void> _confirmVoid(BuildContext context) async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Void Payment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('This will void the payment and cancel the order.'),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              decoration: const InputDecoration(
                labelText: 'Reason',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Void', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      try {
        await ApiClient.instance.post(
          '/payments/${payment.id}/void',
          data: {'reason': reasonCtrl.text.trim()},
        );
        ref.invalidate(paymentsListProvider);
        messenger.showSnackBar(const SnackBar(content: Text('Payment voided')));
      } on ApiException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
    reasonCtrl.dispose();
  }
}
