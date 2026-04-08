import 'package:coffee_shop/features/reports/data/reports_repository.dart';
import 'package:flutter/material.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final _repo = ReportsRepository.instance;
  DateTime _selectedDate = DateTime.now();

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
          return GridView.count(
            crossAxisCount: MediaQuery.of(context).size.width > 900 ? 3 : 1,
            padding: const EdgeInsets.all(16),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            children: [
              _card(
                'Daily Sales',
                'Rp ${(data['daily_sales'] as double).toStringAsFixed(0)}',
              ),
              _card(
                'Payment Methods',
                (data['payment_methods'] as Map).entries
                    .map(
                      (entry) =>
                          '${entry.key}: ${((entry.value as double) * 100).toStringAsFixed(1)}%',
                    )
                    .join('\n'),
              ),
              _card(
                'Top Selling Items',
                (data['top_items'] as List)
                    .map((row) => 'Product ${row['product_id']}: ${row['qty']}')
                    .join('\n'),
              ),
              _card(
                'Shift Summary',
                'Expected Cash: Rp ${((data['shift_summary'] as Map)['expected_cash_drawer'] as double).toStringAsFixed(0)}\nActual Cash: Rp ${((data['shift_summary'] as Map)['actual_cash_drawer'] as double).toStringAsFixed(0)}',
              ),
              _card(
                'Sync Status',
                'Offline: ${(data['sync_counts'] as Map)['offline']}\nSynced: ${(data['sync_counts'] as Map)['synced']}',
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _card(String title, String body) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Expanded(child: SingleChildScrollView(child: Text(body))),
          ],
        ),
      ),
    );
  }

  Future<Map<String, dynamic>> _loadData() async {
    final daily = await _repo.fetchDailySalesSummary(_selectedDate);
    final methods = await _repo.fetchPaymentMethodBreakdown(_selectedDate);
    final topItems = await _repo.fetchTopSellingItems(limit: 5);
    final shiftSummary = await _repo.fetchShiftSummary();
    final syncCounts = await _repo.fetchSyncStatusCounts();

    return {
      'daily_sales': daily,
      'payment_methods': methods,
      'top_items': topItems,
      'shift_summary': shiftSummary,
      'sync_counts': syncCounts,
    };
  }
}
