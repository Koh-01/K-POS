import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/api/api_client.dart';
import '../../../core/models/cash_record.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../../../shared/utils/csv_downloader.dart';
import '../../../shared/utils/error_utils.dart';

final _cashProvider = FutureProvider.autoDispose<List<CashRecord>>((ref) async {
  final res = await ApiClient.instance.get('/cash-records');
  return (res.data as List)
      .map((e) => CashRecord.fromJson(e as Map<String, dynamic>))
      .toList();
});

// (English, 中文)
const _categories = [
  ('Entertainment', '娱乐'),
  ('Frozen Food', '冷冻食品'),
  ('House Keeping & Cleaning', '家务清洁'),
  ('Maintenance', '维修保养'),
  ('New Machine', '新机器'),
  ('Petrol', '油费'),
  ('Seafood', '海鲜'),
  ('Utilities', '公用事业'),
  ('Labor Cost', '人工费'),
  ('Miscellaneous', '杂项'),
  ('Cash Out', '现金支出'),
];

class CashRecordsScreen extends ConsumerWidget {
  const CashRecordsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cashAsync = ref.watch(_cashProvider);
    final currentUser = ref.watch(authProvider).user;
    final isAdmin = currentUser?.isAdmin ?? false;
    final canAdd    = currentUser?.canAddCash    ?? true;
    final canEdit   = currentUser?.canEditCash   ?? true;
    final canDelete = currentUser?.canDeleteCash ?? true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cash Records / 现金记录'),
        actions: [
          if (isAdmin)
            IconButton(
              icon: const Icon(Icons.download),
              tooltip: 'Export CSV',
              onPressed: () {
                final records = ref.read(_cashProvider).value;
                if (records == null) return;
                _exportCsv(context, records);
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(_cashProvider),
          ),
        ],
      ),
      body: cashAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(loadError(e))),
        data: (records) {
          final totalIn = records
              .where((r) => r.isCashIn)
              .fold(0.0, (s, r) => s + r.amount);
          final totalOut = records
              .where((r) => !r.isCashIn)
              .fold(0.0, (s, r) => s + r.amount);

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: _SummaryChip(
                          label: 'Cash In / 收入',
                          value: formatRM(totalIn),
                          color: const Color(0xFF10B981)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _SummaryChip(
                          label: 'Cash Out / 支出',
                          value: formatRM(totalOut),
                          color: const Color(0xFFEF4444)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _SummaryChip(
                          label: 'Net / 净额',
                          value: formatRM(totalIn - totalOut),
                          color: const Color(0xFF1E6FD9)),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: records.isEmpty
                    ? const Center(child: Text('No records / 暂无记录'))
                    : ListView.builder(
                        itemCount: records.length,
                        itemBuilder: (ctx, i) {
                          final r = records[i];
                          final date = r.createdAt;
                          final subtitle = [
                            if (r.category != null) r.category!,
                            '${date.day}/${date.month}/${date.year}',
                          ].join(' · ');
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: r.isCashIn
                                  ? const Color(0xFF10B981).withValues(alpha: 0.15)
                                  : const Color(0xFFEF4444).withValues(alpha: 0.15),
                              child: Icon(
                                r.isCashIn
                                    ? Icons.arrow_downward
                                    : Icons.arrow_upward,
                                color: r.isCashIn
                                    ? const Color(0xFF10B981)
                                    : const Color(0xFFEF4444),
                              ),
                            ),
                            title: Text(r.description),
                            subtitle: Text(subtitle),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${r.isCashIn ? '+' : '-'} ${formatRM(r.amount)}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: r.isCashIn
                                        ? const Color(0xFF10B981)
                                        : const Color(0xFFEF4444),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                if (canEdit || canDelete)
                                  PopupMenuButton<String>(
                                    icon: const Icon(Icons.more_vert, size: 18),
                                    onSelected: (v) async {
                                      if (v == 'edit') {
                                        await _showEditForm(context, ref, r);
                                      } else if (v == 'delete') {
                                        await _confirmDelete(context, ref, r);
                                      }
                                    },
                                    itemBuilder: (_) => [
                                      if (canEdit)
                                        const PopupMenuItem(value: 'edit', child: Text('Edit / 编辑')),
                                      if (canDelete)
                                        const PopupMenuItem(value: 'delete', child: Text('Delete / 删除')),
                                    ],
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: canAdd
          ? FloatingActionButton(
              onPressed: () => _showAddForm(context, ref),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  String _csvEscape(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  Future<void> _exportCsv(BuildContext context, List<CashRecord> records) async {
    final buffer = StringBuffer();
    buffer.writeln('Date,Note,Category,Amount,Type,Image');
    for (final r in records) {
      final date =
          '${r.createdAt.year}-${r.createdAt.month.toString().padLeft(2, '0')}-${r.createdAt.day.toString().padLeft(2, '0')}';
      final note = _csvEscape(r.description);
      final category = _csvEscape(r.category ?? '');
      final amount = r.amount.toStringAsFixed(2);
      final type = r.isCashIn ? 'Cash In' : 'Cash Out';
      final image = _csvEscape(r.receiptImagePath ?? '');
      buffer.writeln('$date,$note,$category,$amount,$type,$image');
    }

    final now = DateTime.now();
    final filename =
        'cash_records_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.csv';

    final result = await downloadCsv(buffer.toString(), filename);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result == filename
              ? 'CSV downloaded: $filename'
              : 'CSV saved to: $result'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _showAddForm(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _CashRecordForm(
        onSaved: () => ref.invalidate(_cashProvider),
      ),
    );
  }

  Future<void> _showEditForm(
      BuildContext context, WidgetRef ref, CashRecord record) async {
    final amountCtrl =
        TextEditingController(text: record.amount.toStringAsFixed(2));
    final descCtrl = TextEditingController(text: record.description);
    String? category = record.category;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Edit Record / 编辑记录'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: amountCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Amount / 金额 (RM)',
                      prefixText: 'RM ',
                      border: OutlineInputBorder()),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: descCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Description / 说明 (optional)',
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  value: category,
                  decoration: const InputDecoration(
                      labelText: 'Category / 类别',
                      border: OutlineInputBorder()),
                  hint: const Text('None / 无'),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('None / 无')),
                    ..._categories.map((c) => DropdownMenuItem(
                          value: c.$1,
                          child: Text(
                            '${c.$1} / ${c.$2}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        )),
                  ],
                  onChanged: (v) => setState(() => category = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final amount = double.tryParse(amountCtrl.text.trim());
                if (amount == null || amount <= 0) return;
                Navigator.pop(ctx);
                try {
                  await ApiClient.instance.put('/cash-records/${record.id}',
                      data: {
                        'amount': amount,
                        if (descCtrl.text.trim().isNotEmpty)
                          'description': descCtrl.text.trim(),
                        'category': category,
                      });
                  ref.invalidate(_cashProvider);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(friendlyError(e))));
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    amountCtrl.dispose();
    descCtrl.dispose();
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, CashRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Record / 删除记录'),
        content: Text(
            'Delete "${record.description}" (${formatRM(record.amount)})?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await ApiClient.instance.delete('/cash-records/${record.id}');
        ref.invalidate(_cashProvider);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(friendlyError(e))));
        }
      }
    }
  }
}

class _CashRecordForm extends StatefulWidget {
  final VoidCallback onSaved;
  const _CashRecordForm({required this.onSaved});

  @override
  State<_CashRecordForm> createState() => _CashRecordFormState();
}

class _CashRecordFormState extends State<_CashRecordForm> {
  String _type = 'cash_out';
  String? _category;
  final _amountCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  File? _receiptImage;
  bool _saving = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickReceipt() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (picked != null) setState(() => _receiptImage = File(picked.path));
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a valid amount.')));
      return;
    }
    final desc = _descCtrl.text.trim();

    setState(() => _saving = true);
    try {
      final res = await ApiClient.instance.post('/cash-records', data: {
        'type': _type,
        'amount': amount,
        if (desc.isNotEmpty) 'description': desc,
        if (_category != null) 'category': _category,
      });

      if (_receiptImage != null) {
        final recordId = (res.data as Map<String, dynamic>)['id'];
        final form = FormData.fromMap({
          'file': await MultipartFile.fromFile(
            _receiptImage!.path,
            filename: 'receipt.jpg',
          ),
        });
        await ApiClient.instance.post('/cash-records/$recordId/receipt', data: form);
      }

      if (mounted) {
        Navigator.pop(context);
        widget.onSaved();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCashOut = _type == 'cash_out';
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
            // Drag handle
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
              'Add Record / 新增记录',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // Type toggle
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'cash_out',
                  label: Text('Cash Out / 支出'),
                  icon: Icon(Icons.arrow_upward),
                ),
                ButtonSegment(
                  value: 'cash_in',
                  label: Text('Cash In / 收入'),
                  icon: Icon(Icons.arrow_downward),
                ),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() {
                _type = s.first;
                if (!isCashOut) _category = null;
              }),
            ),
            const SizedBox(height: 16),

            // Amount
            TextField(
              controller: _amountCtrl,
              decoration: const InputDecoration(
                labelText: 'Amount / 金额 (RM)',
                prefixText: 'RM ',
                border: OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              autofocus: true,
            ),
            const SizedBox(height: 12),

            // Description
            TextField(
              controller: _descCtrl,
              decoration: const InputDecoration(
                labelText: 'Description / 说明',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),

            // Category (cash_out only)
            if (isCashOut) ...[
              DropdownButtonFormField<String?>(
                value: _category,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Category / 类别 (optional)',
                  border: OutlineInputBorder(),
                ),
                hint: const Text('Select category / 选择类别'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('None / 无')),
                  ..._categories.map((c) => DropdownMenuItem(
                        value: c.$1,
                        child: Text(
                          '${c.$1} / ${c.$2}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      )),
                ],
                onChanged: (v) => setState(() => _category = v),
              ),
              const SizedBox(height: 12),
            ],

            // Receipt photo
            GestureDetector(
              onTap: _pickReceipt,
              child: Container(
                height: _receiptImage != null ? 160 : 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade400),
                  color: Colors.grey.shade50,
                ),
                child: _receiptImage != null
                    ? Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(_receiptImage!,
                                width: double.infinity,
                                height: 160,
                                fit: BoxFit.cover),
                          ),
                          Positioned(
                            top: 6,
                            right: 6,
                            child: GestureDetector(
                              onTap: () => setState(() => _receiptImage = null),
                              child: const CircleAvatar(
                                radius: 12,
                                backgroundColor: Colors.red,
                                child: Icon(Icons.close, size: 14, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.receipt_long, color: Colors.grey.shade500),
                          const SizedBox(width: 8),
                          Text(
                            'Upload Receipt / 上传收据 (optional)',
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                        ],
                      ),
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

class _SummaryChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _SummaryChip(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Text(label,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: color, fontSize: 13)),
          ],
        ),
      );
}
