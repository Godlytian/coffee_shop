import 'package:coffee_shop/features/reports/data/reports_repository.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final _repo = ReportsRepository.instance;
  DateTime _selectedDate = DateTime.now();
  bool _showTopItemsBarChart = false;

  // Formatter for pretty numbers (e.g., 1,500,000 -> 1.5M, 150,000 -> 150K)
  String _formatCompact(double value) {
    if (value == 0) return '0';
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '')}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(0)}K';
    }
    return value.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports Dashboard'),
        actions: [
          IconButton(
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                firstDate: DateTime(2020),
                lastDate: DateTime.now().add(const Duration(days: 365)),
                initialDate: _selectedDate,
              );
              if (picked != null) {
                setState(() => _selectedDate = picked);
              }
            },
            icon: const Icon(Icons.calendar_month),
          ),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _loadData(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!;
          final isDesktop = MediaQuery.of(context).size.width > 900;

          return GridView.count(
            crossAxisCount: isDesktop ? 2 : 1,
            padding: const EdgeInsets.all(16),
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: isDesktop ? 1.5 : 1.2,
            children: [
              _buildWeeklySalesChart(data['weekly_sales']),
              _buildWeeklyShiftSummaryChart(data['weekly_shifts']),
              _buildPaymentMethodsChart(data['payment_methods']),
              _buildTopItemsChart(data['top_items']),
            ],
          );
        },
      ),
    );
  }

  Widget _buildWeeklySalesChart(List<double> weeklySales) {
    return _ChartCard(
      title: 'Daily Sales (Last 7 Days)',
      child: BarChart(
        BarChartData(
          barTouchData: BarTouchData(
            enabled: true,
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (group) => Colors.blueGrey.withOpacity(0.9),
              tooltipPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final date = _selectedDate.subtract(
                  Duration(days: 6 - group.x.toInt()),
                );
                final dateStr = _formatDateShort(date);

                return BarTooltipItem(
                  'Total Sales ($dateStr)\n',
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
          barGroups: weeklySales.asMap().entries.map((e) {
            return BarChartGroupData(
              x: e.key,
              barRods: [
                BarChartRodData(
                  toY: e.value,
                  color: Theme.of(context).primaryColor,
                  width: 20,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
              ],
            );
          }).toList(),
          titlesData: FlTitlesData(
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= weeklySales.length)
                    return const SizedBox();

                  final d = _selectedDate.subtract(
                    Duration(days: (weeklySales.length - 1) - index),
                  );
                  final weekdays = [
                    'Sen',
                    'Sel',
                    'Rab',
                    'Kam',
                    'Jum',
                    'Sab',
                    'Min',
                  ];

                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      weekdays[d.weekday - 1],
                      style: const TextStyle(fontSize: 10),
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
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
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
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (value) =>
                FlLine(color: Colors.grey.withOpacity(0.2), strokeWidth: 1),
          ),
        ),
      ),
    );
  }

  Widget _buildWeeklyShiftSummaryChart(List<Map<String, double>> weeklyShifts) {
    return _ChartCard(
      title: 'Shift 1 vs Shift 2 Sales (Weekly)',
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
              getTooltipColor: (group) => Colors.blueGrey.withOpacity(0.9),
              tooltipPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              tooltipMargin: 8,
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final date = _selectedDate.subtract(
                  Duration(days: 6 - group.x.toInt()),
                );
                final dateStr = _formatDateShort(date);

                final shiftName = rodIndex == 0 ? 'Shift 1' : 'Shift 2';

                return BarTooltipItem(
                  '$shiftName ($dateStr)\n',
                  const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  children: [
                    TextSpan(
                      text: 'Rp ${_formatFull(rod.toY)}',
                      style: const TextStyle(
                        color: Colors.yellow,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          barGroups: weeklyShifts.asMap().entries.map((e) {
            return BarChartGroupData(
              x: e.key,
              barsSpace: 4,
              barRods: [
                BarChartRodData(
                  toY: e.value['shift_1'] ?? 0,
                  color: Colors.blue,
                  width: 14,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
                BarChartRodData(
                  toY: e.value['shift_2'] ?? 0,
                  color: Colors.purple,
                  width: 14,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
              ],
            );
          }).toList(),
          titlesData: FlTitlesData(
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= 7) return const SizedBox();
                  final d = _selectedDate.subtract(Duration(days: 6 - index));
                  final weekdays = [
                    'Sen',
                    'Sel',
                    'Rab',
                    'Kam',
                    'Jum',
                    'Sab',
                    'Min',
                  ];
                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      weekdays[d.weekday - 1],
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
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
                  return Text(
                    _formatCompact(value),
                    style: const TextStyle(fontSize: 9, color: Colors.grey),
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
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (value) =>
                FlLine(color: Colors.grey.withOpacity(0.1), strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
        ),
      ),
    );
  }

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

    final colors = [
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
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      return BarTooltipItem(
                        '${topItems[group.x.toInt()]['product_name']}\nQty: ${rod.toY.toInt()}',
                        const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      );
                    },
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
                        if (value.toInt() >= topItems.length)
                          return const SizedBox();
                        return Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Text(
                            topItems[value.toInt()]['product_name']
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
                        if (value == 0 || value % 1 != 0)
                          return const SizedBox();
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
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: Colors.grey.withOpacity(0.2),
                    strokeWidth: 1,
                  ),
                ),
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

  Future<Map<String, dynamic>> _loadData() async {
    List<double> weeklySales = [];
    List<Map<String, double>> weeklyShifts = [];

    for (int i = 6; i >= 0; i--) {
      final d = _selectedDate.subtract(Duration(days: i));
      weeklySales.add(await _repo.fetchDailySalesSummary(d));
      weeklyShifts.add(await _repo.fetchShiftSummary(d));
    }

    Map<String, double> methods = {'cash': 0, 'qris': 0};
    List<Map<String, dynamic>> topItems = <Map<String, dynamic>>[];

    try {
      methods = await _repo.fetchPaymentMethodBreakdown(_selectedDate);
    } catch (_) {}
    try {
      topItems = await _repo.fetchTopSellingItems(
        date: _selectedDate,
        limit: 5,
      );
    } catch (_) {}

    return {
      'weekly_sales': weeklySales,
      'payment_methods': methods,
      'top_items': topItems,
      'weekly_shifts': weeklyShifts,
    };
  }
}

String _formatFull(double value) {
  // Formats 1900000.0 into 1.900.000
  return value
      .toStringAsFixed(0)
      .replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
        (Match m) => '${m[1]}.',
      );
}

String _formatDateShort(DateTime date) {
  const months = [
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
  return '${date.day} ${months[date.month - 1]}';
}

// Helper Widget for custom chart legends
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
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
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
