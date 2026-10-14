import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/db/local_db.dart';
import '../../../core/models/cash_record.dart';
import '../../../features/auth/providers/auth_provider.dart';
import '../../cashier/providers/cashier_provider.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../../../shared/utils/csv_downloader.dart';
import '../../../shared/utils/error_utils.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/utils/toast.dart';

/// Converts locally-queued (not-yet-synced) cash records into displayable
/// [CashRecord]s. Uses id -1 as an "offline, pending sync" marker.
List<CashRecord> _pendingAsCashRecords(List<Map<String, dynamic>> rows) {
  return rows
      .map(
        (r) => CashRecord(
          id: -1,
          type: r['type'] as String,
          amount: r['amount'] as double,
          description: r['description'] as String? ?? '',
          category: r['category'] as String?,
          createdAt: DateTime.parse(r['created_at'] as String),
        ),
      )
      .toList();
}

typedef _CashRange = ({DateTime start, DateTime end});

String _formatApiDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

bool _isWithinRange(CashRecord record, _CashRange range) {
  final day = DateTime(
    record.createdAt.year,
    record.createdAt.month,
    record.createdAt.day,
  );
  return !day.isBefore(range.start) && !day.isAfter(range.end);
}

final _cashProvider = FutureProvider.autoDispose
    .family<List<CashRecord>, _CashRange>((ref, range) async {
      try {
        final res = await ApiClient.instance.get(
          '/cash-records?start_date=${_formatApiDate(range.start)}'
          '&end_date=${_formatApiDate(range.end)}',
        );
        return (res.data as List)
            .map((e) => CashRecord.fromJson(e as Map<String, dynamic>))
            .toList();
      } on Exception catch (e) {
        if (!ApiException.isOfflineFailure(e)) rethrow;
        // Offline: server history isn't reachable, but still show locally queued
        // rows that fall within the selected period.
        final pending = await LocalDb.getPendingCashRecords();
        return _pendingAsCashRecords(
          pending,
        ).where((record) => _isWithinRange(record, range)).toList();
      }
    });

/// Replays cash records that were added while offline. Call after
/// connectivity is restored.
class CashRecordSync {
  static Future<void> syncPending() async {
    final pending = await LocalDb.getPendingCashRecords();
    for (final row in pending) {
      try {
        final res = await ApiClient.instance.post(
          '/cash-records',
          data: {
            'offline_ref': row['offline_ref'],
            'type': row['type'],
            'amount': row['amount'],
            if ((row['description'] as String?)?.isNotEmpty ?? false)
              'description': row['description'],
            if (row['category'] != null) 'category': row['category'],
          },
        );

        final receiptPath = row['receipt_local_path'] as String?;
        if (receiptPath != null && await File(receiptPath).exists()) {
          final recordId = (res.data as Map<String, dynamic>)['id'];
          final form = FormData.fromMap({
            'file': await MultipartFile.fromFile(
              receiptPath,
              filename: 'receipt.jpg',
            ),
          });
          await ApiClient.instance.post(
            '/cash-records/$recordId/receipt',
            data: form,
          );
        }

        await LocalDb.markCashRecordSynced(row['offline_ref'] as String);
      } catch (e) {
        if (ApiException.isOfflineFailure(e)) return;
        await LocalDb.markCashRecordSyncError(
          row['offline_ref'] as String,
          friendlyError(e),
        );
      }
    }
  }
}

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

enum _CashPeriodMode { monthly, custom }

