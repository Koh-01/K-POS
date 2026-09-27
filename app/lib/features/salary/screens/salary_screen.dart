import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/models/worker.dart';
import '../../../core/models/salary_payment.dart';
import '../../../features/payments/services/receipt_printer.dart';
import '../../../features/settings/providers/settings_provider.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../../../shared/utils/error_utils.dart';
import '../../../shared/widgets/signature_pad.dart';

// ── Providers ──────────────────────────────────────────────────────────────

final _workersProvider = FutureProvider.autoDispose<List<Worker>>((ref) async {
  final res = await ApiClient.instance.get('/salary/workers');
  return (res.data as List)
      .map((e) => Worker.fromJson(e as Map<String, dynamic>))
      .toList();
});

final _paymentsProvider = FutureProvider.autoDispose<List<SalaryPayment>>((
  ref,
) async {
  final res = await ApiClient.instance.get('/salary/payments');
  return (res.data as List)
      .map((e) => SalaryPayment.fromJson(e as Map<String, dynamic>))
      .toList();
});

// ── Main Screen ────────────────────────────────────────────────────────────

class SalaryScreen extends ConsumerWidget {
  const SalaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Salary / 薪资'),
          bottom: TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white.withValues(alpha: 0.55),
            indicatorColor: Colors.white,
            tabs: const [
              Tab(icon: Icon(Icons.people_outline), text: 'Workers / 员工'),
              Tab(icon: Icon(Icons.payments_outlined), text: 'History / 薪资记录'),
            ],
          ),
        ),
        body: const TabBarView(children: [_WorkersTab(), _PaymentsTab()]),
      ),
    );
  }
}

// ── Workers Tab ────────────────────────────────────────────────────────────

class _WorkersTab extends ConsumerWidget {
  const _WorkersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workersAsync = ref.watch(_workersProvider);

    return Scaffold(
      body: workersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(loadError(e))),
        data: (workers) => workers.isEmpty
            ? const Center(
                child: Text(
                  'No workers yet.\nTap + to add one.',
                  textAlign: TextAlign.center,
                ),
              )
            : ListView.separated(
                itemCount: workers.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 72),
                itemBuilder: (ctx, i) => _WorkerTile(
                  worker: workers[i],
                  onRefreshWorkers: () => ref.invalidate(_workersProvider),
                  onRefreshPayments: () => ref.invalidate(_paymentsProvider),
                ),
              ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            builder: (_) => const _WorkerFormSheet(worker: null),
          );
          ref.invalidate(_workersProvider);
        },
        child: const Icon(Icons.person_add),
      ),
    );
  }
}

// ── Worker Tile ────────────────────────────────────────────────────────────

class _WorkerTile extends StatelessWidget {
  final Worker worker;
  final VoidCallback onRefreshWorkers;
  final VoidCallback onRefreshPayments;

  const _WorkerTile({
    required this.worker,
    required this.onRefreshWorkers,
    required this.onRefreshPayments,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (worker.position != null && worker.position!.isNotEmpty)
        worker.position!,
      if (worker.phone != null && worker.phone!.isNotEmpty) worker.phone!,
    ].join(' · ');

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF1E6FD9).withValues(alpha: 0.15),
        child: Text(
          worker.name[0].toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF1E6FD9),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(
        worker.name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: subtitle.isNotEmpty ? Text(subtitle) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            onPressed: () => _showPaySheet(context),
            icon: const Icon(Icons.attach_money, size: 16),
            label: const Text('Pay'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF10B981),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'edit') {
                await showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  builder: (_) => _WorkerFormSheet(worker: worker),
                );
                onRefreshWorkers();
              } else if (v == 'delete') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Remove Worker / 删除员工'),
                    content: Text('Remove "${worker.name}"?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                        child: const Text('Remove'),
                      ),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  try {
                    await ApiClient.instance.delete(
                      '/salary/workers/${worker.id}',
                    );
                    onRefreshWorkers();
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                        ..clearSnackBars()
                        ..showSnackBar(
                          SnackBar(content: Text(friendlyError(e))),
                        );
                    }
                  }
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit / 编辑')),
              PopupMenuItem(value: 'delete', child: Text('Remove / 删除')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showPaySheet(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _PaySalarySheet(worker: worker),
    );
    onRefreshPayments();
  }
}

// ── Payments Tab ───────────────────────────────────────────────────────────

class _PaymentsTab extends ConsumerWidget {
  const _PaymentsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paymentsAsync = ref.watch(_paymentsProvider);

    return paymentsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(loadError(e))),
      data: (payments) => payments.isEmpty
          ? const Center(child: Text('No salary payments yet / 暂无薪资记录'))
          : ListView.separated(
              itemCount: payments.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
              itemBuilder: (ctx, i) => _PaymentTile(
                payment: payments[i],
                onRefresh: () => ref.invalidate(_paymentsProvider),
              ),
            ),
    );
  }
}

// ── Payment Tile ───────────────────────────────────────────────────────────

