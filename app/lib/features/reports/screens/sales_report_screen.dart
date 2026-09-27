import 'dart:math' show max;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../core/api/api_client.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../../../shared/utils/error_utils.dart';

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

double _parseRev(dynamic v) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0.0;
}

int _parseInt(dynamic v) {
  if (v is int) return v;
  return int.tryParse(v.toString()) ?? 0;
}

const _kBlue = Color(0xFF1E6FD9);
const _kGreen = Color(0xFF10B981);
const _kPurple = Color(0xFF8B5CF6);

const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

class SalesReportScreen extends ConsumerStatefulWidget {
  const SalesReportScreen({super.key});

  @override
  ConsumerState<SalesReportScreen> createState() => _SalesReportScreenState();
}

class _SalesReportScreenState extends ConsumerState<SalesReportScreen> {
  // 0=Daily, 1=Monthly, 2=Yearly, 3=Custom
  int _tabIndex = 0;
  static const _tabLabels = ['Daily', 'Monthly', 'Yearly', 'Custom'];

  int _dailyDays = 30;
  int _monthlyYear = DateTime.now().year;
  DateTime _customStart = DateTime.now().subtract(const Duration(days: 29));
  DateTime _customEnd = DateTime.now();
  bool _customApplied = false;

  List<_DataPoint>? _breakdown;
  double _totalRevenue = 0;
  int _totalOrders = 0;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_tabIndex == 3 && !_customApplied) return;
    setState(() {
      _loading = true;
      _error = null;
      _breakdown = null;
    });
    try {
      final result = await _fetchData();
      setState(() {
        _breakdown = result.$1;
        _totalRevenue = result.$2;
        _totalOrders = result.$3;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  Future<(List<_DataPoint>, double, int)> _fetchData() async {
    switch (_tabIndex) {
      case 0: // Daily
        final end = DateTime.now();
        final start = end.subtract(Duration(days: _dailyDays - 1));
        final r = await ApiClient.instance.get(
          '/reports/sales?start_date=${_fmtDate(start)}&end_date=${_fmtDate(end)}',
        );
        final data = r.data as Map<String, dynamic>;
        final rows = (data['daily_breakdown'] as List).map((e) {
          final dateStr = e['date'] as String;
          final label = dateStr.length >= 7
              ? dateStr.substring(5)
              : dateStr; // MM-DD
          return _DataPoint(
            label: label,
            revenue: _parseRev(e['revenue']),
            orders: _parseInt(e['orders']),
          );
        }).toList();
        return (
          rows,
          _parseRev(data['total_revenue']),
          _parseInt(data['total_orders']),
        );

      case 1: // Monthly
        final r = await ApiClient.instance.get(
          '/reports/sales/annual?year=$_monthlyYear',
        );
        final data = r.data as Map<String, dynamic>;
        final rows = (data['monthly_breakdown'] as List).map((e) {
          final monthStr = e['month'] as String; // "YYYY-MM"
          final mIdx = (int.tryParse(monthStr.split('-').last) ?? 1) - 1;
          final label = _monthNames[mIdx.clamp(0, 11)];
          return _DataPoint(
            label: label,
            revenue: _parseRev(e['revenue']),
            orders: _parseInt(e['orders']),
          );
        }).toList();
        return (
          rows,
          _parseRev(data['total_revenue']),
          _parseInt(data['total_orders']),
        );

      case 2: // Yearly
        final r = await ApiClient.instance.get('/reports/sales/yearly');
        final data = r.data as Map<String, dynamic>;
        final rows = (data['yearly_breakdown'] as List).map((e) {
          return _DataPoint(
            label: '${e['year']}',
            revenue: _parseRev(e['revenue']),
            orders: _parseInt(e['orders']),
          );
        }).toList();
        return (
          rows,
          _parseRev(data['total_revenue']),
          _parseInt(data['total_orders']),
        );

      case 3: // Custom
        final r = await ApiClient.instance.get(
          '/reports/sales?start_date=${_fmtDate(_customStart)}&end_date=${_fmtDate(_customEnd)}',
        );
        final data = r.data as Map<String, dynamic>;
        final rows = (data['daily_breakdown'] as List).map((e) {
          final dateStr = e['date'] as String;
          final label = dateStr.length >= 7 ? dateStr.substring(5) : dateStr;
          return _DataPoint(
            label: label,
            revenue: _parseRev(e['revenue']),
            orders: _parseInt(e['orders']),
          );
        }).toList();
        return (
          rows,
          _parseRev(data['total_revenue']),
          _parseInt(data['total_orders']),
        );

      default:
        return (<_DataPoint>[], 0.0, 0);
    }
  }

  // Compare first half avg/order vs second half avg/order
  _Trend _computeTrend(List<_DataPoint> bd) {
    if (bd.length < 3) return _Trend.flat;
    final half = bd.length ~/ 2;
    double firstSum = 0, secondSum = 0;
    int fc = 0, sc = 0;
    for (int i = 0; i < bd.length; i++) {
      if (bd[i].orders > 0) {
        if (i < half) {
          firstSum += bd[i].revenue / bd[i].orders;
          fc++;
        } else {
          secondSum += bd[i].revenue / bd[i].orders;
          sc++;
        }
      }
    }
    if (fc == 0 || sc == 0) return _Trend.flat;
    final fa = firstSum / fc;
    final sa = secondSum / sc;
    if (sa > fa * 1.02) return _Trend.up;
    if (sa < fa * 0.98) return _Trend.down;
    return _Trend.flat;
  }

  Future<void> _pickCustomRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _customStart, end: _customEnd),
    );
    if (range != null && mounted) {
      setState(() {
        _customStart = range.start;
        _customEnd = range.end;
        _customApplied = true;
      });
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sales Report'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: Column(
        children: [
          _buildTabBar(),
          _buildPeriodControls(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(child: Text(_error!))
                : _buildContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Material(
      elevation: 0,
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        children: List.generate(_tabLabels.length, (i) {
          final selected = _tabIndex == i;
          return Expanded(
            child: InkWell(
              onTap: () {
                if (_tabIndex == i) return;
                setState(() {
                  _tabIndex = i;
                  _breakdown = null;
                });
                _load();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: selected ? _kBlue : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                ),
                child: Text(
                  _tabLabels[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    color: selected ? _kBlue : Colors.grey,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildPeriodControls() {
    if (_tabIndex == 0) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            for (final rec in [
              ('Today', 1),
              ('7 days', 7),
              ('30 days', 30),
              ('90 days', 90),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(rec.$1),
                  selected: _dailyDays == rec.$2,
                  onSelected: (_) {
                    if (_dailyDays == rec.$2) return;
                    setState(() {
                      _dailyDays = rec.$2;
                      _breakdown = null;
                    });
                    _load();
                  },
                ),
              ),
          ],
        ),
      );
    }

    if (_tabIndex == 1) {
      final thisYear = DateTime.now().year;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            for (int y = thisYear; y >= thisYear - 4; y--)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text('$y'),
                  selected: _monthlyYear == y,
                  onSelected: (_) {
                    if (_monthlyYear == y) return;
                    setState(() {
                      _monthlyYear = y;
                      _breakdown = null;
                    });
                    _load();
                  },
                ),
              ),
          ],
        ),
      );
    }

    if (_tabIndex == 2) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(
          'All years on record',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }

    // Custom
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Semantics(
        button: true,
        label: 'Select sales report date range',
        child: InkWell(
          onTap: _pickCustomRange,
          borderRadius: BorderRadius.circular(10),
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Date range',
              prefixIcon: Icon(Icons.date_range_outlined),
              suffixIcon: Icon(Icons.keyboard_arrow_down_rounded),
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 14,
              ),
            ),
            child: Text(
              _customApplied
                  ? '${_fmtDate(_customStart)}  →  ${_fmtDate(_customEnd)}'
                  : 'Select start and end dates',
              style: TextStyle(
                fontSize: 14,
                color: _customApplied ? null : Colors.grey.shade600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final bd = _breakdown;

    if (_tabIndex == 3 && !_customApplied) {
      return const Center(child: Text('Select a date range to view data'));
    }
    if (bd == null || bd.isEmpty) {
      return const Center(child: Text('No data for this period'));
    }

    final avg = _totalOrders > 0 ? _totalRevenue / _totalOrders : 0.0;
    final trend = _computeTrend(bd);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 3 Stat Cards ───────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Total Revenue',
                  value: formatRM(_totalRevenue),
                  icon: Icons.attach_money,
                  color: _kGreen,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatCard(
                  label: 'Total Orders',
                  value: '$_totalOrders',
                  icon: Icons.receipt_long,
                  color: _kBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _StatCard(
            label: 'Avg per Order',
            value: formatRM(avg),
            icon: Icons.bar_chart,
            color: _kPurple,
            trend: trend,
          ),
          const SizedBox(height: 14),
          // ── Bar Chart ──────────────────────────────────────────────────────
          Container(
            height: 210,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.07),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(6, 14, 14, 6),
            child: _buildChart(bd),
          ),
          const SizedBox(height: 14),
          // ── Detail List ────────────────────────────────────────────────────
          Card(
            child: Column(
              children: [
                ...bd.asMap().entries.map((entry) {
                  final i = entry.key;
                  final row = entry.value;
                  final rowAvg = row.orders > 0
                      ? row.revenue / row.orders
                      : null;
                  final prev = i > 0 ? bd[i - 1] : null;
                  String? vsPrev;
                  if (prev != null && prev.revenue > 0) {
                    final pct =
                        (row.revenue - prev.revenue) / prev.revenue * 100;
                    vsPrev = pct >= 0
                        ? '+${pct.toStringAsFixed(1)}%'
                        : '${pct.toStringAsFixed(1)}%';
                  }
                  return ListTile(
                    dense: true,
                    title: Text(row.label),
                    subtitle: vsPrev != null
                        ? Text(
                            vsPrev,
                            style: TextStyle(
                              fontSize: 11,
                              color: vsPrev.startsWith('+')
                                  ? _kGreen
                                  : Colors.red,
                            ),
                          )
                        : null,
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          formatRM(row.revenue),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          '${row.orders} orders${rowAvg != null ? ' · ${formatRM(rowAvg)} avg' : ''}',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      const Text(
                        'Total',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Text(
                        formatRM(_totalRevenue),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '$_totalOrders orders',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChart(List<_DataPoint> bd) {
    final maxRev = bd.map((e) => e.revenue).fold(0.0, max);
    if (maxRev == 0) {
      return const Center(
        child: Text('No data', style: TextStyle(color: Colors.grey)),
      );
    }

    // dynamic bar width based on count
    double barW = bd.length > 30
        ? 4
        : bd.length > 15
        ? 8
        : 14;
    // label interval so we show ~8 labels max
    final step = max(1, (bd.length / 8).ceil());

    return BarChart(
      BarChartData(
        maxY: maxRev * 1.22,
        barGroups: bd
            .asMap()
            .entries
            .map(
              (e) => BarChartGroupData(
                x: e.key,
                barRods: [
                  BarChartRodData(
                    toY: e.value.revenue,
                    width: barW,
                    color: _kGreen,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ],
              ),
            )
            .toList(),
        borderData: FlBorderData(show: false),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxRev / 4,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: Colors.grey.shade200, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: step.toDouble(),
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= bd.length || i % step != 0) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    bd[i].label,
                    style: const TextStyle(fontSize: 9, color: Colors.grey),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              interval: maxRev / 4,
              getTitlesWidget: (v, _) {
                final s = v >= 1000
                    ? '${(v / 1000).toStringAsFixed(1)}k'
                    : v.toStringAsFixed(0);
                return Text(
                  s,
                  style: const TextStyle(fontSize: 9, color: Colors.grey),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final row = bd[group.x];
              return BarTooltipItem(
                '${row.label}\n',
                const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
                children: [
                  TextSpan(
                    text: formatRM(rod.toY),
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                  TextSpan(
                    text: '\n${row.orders} orders',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 10,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ── Data model ─────────────────────────────────────────────────────────────────

class _DataPoint {
  final String label;
  final double revenue;
  final int orders;
  const _DataPoint({
    required this.label,
    required this.revenue,
    required this.orders,
  });
}

enum _Trend { up, down, flat }

// ── Stat card ──────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final _Trend? trend;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.trend,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          value,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: color,
                          ),
                        ),
                      ),
                      if (trend == _Trend.up)
                        const Icon(
                          Icons.trending_up_rounded,
                          color: Color(0xFF10B981),
                          size: 20,
                        ),
                      if (trend == _Trend.down)
                        const Icon(
                          Icons.trending_down_rounded,
                          color: Colors.red,
                          size: 20,
                        ),
                      if (trend == _Trend.flat)
                        Icon(
                          Icons.trending_flat_rounded,
                          color: Colors.orange.shade400,
                          size: 20,
                        ),
                    ],
                  ),
                  if (trend != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        trend == _Trend.up
                            ? 'Avg/order trending up'
                            : trend == _Trend.down
                            ? 'Avg/order trending down'
                            : 'Avg/order stable',
                        style: TextStyle(
                          fontSize: 10,
                          color: trend == _Trend.up
                              ? const Color(0xFF10B981)
                              : trend == _Trend.down
                              ? Colors.red
                              : Colors.orange.shade400,
                        ),
                      ),
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
