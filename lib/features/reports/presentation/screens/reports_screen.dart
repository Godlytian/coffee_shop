import 'package:coffee_shop/features/reports/data/reports_repository.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

enum ReportPeriod { day, week, month, year }

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final _repo = ReportsRepository.instance;

  ReportPeriod _period = ReportPeriod.week;
  DateTime _selectedDate = DateTime.now();
  int _selectedMonth = DateTime.now().month;
  int _selectedYear = DateTime.now().year;
  bool _showTopItemsBarChart = false;
  Future<Map<String, dynamic>>? _dataFuture;

  @override
  void initState() {
    super.initState();
    _dataFuture = _loadData();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  DateTime _weekStart(DateTime d) =>
      DateTime(d.year, d.month, d.day - (d.weekday - 1));

  String _weekdayShort(int wd) =>
      const ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'][wd - 1];

  String _monthShort(int m) => const [
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
  ][m - 1];

  String _monthFull(int m) => const [
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
  ][m - 1];

  String _formatCompact(double v) {
    if (v == 0) return '0';
    if (v >= 1000000) {
      return '${(v / 1000000).toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '')}M';
    }
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(0)}K';
    return v.toStringAsFixed(0);
  }

  double _barWidth(int count) {
    if (count <= 4) return 30;
    if (count <= 7) return 20;
    return 16;
  }

  double _shiftBarWidth(int count) {
    if (count <= 4) return 18;
    if (count <= 7) return 14;
    return 10;
  }

  // ── Selection label ─────────────────────────────────────────────────────────

  String _selectionLabel() {
    switch (_period) {
      case ReportPeriod.day:
        return 'Day: ${_selectedDate.day} ${_monthShort(_selectedDate.month)} ${_selectedDate.year}';
      case ReportPeriod.week:
        final ws = _weekStart(_selectedDate);
        final we = ws.add(const Duration(days: 6));
        return 'Week: ${ws.day} ${_monthShort(ws.month)} – ${we.day} ${_monthShort(we.month)} ${we.year}';
      case ReportPeriod.month:
        return 'Month: ${_monthFull(_selectedMonth)} $_selectedYear';
      case ReportPeriod.year:
        return 'Year: $_selectedYear';
    }
  }

  // ── Pickers ─────────────────────────────────────────────────────────────────

  Future<void> _openPicker() async {
    if (_period == ReportPeriod.day || _period == ReportPeriod.week) {
      final picked = await showDatePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime.now().add(const Duration(days: 365)),
        initialDate: _selectedDate,
      );
      if (picked != null) {
        setState(() {
          _selectedDate = picked;
          _dataFuture = _loadData();
        });
      }
    } else if (_period == ReportPeriod.month) {
      await _showMonthPicker();
    } else {
      await _showYearPicker();
    }
  }

  Future<void> _showMonthPicker() async {
    int tempYear = _selectedYear;
    const names = [
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
    final result = await showDialog<Map<String, int>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, sd) => AlertDialog(
          title: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => sd(() => tempYear--),
              ),
              Expanded(
                child: Text(
                  '$tempYear',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => sd(() => tempYear++),
              ),
            ],
          ),
          content: SizedBox(
            width: 280,
            child: GridView.builder(
              shrinkWrap: true,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 1.8,
              ),
              itemCount: 12,
              itemBuilder: (ctx, i) {
                final isSelected =
                    _selectedMonth == i + 1 && _selectedYear == tempYear;
                return InkWell(
                  onTap: () =>
                      Navigator.pop(ctx, {'year': tempYear, 'month': i + 1}),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    alignment: Alignment.center,
                    margin: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? Theme.of(ctx).primaryColor.withValues(alpha: 0.2)
                          : null,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      names[i],
                      style: TextStyle(
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    if (result != null) {
      setState(() {
        _selectedYear = result['year']!;
        _selectedMonth = result['month']!;
        _dataFuture = _loadData();
      });
    }
  }

  Future<void> _showYearPicker() async {
    final currentYear = DateTime.now().year;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select Year'),
        content: SizedBox(
          width: 200,
          height: 250,
          child: ListView.builder(
            itemCount: currentYear - 2019,
            itemBuilder: (ctx, i) {
              final year = currentYear - i;
              return ListTile(
                title: Text('$year', textAlign: TextAlign.center),
                selected: year == _selectedYear,
                selectedTileColor: Theme.of(
                  ctx,
                ).primaryColor.withValues(alpha: 0.12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                onTap: () => Navigator.pop(ctx, year),
              );
            },
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() {
        _selectedYear = picked;
        _dataFuture = _loadData();
      });
    }
  }

  // ── Data loading ─────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _loadData() {
    if (_period == ReportPeriod.day || _period == ReportPeriod.week) {
      return _loadWeeklyData();
    } else if (_period == ReportPeriod.month) {
      return _loadMonthlyData();
    } else {
      return _loadYearlyData();
    }
  }

  Future<Map<String, dynamic>> _loadWeeklyData() async {
    final ws = _weekStart(_selectedDate);
    final List<double> salesData = [];
    final List<Map<String, double>> shiftData = [];
    final List<String> xLabels = [];

    for (int i = 0; i < 7; i++) {
      final d = ws.add(Duration(days: i));
      salesData.add(await _repo.fetchDailySalesSummary(d));
      shiftData.add(await _repo.fetchShiftSummary(d));
      xLabels.add(_weekdayShort(d.weekday));
    }

    final Map<String, double> payment;
    final List<Map<String, dynamic>> topItems;

    if (_period == ReportPeriod.day) {
      payment = await _repo.fetchPaymentMethodBreakdown(_selectedDate);
      topItems = await _repo.fetchTopSellingItems(
        date: _selectedDate,
        limit: 5,
      );
    } else {
      final we = ws.add(const Duration(days: 6));
      payment = await _repo.fetchPaymentMethodBreakdownRange(ws, we);
      topItems = await _repo.fetchTopSellingItemsInRange(ws, we, limit: 5);
    }

    return {
      'sales_data': salesData,
      'shift_data': shiftData,
      'x_labels': xLabels,
      'payment_methods': payment,
      'top_items': topItems,
      'sales_title': 'Weekly Sales',
      'shift_title': 'Shift Sales (Weekly)',
    };
  }

  Future<Map<String, dynamic>> _loadMonthlyData() async {
    final lastDay = DateTime(_selectedYear, _selectedMonth + 1, 0).day;
    final buckets = [
      [1, 7],
      [8, 14],
      [15, 21],
      [22, lastDay],
    ];
    final List<double> salesData = [];
    final List<Map<String, double>> shiftData = [];

    for (final b in buckets) {
      final s = DateTime(_selectedYear, _selectedMonth, b[0]);
      final e = DateTime(_selectedYear, _selectedMonth, b[1]);
      salesData.add(await _repo.fetchSalesInRange(s, e));
      shiftData.add(await _repo.fetchShiftSummaryInRange(s, e));
    }

    final mStart = DateTime(_selectedYear, _selectedMonth, 1);
    final mEnd = DateTime(_selectedYear, _selectedMonth, lastDay);
    final payment = await _repo.fetchPaymentMethodBreakdownRange(mStart, mEnd);
    final topItems = await _repo.fetchTopSellingItemsInRange(
      mStart,
      mEnd,
      limit: 5,
    );

    return {
      'sales_data': salesData,
      'shift_data': shiftData,
      'x_labels': const ['Wk 1', 'Wk 2', 'Wk 3', 'Wk 4'],
      'payment_methods': payment,
      'top_items': topItems,
      'sales_title':
          'Sales by Week (${_monthShort(_selectedMonth)} $_selectedYear)',
      'shift_title': 'Shift Sales by Week',
    };
  }

  Future<Map<String, dynamic>> _loadYearlyData() async {
    final List<double> salesData = [];
    final List<Map<String, double>> shiftData = [];
    const xLabels = [
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

    for (int m = 1; m <= 12; m++) {
      final s = DateTime(_selectedYear, m, 1);
      final e = DateTime(_selectedYear, m + 1, 0);
      salesData.add(await _repo.fetchSalesInRange(s, e));
      shiftData.add(await _repo.fetchShiftSummaryInRange(s, e));
    }

    final yStart = DateTime(_selectedYear, 1, 1);
    final yEnd = DateTime(_selectedYear, 12, 31);
    final payment = await _repo.fetchPaymentMethodBreakdownRange(yStart, yEnd);
    final topItems = await _repo.fetchTopSellingItemsInRange(
      yStart,
      yEnd,
      limit: 5,
    );

    return {
      'sales_data': salesData,
      'shift_data': shiftData,
      'x_labels': xLabels,
      'payment_methods': payment,
      'top_items': topItems,
      'sales_title': 'Sales by Month ($_selectedYear)',
      'shift_title': 'Shift Sales by Month',
    };
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: SegmentedButton<ReportPeriod>(
              segments: const [
                ButtonSegment(value: ReportPeriod.day, label: Text('Day')),
                ButtonSegment(value: ReportPeriod.week, label: Text('Week')),
                ButtonSegment(value: ReportPeriod.month, label: Text('Month')),
                ButtonSegment(value: ReportPeriod.year, label: Text('Year')),
              ],
              selected: {_period},
              onSelectionChanged: (s) => setState(() {
                _period = s.first;
                _dataFuture = _loadData();
              }),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          // Date selector row
          InkWell(
            onTap: _openPicker,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.calendar_today, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    _selectionLabel(),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down, size: 20),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<Map<String, dynamic>>(
              future: _dataFuture,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final data = snapshot.data!;
                final isDesktop = MediaQuery.of(context).size.width > 900;
                final salesData = data['sales_data'] as List<double>;
                final shiftData =
                    data['shift_data'] as List<Map<String, double>>;
                final xLabels = data['x_labels'] as List<String>;

                return GridView.count(
                  crossAxisCount: isDesktop ? 2 : 1,
                  padding: const EdgeInsets.all(16),
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: isDesktop ? 1.5 : 1.2,
                  children: [
                    _buildSalesChart(
                      salesData,
                      xLabels,
                      data['sales_title'] as String,
                    ),
                    _buildShiftChart(
                      shiftData,
                      xLabels,
                      data['shift_title'] as String,
                    ),
                    _buildPaymentMethodsChart(
                      data['payment_methods'] as Map<String, double>,
                    ),
                    _buildTopItemsChart(
                      data['top_items'] as List<Map<String, dynamic>>,
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Chart builders ──────────────────────────────────────────────────────────

  Widget _buildSalesChart(
    List<double> salesData,
    List<String> xLabels,
    String title,
  ) {
    final bw = _barWidth(salesData.length);
    return _ChartCard(
      title: title,
      child: BarChart(
        BarChartData(
          barTouchData: BarTouchData(
            enabled: true,
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (g) => Colors.blueGrey.withValues(alpha: 0.9),
              tooltipPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              getTooltipItem: (group, gi, rod, ri) {
                final label = xLabels[group.x.toInt()];
                return BarTooltipItem(
                  '$label\n',
                  const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  children: [
                    TextSpan(
                      text: 'Rp ${_formatFull(rod.toY)}',
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          barGroups: salesData.asMap().entries.map((e) {
            return BarChartGroupData(
              x: e.key,
              barRods: [
                BarChartRodData(
                  toY: e.value,
                  color: Theme.of(context).primaryColor,
                  width: bw,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
              ],
            );
          }).toList(),
          titlesData: _titlesData(xLabels),
          borderData: FlBorderData(show: false),
          gridData: _gridData(),
        ),
      ),
    );
  }

  Widget _buildShiftChart(
    List<Map<String, double>> shiftData,
    List<String> xLabels,
    String title,
  ) {
    final bw = _shiftBarWidth(shiftData.length);
    return _ChartCard(
      title: title,
      action: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _LegendItem(color: Colors.blue, text: 'S1 (Morning)'),
          SizedBox(width: 8),
          _LegendItem(color: Colors.purple, text: 'S2 (Evening)'),
        ],
      ),
      child: BarChart(
        BarChartData(
          barTouchData: BarTouchData(
            enabled: true,
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (g) => Colors.blueGrey.withValues(alpha: 0.9),
              tooltipPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              getTooltipItem: (group, gi, rod, ri) {
                final label = xLabels[group.x.toInt()];
                final shift = ri == 0 ? 'Shift 1' : 'Shift 2';
                return BarTooltipItem(
                  '$shift ($label)\n',
                  const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  children: [
                    TextSpan(
                      text: 'Rp ${_formatFull(rod.toY)}',
                      style: const TextStyle(
                        color: Colors.yellow,
                        fontSize: 12,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          barGroups: shiftData.asMap().entries.map((e) {
            return BarChartGroupData(
              x: e.key,
              barsSpace: 3,
              barRods: [
                BarChartRodData(
                  toY: e.value['shift_1'] ?? 0,
                  color: Colors.blue,
                  width: bw,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
                BarChartRodData(
                  toY: e.value['shift_2'] ?? 0,
                  color: Colors.purple,
                  width: bw,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
              ],
            );
          }).toList(),
          titlesData: _titlesData(xLabels, bold: true),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (v) => FlLine(
              color: Colors.grey.withValues(alpha: 0.1),
              strokeWidth: 1,
            ),
          ),
          borderData: FlBorderData(show: false),
        ),
      ),
    );
  }

  FlTitlesData _titlesData(List<String> xLabels, {bool bold = false}) {
    return FlTitlesData(
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          getTitlesWidget: (value, meta) {
            final i = value.toInt();
            if (i < 0 || i >= xLabels.length) return const SizedBox();
            return Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(
                xLabels[i],
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            );
          },
        ),
      ),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 40,
          getTitlesWidget: (value, meta) {
            if (value == 0) return const SizedBox();
            return Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: Text(
                _formatCompact(value),
                style: const TextStyle(fontSize: 9, color: Colors.grey),
                textAlign: TextAlign.right,
              ),
            );
          },
        ),
      ),
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    );
  }

  FlGridData _gridData() => FlGridData(
    show: true,
    drawVerticalLine: false,
    getDrawingHorizontalLine: (v) =>
        FlLine(color: Colors.grey.withValues(alpha: 0.2), strokeWidth: 1),
  );

  Widget _buildPaymentMethodsChart(Map<String, double> methods) {
    final hasData = (methods['cash'] ?? 0) > 0 || (methods['qris'] ?? 0) > 0;
    return _ChartCard(
      title: 'Payment Methods',
      child: !hasData
          ? const Center(child: Text('No payment data available'))
          : PieChart(
              PieChartData(
                sections: [
                  PieChartSectionData(
                    value: methods['cash'] ?? 0,
                    title:
                        'Cash\n${((methods['cash'] ?? 0) * 100).toStringAsFixed(1)}%',
                    color: Colors.green,
                    radius: 60,
                    titleStyle: const TextStyle(
                      fontSize: 12,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  PieChartSectionData(
                    value: methods['qris'] ?? 0,
                    title:
                        'QRIS\n${((methods['qris'] ?? 0) * 100).toStringAsFixed(1)}%',
                    color: Colors.orange,
                    radius: 60,
                    titleStyle: const TextStyle(
                      fontSize: 12,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
                sectionsSpace: 2,
                centerSpaceRadius: 40,
              ),
            ),
    );
  }

  Widget _buildTopItemsChart(List<Map<String, dynamic>> topItems) {
    if (topItems.isEmpty) {
      return const _ChartCard(
        title: 'Top Selling Items',
        child: Center(child: Text('No items sold')),
      );
    }
    const colors = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.orange,
      Colors.purple,
    ];
    return _ChartCard(
      title: 'Top Selling Items',
      action: IconButton(
        icon: Icon(_showTopItemsBarChart ? Icons.pie_chart : Icons.bar_chart),
        onPressed: () =>
            setState(() => _showTopItemsBarChart = !_showTopItemsBarChart),
      ),
      child: _showTopItemsBarChart
          ? BarChart(
              BarChartData(
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
                      '${topItems[group.x.toInt()]['product_name']}\nQty: ${rod.toY.toInt()}',
                      const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                barGroups: topItems.asMap().entries.map((e) {
                  return BarChartGroupData(
                    x: e.key,
                    barRods: [
                      BarChartRodData(
                        toY: (e.value['qty'] as num).toDouble(),
                        color: colors[e.key % colors.length],
                        width: 20,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ],
                  );
                }).toList(),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, meta) {
                        final i = value.toInt();
                        if (i >= topItems.length) return const SizedBox();
                        return Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Text(
                            topItems[i]['product_name']
                                .toString()
                                .split(' ')
                                .first,
                            style: const TextStyle(fontSize: 10),
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      getTitlesWidget: (value, meta) {
                        if (value == 0 || value % 1 != 0) {
                          return const SizedBox();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: Text(
                            value.toInt().toString(),
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        );
                      },
                    ),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                borderData: FlBorderData(show: false),
                gridData: _gridData(),
              ),
            )
          : PieChart(
              PieChartData(
                sections: topItems.asMap().entries.map((e) {
                  return PieChartSectionData(
                    value: (e.value['qty'] as num).toDouble(),
                    title:
                        '${e.value['product_name'].toString().split(' ').first}\n(${e.value['qty']})',
                    color: colors[e.key % colors.length],
                    radius: 70,
                    titleStyle: const TextStyle(
                      fontSize: 11,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  );
                }).toList(),
                sectionsSpace: 2,
                centerSpaceRadius: 30,
              ),
            ),
    );
  }
}

// ── Utilities ──────────────────────────────────────────────────────────────────

String _formatFull(double value) {
  return value
      .toStringAsFixed(0)
      .replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
        (m) => '${m[1]}.',
      );
}

// ── Shared widgets ─────────────────────────────────────────────────────────────

class _LegendItem extends StatelessWidget {
  final Color color;
  final String text;

  const _LegendItem({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
  }
}

class _ChartCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? action;

  const _ChartCard({required this.title, required this.child, this.action});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (action != null) action!,
              ],
            ),
            const SizedBox(height: 16),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