class _PaymentTile extends ConsumerWidget {
  final SalaryPayment payment;
  final VoidCallback onRefresh;

  const _PaymentTile({required this.payment, required this.onRefresh});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = payment;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF10B981).withValues(alpha: 0.12),
        child: const Icon(
          Icons.payments_outlined,
          color: Color(0xFF10B981),
          size: 20,
        ),
      ),
      title: Text(
        p.workerName,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          p.monthLabel,
          if (p.note != null && p.note!.isNotEmpty) p.note!,
        ].join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (p.signatureImageUrl != null)
            IconButton(
              icon: const Icon(Icons.draw_outlined, size: 18),
              tooltip: 'View Signature',
              onPressed: () => _viewSignature(context, p),
            ),
          Text(
            formatRM(p.amount),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Color(0xFF10B981),
              fontSize: 15,
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (v) async {
              if (v == 'reprint') {
                await _reprint(context, ref, p);
              } else if (v == 'edit') {
                await showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  builder: (_) => _EditPaymentSheet(payment: p),
                );
                onRefresh();
              } else if (v == 'delete') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete Payment / 删除记录'),
                    content: Text(
                      'Delete ${p.workerName} ${p.monthLabel} ${formatRM(p.amount)}?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  try {
                    await ApiClient.instance.delete('/salary/payments/${p.id}');
                    onRefresh();
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                        ..clearSnackBars()
                        ..showSnackBar(
                          SnackBar(content: Text(friendlyError(e))),
                        );
                    }
                  }
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'reprint',
                child: Row(
                  children: [
                    Icon(Icons.print_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('Reprint / 重新打印'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('Edit Amount / 修改数额'),
                  ],
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 18, color: Colors.red),
                    SizedBox(width: 10),
                    Text('Delete / 删除', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _viewSignature(BuildContext context, SalaryPayment p) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${p.workerName} · ${p.monthLabel}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  color: Colors.white,
                  child: Image.network(
                    p.signatureImageUrl!,
                    errorBuilder: (_, _, _) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Failed to load signature'),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _reprint(
    BuildContext context,
    WidgetRef ref,
    SalaryPayment p,
  ) async {
    try {
      final settings = await ref.read(settingsProvider.future);
      await ReceiptPrinter.printSalarySlip(
        workerName: p.workerName,
        position: '',
        year: p.year,
        month: p.month,
        amount: p.amount,
        note: p.note,
        storeName: settings.storeName,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(content: Text('Salary slip printed')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: const Text(
                'Print failed. Make sure the printer is connected and try again.',
              ),
              backgroundColor: Colors.red,
            ),
          );
      }
    }
  }
}

// ── Edit Payment Sheet ─────────────────────────────────────────────────────

class _EditPaymentSheet extends StatefulWidget {
  final SalaryPayment payment;
  const _EditPaymentSheet({required this.payment});

  @override
  State<_EditPaymentSheet> createState() => _EditPaymentSheetState();
}

class _EditPaymentSheetState extends State<_EditPaymentSheet> {
  late final TextEditingController _amountCtrl;
  late final TextEditingController _noteCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController(
      text: widget.payment.amount.toStringAsFixed(2),
    );
    _noteCtrl = TextEditingController(text: widget.payment.note ?? '');
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('Please enter a valid amount.')),
        );
      return;
    }
    setState(() => _saving = true);
    try {
      await ApiClient.instance.put(
        '/salary/payments/${widget.payment.id}',
        data: {
          'amount': amount,
          'note': _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
        },
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payment;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
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
            const Text(
              'Edit Salary / 修改薪资',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '${p.workerName} · ${p.monthLabel}',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _amountCtrl,
              decoration: const InputDecoration(
                labelText: 'Amount / 数额 (RM)',
                prefixText: 'RM ',
                border: OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteCtrl,
              decoration: const InputDecoration(
                labelText: 'Note / 备注 (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _saving
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save / 保存', style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Worker Form Sheet ──────────────────────────────────────────────────────

class _WorkerFormSheet extends StatefulWidget {
  final Worker? worker;
  const _WorkerFormSheet({required this.worker});

  @override
  State<_WorkerFormSheet> createState() => _WorkerFormSheetState();
}

class _WorkerFormSheetState extends State<_WorkerFormSheet> {
  final _nameCtrl = TextEditingController();
  final _positionCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.worker != null) {
      _nameCtrl.text = widget.worker!.name;
      _positionCtrl.text = widget.worker!.position ?? '';
      _phoneCtrl.text = widget.worker!.phone ?? '';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _positionCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('Name is required')));
      return;
    }
    setState(() => _saving = true);
    try {
      final payload = {
        'name': name,
        'position': _positionCtrl.text.trim().isEmpty
            ? null
            : _positionCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
      };
      if (widget.worker == null) {
        await ApiClient.instance.post('/salary/workers', data: payload);
      } else {
        await ApiClient.instance.put(
          '/salary/workers/${widget.worker!.id}',
          data: payload,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.worker != null;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
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
            Text(
              isEdit ? 'Edit Worker / 编辑员工' : 'Add Worker / 添加员工',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Name / 姓名 *',
                border: OutlineInputBorder(),
              ),
              autofocus: !isEdit,
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _positionCtrl,
              decoration: const InputDecoration(
                labelText: 'Position / 职位 (optional)',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneCtrl,
              decoration: const InputDecoration(
                labelText: 'Phone / 电话 (optional)',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _saving
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      isEdit ? 'Save / 保存' : 'Add / 添加',
                      style: const TextStyle(fontSize: 16),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Pay Salary Sheet ───────────────────────────────────────────────────────

class _PaySalarySheet extends ConsumerStatefulWidget {
  final Worker worker;
  const _PaySalarySheet({required this.worker});

  @override
  ConsumerState<_PaySalarySheet> createState() => _PaySalarySheetState();
}

class _PaySalarySheetState extends ConsumerState<_PaySalarySheet> {
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  late int _year;
  late int _month;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  static const _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  Future<void> _save() async {
    final amount = double.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('Please enter a valid amount.')),
        );
      return;
    }

    // Signature is captured *before* the payment is created, so cancelling
    // it aborts the whole save instead of leaving an unsigned payment on
    // record when the setting requires one.
    final requireSignature =
        ref.read(settingsProvider).value?.requireSalarySignature ?? false;
    Uint8List? signature;
    if (requireSignature) {
      if (!mounted) return;
      signature = await SignatureCaptureSheet.show(
        context,
        title: 'Worker Signature',
        subtitle:
            '${widget.worker.name} · ${_monthNames[_month - 1]} $_year · ${formatRM(amount)}',
      );
      if (signature == null) return; // cancelled — nothing saved
    }

    setState(() => _saving = true);
    try {
      final res = await ApiClient.instance.post(
        '/salary/payments',
        data: {
          'worker_id': widget.worker.id,
          'year': _year,
          'month': _month,
          'amount': amount,
          if (_noteCtrl.text.trim().isNotEmpty) 'note': _noteCtrl.text.trim(),
        },
      );

      if (signature != null) {
        final paymentId = (res.data as Map<String, dynamic>)['id'];
        final form = FormData.fromMap({
          'file': MultipartFile.fromBytes(signature, filename: 'signature.png'),
        });
        await ApiClient.instance.post(
          '/salary/payments/$paymentId/signature',
          data: form,
        );
      }

      if (!mounted) return;

      // Ask about printing BEFORE popping (context still valid here)
      final shouldPrint = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Payment Saved!'),
          content: Text(
            '${widget.worker.name} · ${_monthNames[_month - 1]} $_year\n${formatRM(amount)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Skip'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.print, size: 16),
                  SizedBox(width: 6),
                  Text('Print Slip'),
                ],
              ),
            ),
          ],
        ),
      );

      if (!mounted) return;
      if (shouldPrint == true) {
        try {
          // Print while this sheet is still mounted. Closing it first disposed
          // the ConsumerState and made later ref/context access fail.
          final settings = await ref.read(settingsProvider.future);
          await ReceiptPrinter.printSalarySlip(
            workerName: widget.worker.name,
            position: widget.worker.position ?? '',
            year: _year,
            month: _month,
            amount: amount,
            note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
            storeName: settings.storeName,
          );
          if (mounted) {
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(
                const SnackBar(content: Text('Salary slip printed')),
              );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(
                const SnackBar(
                  content: Text(
                    'Print failed. Make sure the printer is connected and try again.',
                  ),
                  backgroundColor: Colors.red,
                ),
              );
          }
        }
      }
      if (mounted) Navigator.pop(context); // close the pay sheet last
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final years = [now.year - 1, now.year, now.year + 1];

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
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
            Text(
              'Pay Salary / 发薪',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              widget.worker.name,
              style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 16),

            // Month / Year row
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<int>(
                    initialValue: _month,
                    decoration: const InputDecoration(
                      labelText: 'Month / 月份',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                    ),
                    items: List.generate(
                      12,
                      (i) => DropdownMenuItem(
                        value: i + 1,
                        child: Text(_monthNames[i]),
                      ),
                    ),
                    onChanged: (v) => setState(() => _month = v!),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _year,
                    decoration: const InputDecoration(
                      labelText: 'Year / 年',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                    ),
                    items: years
                        .map(
                          (y) => DropdownMenuItem(
                            value: y,
                            child: Text(y.toString()),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _year = v!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Amount
            TextField(
              controller: _amountCtrl,
              decoration: const InputDecoration(
                labelText: 'Amount / 金额 (RM)',
                prefixText: 'RM ',
                border: OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),

            // Note
            TextField(
              controller: _noteCtrl,
              decoration: const InputDecoration(
                labelText: 'Note / 备注 (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),

            ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
              ),
              child: _saving
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Confirm & Pay / 确认发薪',
                      style: TextStyle(fontSize: 16),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