const _monthNames = [
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

class CashRecordsScreen extends ConsumerStatefulWidget {
  const CashRecordsScreen({super.key});

  @override
  ConsumerState<CashRecordsScreen> createState() => _CashRecordsScreenState();
}

class _CashRecordsScreenState extends ConsumerState<CashRecordsScreen> {
  _CashPeriodMode _periodMode = _CashPeriodMode.monthly;
  int _selectedYear = DateTime.now().year;
  int _selectedMonth = DateTime.now().month;
  DateTime _customStart = DateTime.now().subtract(const Duration(days: 29));
  DateTime _customEnd = DateTime.now();

  _CashRange get _selectedRange {
    if (_periodMode == _CashPeriodMode.custom) {
      return (start: _customStart, end: _customEnd);
    }
    return (
      start: DateTime(_selectedYear, _selectedMonth),
      end: DateTime(_selectedYear, _selectedMonth + 1, 0),
    );
  }

  Future<void> _pickCustomRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _customStart, end: _customEnd),
      builder: (context, child) {
        final baseTheme = Theme.of(context);
        final scheme = baseTheme.colorScheme;
        const selectedBlue = AppTheme.primaryBlue;
        final pickerTheme = baseTheme.copyWith(
          colorScheme: scheme.copyWith(
            primary: selectedBlue,
            onPrimary: Colors.white,
            secondary: selectedBlue,
            onSecondary: Colors.white,
            secondaryContainer: selectedBlue,
            onSecondaryContainer: Colors.white,
          ),
          datePickerTheme: DatePickerThemeData(
            rangePickerBackgroundColor: scheme.surface,
            rangePickerHeaderBackgroundColor: scheme.surface,
            rangePickerHeaderForegroundColor: scheme.onSurface,
            rangeSelectionBackgroundColor: selectedBlue.withValues(
              alpha: baseTheme.brightness == Brightness.dark ? 0.55 : 0.22,
            ),
            dayBackgroundColor: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.selected)
                  ? selectedBlue
                  : null;
            }),
            dayForegroundColor: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.selected)
                  ? Colors.white
                  : null;
            }),
          ),
        );
        return Theme(data: pickerTheme, child: child!);
      },
    );
    if (range != null && mounted) {
      setState(() {
        _customStart = range.start;
        _customEnd = range.end;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedRange = _selectedRange;
    final cashAsync = ref.watch(_cashProvider(selectedRange));
    final currentUser = ref.watch(authProvider).user;
    final isAdmin = currentUser?.isAdmin ?? false;
    final canAdd = currentUser?.canAddCash ?? true;
    final canEdit = currentUser?.canEditCash ?? true;
    final canDelete = currentUser?.canDeleteCash ?? true;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Cash Records'),
            Text(
              '现金记录',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: Colors.white70,
              ),
            ),
          ],
        ),
        actions: [
          if (isAdmin)
            IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: 'Export CSV / 导出',
              onPressed: () {
                final records = ref.read(_cashProvider(selectedRange)).value;
                if (records == null) return;
                _exportCsv(context, records, selectedRange);
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh / 刷新',
            onPressed: () => ref.invalidate(_cashProvider(selectedRange)),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _buildPeriodControls(),
          Expanded(
            child: cashAsync.when(
              loading: () => const _CashRecordsLoading(),
              error: (e, _) => _CashRecordsError(
                message: loadError(e),
                onRetry: () => ref.invalidate(_cashProvider(selectedRange)),
              ),
              data: (records) {
                final totalIn = records
                    .where((r) => r.isCashIn)
                    .fold(0.0, (s, r) => s + r.amount);
                final totalOut = records
                    .where((r) => !r.isCashIn)
                    .fold(0.0, (s, r) => s + r.amount);

                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1400),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Column(
                        children: [
                          _CashSummary(totalIn: totalIn, totalOut: totalOut),
                          const SizedBox(height: 14),
                          Expanded(
                            child: _RecordsPanel(
                              records: records,
                              canEdit: canEdit,
                              canDelete: canDelete,
                              onEdit: (record) =>
                                  _showEditForm(context, ref, record),
                              onDelete: (record) =>
                                  _confirmDelete(context, ref, record),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: canAdd
          ? FloatingActionButton.extended(
              onPressed: () => _showAddForm(context, ref),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add record / 新增'),
            )
          : null,
    );
  }

  Widget _buildPeriodControls() {
    final thisYear = DateTime.now().year;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final modeSelector = SegmentedButton<_CashPeriodMode>(
      style: SegmentedButton.styleFrom(
        minimumSize: const Size(0, 48),
        foregroundColor: scheme.onSurfaceVariant,
        backgroundColor: scheme.surfaceContainerHighest,
        selectedForegroundColor: Colors.white,
        selectedBackgroundColor: AppTheme.primaryBlue,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      segments: const [
        ButtonSegment(
          value: _CashPeriodMode.monthly,
          icon: Icon(Icons.calendar_month_outlined, size: 18),
          label: Text('Monthly / 按月'),
        ),
        ButtonSegment(
          value: _CashPeriodMode.custom,
          icon: Icon(Icons.date_range_outlined, size: 18),
          label: Text('Custom / 自定义'),
        ),
      ],
      selected: {_periodMode},
      showSelectedIcon: false,
      onSelectionChanged: (selection) {
        setState(() => _periodMode = selection.first);
      },
    );

    final dateControls = _periodMode == _CashPeriodMode.monthly
        ? Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _selectedYear,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Year / 年',
                    isDense: true,
                  ),
                  items: [
                    for (int year = thisYear; year >= 2020; year--)
                      DropdownMenuItem(value: year, child: Text('$year')),
                  ],
                  onChanged: (year) {
                    if (year != null) setState(() => _selectedYear = year);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<int>(
                  initialValue: _selectedMonth,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Month / 月',
                    isDense: true,
                  ),
                  items: [
                    for (int month = 1; month <= 12; month++)
                      DropdownMenuItem(
                        value: month,
                        child: Text(
                          '${month.toString().padLeft(2, '0')}  ${_monthNames[month - 1]}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (month) {
                    if (month != null) setState(() => _selectedMonth = month);
                  },
                ),
              ),
            ],
          )
        : Semantics(
            button: true,
            label: 'Select cash record date range',
            child: InkWell(
              onTap: _pickCustomRange,
              borderRadius: BorderRadius.circular(12),
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Date range / 日期范围',
                  prefixIcon: Icon(Icons.date_range_outlined),
                  suffixIcon: Icon(Icons.keyboard_arrow_down_rounded),
                  isDense: true,
                ),
                child: Text(
                  '${_formatApiDate(_customStart)}  to  ${_formatApiDate(_customEnd)}',
                ),
              ),
            ),
          );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                final heading = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: scheme.onSurface.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.calendar_today_outlined,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Reporting period / 报表时段',
                          style: theme.textTheme.labelLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _periodMode == _CashPeriodMode.monthly
                              ? '${_monthNames[_selectedMonth - 1]} $_selectedYear'
                              : '${_formatApiDate(_customStart)} to ${_formatApiDate(_customEnd)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                );

                if (wide) {
                  return Row(
                    children: [
                      SizedBox(width: 230, child: heading),
                      const SizedBox(width: 18),
                      SizedBox(width: 340, child: modeSelector),
                      const SizedBox(width: 18),
                      Expanded(child: dateControls),
                    ],
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    heading,
                    const SizedBox(height: 14),
                    modeSelector,
                    const SizedBox(height: 12),
                    dateControls,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  String _csvEscape(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  Future<void> _exportCsv(
    BuildContext context,
    List<CashRecord> records,
    _CashRange range,
  ) async {
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

    final filename =
        'cash_records_${_formatApiDate(range.start).replaceAll('-', '')}'
        '_${_formatApiDate(range.end).replaceAll('-', '')}.csv';

    final result = await downloadCsv(buffer.toString(), filename);

    if (context.mounted) {
      showToast(
        context,
        result == filename
            ? 'CSV downloaded: $filename'
            : 'CSV saved to: $result',
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
        onSaved: () {
          ref.invalidate(_cashProvider);
          ref.invalidate(pendingSyncCountProvider);
        },
      ),
    );
  }

  Future<void> _showEditForm(
    BuildContext context,
    WidgetRef ref,
    CashRecord record,
  ) async {
    final amountCtrl = TextEditingController(
      text: record.amount.toStringAsFixed(2),
    );
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
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: descCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Description / 说明 (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  initialValue: category,
                  decoration: const InputDecoration(
                    labelText: 'Category / 类别',
                    border: OutlineInputBorder(),
                  ),
                  hint: const Text('None / 无'),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('None / 无'),
                    ),
                    ..._categories.map(
                      (c) => DropdownMenuItem(
                        value: c.$1,
                        child: Text(
                          '${c.$1} / ${c.$2}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (v) => setState(() => category = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final amount = double.tryParse(amountCtrl.text.trim());
                if (amount == null || amount <= 0) return;
                Navigator.pop(ctx);
                try {
                  await ApiClient.instance.put(
                    '/cash-records/${record.id}',
                    data: {
                      'amount': amount,
                      if (descCtrl.text.trim().isNotEmpty)
                        'description': descCtrl.text.trim(),
                      'category': category,
                    },
                  );
                  ref.invalidate(_cashProvider);
                } catch (e) {
                  if (context.mounted) {
                    showToast(context, friendlyError(e), error: true);
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
    BuildContext context,
    WidgetRef ref,
    CashRecord record,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Record / 删除记录'),
        content: Text(
          'Delete "${record.description}" (${formatRM(record.amount)})?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
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
          showToast(context, friendlyError(e), error: true);
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
    final offlineRef = const Uuid().v4();
    final amount = double.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      showToast(context, 'Please enter a valid amount.', error: true);
      return;
    }
    final desc = _descCtrl.text.trim();

    setState(() => _saving = true);
    try {
      final res = await ApiClient.instance.post(
        '/cash-records',
        data: {
          'offline_ref': offlineRef,
          'type': _type,
          'amount': amount,
          if (desc.isNotEmpty) 'description': desc,
          if (_category != null) 'category': _category,
        },
      );

      if (_receiptImage != null) {
        final recordId = (res.data as Map<String, dynamic>)['id'];
        final form = FormData.fromMap({
          'file': await MultipartFile.fromFile(
            _receiptImage!.path,
            filename: 'receipt.jpg',
          ),
        });
        await ApiClient.instance.post(
          '/cash-records/$recordId/receipt',
          data: form,
        );
      }

      if (mounted) {
        Navigator.pop(context);
        widget.onSaved();
      }
    } on Exception catch (e) {
      // A real server-side rejection (validation, auth, etc.) should not
      // silently queue something the server will just reject again.
      if (!ApiException.isOfflineFailure(e)) {
        if (mounted) {
          setState(() => _saving = false);
          showToast(context, friendlyError(e), error: true);
        }
        return;
      }
      // Otherwise treat it as a connectivity failure and queue locally
      // instead of losing the entry. It will replay once back online.
      await LocalDb.savePendingCashRecord({
        'offline_ref': offlineRef,
        'type': _type,
        'amount': amount,
        'description': desc,
        'category': _category,
        'receipt_local_path': _receiptImage?.path,
        'created_at': DateTime.now().toIso8601String(),
        'synced': 0,
      });
      if (mounted) {
        Navigator.pop(context);
        widget.onSaved();
        showToast(
          context,
          'Saved offline. Will sync when back online. / '
          '已离线保存，联网后自动同步。',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showToast(context, friendlyError(e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCashOut = _type == 'cash_out';
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
                  color: scheme.outlineVariant,
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
              style: SegmentedButton.styleFrom(
                minimumSize: const Size(0, 48),
                foregroundColor: scheme.onSurfaceVariant,
                backgroundColor: scheme.surfaceContainerHighest,
                selectedForegroundColor: Colors.white,
                selectedBackgroundColor: AppTheme.primaryBlue,
                side: BorderSide(color: scheme.outlineVariant),
              ),
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
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
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
                initialValue: _category,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Category / 类别 (optional)',
                  border: OutlineInputBorder(),
                ),
                hint: const Text('Select category / 选择类别'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('None / 无')),
                  ..._categories.map(
                    (c) => DropdownMenuItem(
                      value: c.$1,
                      child: Text(
                        '${c.$1} / ${c.$2}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
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
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scheme.outlineVariant),
                  color: scheme.surfaceContainerHighest,
                ),
                child: _receiptImage != null
                    ? Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              _receiptImage!,
                              width: double.infinity,
                              height: 160,
                              fit: BoxFit.cover,
                            ),
                          ),
                          Positioned(
                            top: 6,
                            right: 6,
                            child: GestureDetector(
                              onTap: () => setState(() => _receiptImage = null),
                              child: const CircleAvatar(
                                radius: 12,
                                backgroundColor: Colors.red,
                                child: Icon(
                                  Icons.close,
                                  size: 14,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.receipt_long,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Upload Receipt / 上传收据 (optional)',
                            style: TextStyle(color: scheme.onSurfaceVariant),
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

class _CashSummary extends StatelessWidget {
  final double totalIn;
  final double totalOut;

  const _CashSummary({required this.totalIn, required this.totalOut});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final net = totalIn - totalOut;
        final netColor = net < 0 ? AppTheme.danger : AppTheme.info;
        final netCard = _SummaryMetricCard(
          label: 'Net balance / 净额',
          value: formatRM(net),
          icon: Icons.account_balance_wallet_outlined,
          color: netColor,
          emphasized: true,
        );
        final inCard = _SummaryMetricCard(
          label: 'Cash in / 收入',
          value: formatRM(totalIn),
          icon: Icons.south_west_rounded,
          color: AppTheme.success,
        );
        final outCard = _SummaryMetricCard(
          label: 'Cash out / 支出',
          value: formatRM(totalOut),
          icon: Icons.north_east_rounded,
          color: AppTheme.danger,
        );

        if (wide) {
          return SizedBox(
            height: 112,
            child: Row(
              children: [
                Expanded(flex: 2, child: netCard),
                const SizedBox(width: 12),
                Expanded(child: inCard),
                const SizedBox(width: 12),
                Expanded(child: outCard),
              ],
            ),
          );
        }

        return Column(
          children: [
            SizedBox(height: 104, child: netCard),
            const SizedBox(height: 10),
            SizedBox(
              height: 104,
              child: Row(
                children: [
                  Expanded(child: inCard),
                  const SizedBox(width: 10),
                  Expanded(child: outCard),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SummaryMetricCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final bool emphasized;

  const _SummaryMetricCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: emphasized ? color.withValues(alpha: 0.10) : scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: emphasized
              ? color.withValues(alpha: 0.34)
              : scheme.outlineVariant,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: color,
                    fontSize: emphasized ? 26 : 20,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordsPanel extends StatelessWidget {
  final List<CashRecord> records;
  final bool canEdit;
  final bool canDelete;
  final Future<void> Function(CashRecord record) onEdit;
  final Future<void> Function(CashRecord record) onDelete;

  const _RecordsPanel({
    required this.records,
    required this.canEdit,
    required this.canDelete,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
                Text(
                  'Transactions / 交易记录',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${records.length} ${records.length == 1 ? 'record' : 'records'}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(
            child: records.isEmpty
                ? const _CashRecordsEmpty()
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: records.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      indent: 76,
                      color: scheme.outlineVariant,
                    ),
                    itemBuilder: (context, index) {
                      final record = records[index];
                      return _CashRecordRow(
                        record: record,
                        canEdit: canEdit,
                        canDelete: canDelete,
                        onEdit: () => onEdit(record),
                        onDelete: () => onDelete(record),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CashRecordRow extends StatelessWidget {
  final CashRecord record;
  final bool canEdit;
  final bool canDelete;
  final Future<void> Function() onEdit;
  final Future<void> Function() onDelete;

  const _CashRecordRow({
    required this.record,
    required this.canEdit,
    required this.canDelete,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isPending = record.id == -1;
    final color = record.isCashIn ? AppTheme.success : AppTheme.danger;
    final date = record.createdAt;
    final dateText =
        '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
    final metadata = [
      if (record.category?.isNotEmpty ?? false) record.category!,
      dateText,
    ].join('  |  ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              record.isCashIn
                  ? Icons.south_west_rounded
                  : Icons.north_east_rounded,
              color: color,
              size: 21,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        record.description.trim().isEmpty
                            ? (record.isCashIn
                                  ? 'Cash in / 收入'
                                  : 'Cash out / 支出')
                            : record.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (isPending) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.warning.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Pending / 待同步',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppTheme.warning,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  metadata,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Text(
            '${record.isCashIn ? '+' : '-'} ${formatRM(record.amount)}',
            style: theme.textTheme.titleMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if ((canEdit || canDelete) && !isPending) ...[
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              tooltip: 'Actions / 操作',
              icon: Icon(
                Icons.more_vert_rounded,
                color: scheme.onSurfaceVariant,
              ),
              onSelected: (value) async {
                if (value == 'edit') await onEdit();
                if (value == 'delete') await onDelete();
              },
              itemBuilder: (_) => [
                if (canEdit)
                  const PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined, size: 20),
                      title: Text('Edit / 编辑'),
                    ),
                  ),
                if (canDelete)
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.delete_outline_rounded,
                        size: 20,
                        color: AppTheme.danger,
                      ),
                      title: Text(
                        'Delete / 删除',
                        style: TextStyle(color: AppTheme.danger),
                      ),
                    ),
                  ),
              ],
            ),
          ] else
            const SizedBox(width: 12),
        ],
      ),
    );
  }
}

class _CashRecordsEmpty extends StatelessWidget {
  const _CashRecordsEmpty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                Icons.receipt_long_outlined,
                size: 32,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'No cash activity / 暂无现金记录',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              'Try another period or add a new record.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CashRecordsLoading extends StatelessWidget {
  const _CashRecordsLoading();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        children: [
          SizedBox(
            height: 112,
            child: Row(
              children: [
                for (var index = 0; index < 3; index++) ...[
                  if (index > 0) const SizedBox(width: 12),
                  Expanded(
                    flex: index == 0 ? 2 : 1,
                    child: _SkeletonBlock(color: scheme.surface),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Expanded(child: _SkeletonBlock(color: scheme.surface)),
        ],
      ),
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  final Color color;
  const _SkeletonBlock({required this.color});

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
  );
}

class _CashRecordsError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _CashRecordsError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 42,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 14),
              Text(
                'Could not load records / 无法加载记录',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again / 重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
