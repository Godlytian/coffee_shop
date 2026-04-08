import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class ReportsRepository {
  ReportsRepository._();
  static final ReportsRepository instance = ReportsRepository._();

  Future<Database> _openOrdersDb() async {
    final dbPath = await getDatabasesPath();
    return openDatabase(p.join(dbPath, 'local_orders.db'));
  }

  Future<Database> _openItemsDb() async {
    final dbPath = await getDatabasesPath();
    return openDatabase(p.join(dbPath, 'local_order_items.db'));
  }

  Future<double> fetchDailySalesSummary(DateTime date) async {
    final db = await _openOrdersDb();
    final start = DateTime(date.year, date.month, date.day).toIso8601String();
    final end = DateTime(
      date.year,
      date.month,
      date.day,
      23,
      59,
      59,
    ).toIso8601String();
    final rows = await db.rawQuery(
      r'SELECT SUM(COALESCE(json_extract(payload_json, "$.total_price"), 0)) as total FROM local_orders WHERE json_extract(payload_json, "$.status") = ? AND created_at >= ? AND created_at <= ?',
      ['paid', start, end],
    );
    return (rows.first['total'] as num?)?.toDouble() ?? 0;
  }

  Future<Map<String, double>> fetchPaymentMethodBreakdown(DateTime date) async {
    final db = await _openOrdersDb();
    final start = DateTime(date.year, date.month, date.day).toIso8601String();
    final end = DateTime(
      date.year,
      date.month,
      date.day,
      23,
      59,
      59,
    ).toIso8601String();
    final rows = await db.rawQuery(
      r'SELECT COALESCE(json_extract(payload_json, "$.payment_method"), "unknown") as method, COUNT(*) as count FROM local_orders WHERE json_extract(payload_json, "$.status") = ? AND created_at >= ? AND created_at <= ? GROUP BY method',
      ['paid', start, end],
    );
    final total = rows.fold<double>(
      0,
      (sum, row) => sum + ((row['count'] as num?)?.toDouble() ?? 0),
    );
    if (total == 0) return {'cash': 0, 'qris': 0};
    final result = <String, double>{};
    for (final row in rows) {
      final method = row['method']?.toString() ?? 'unknown';
      final count = (row['count'] as num?)?.toDouble() ?? 0;
      result[method] = count / total;
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> fetchTopSellingItems({
    int limit = 5,
  }) async {
    final db = await _openItemsDb();
    final rows = await db.rawQuery(
      r'SELECT json_extract(payload_json, "$.product_id") as product_id, SUM(COALESCE(json_extract(payload_json, "$.quantity"), 0)) as qty FROM local_order_items GROUP BY product_id ORDER BY qty DESC LIMIT ?',
      [limit],
    );
    return rows
        .map((row) => {'product_id': row['product_id'], 'qty': row['qty']})
        .toList(growable: false);
  }

  Future<Map<String, int>> fetchSyncStatusCounts() async {
    final db = await _openOrdersDb();
    final rows = await db.rawQuery(
      'SELECT sync_status, COUNT(*) as c FROM local_orders GROUP BY sync_status',
    );
    var synced = 0;
    var offline = 0;
    for (final row in rows) {
      final status = row['sync_status']?.toString() ?? '';
      final count = (row['c'] as num?)?.toInt() ?? 0;
      if (status == 'synced') {
        synced += count;
      } else {
        offline += count;
      }
    }
    return {'synced': synced, 'offline': offline};
  }

  Future<Map<String, double>> fetchShiftSummary() async {
    final db = await _openOrdersDb();
    final rows = await db.rawQuery(
      r'SELECT SUM(CASE WHEN json_extract(payload_json, "$.payment_method") = "cash" THEN COALESCE(json_extract(payload_json, "$.total_price"), 0) ELSE 0 END) as cash_total, SUM(COALESCE(json_extract(payload_json, "$.total_price"), 0)) as total FROM local_orders WHERE json_extract(payload_json, "$.status") = "paid"',
    );
    final cash = (rows.first['cash_total'] as num?)?.toDouble() ?? 0;
    final total = (rows.first['total'] as num?)?.toDouble() ?? 0;
    return {
      'expected_cash_drawer': cash,
      'actual_cash_drawer': cash,
      'total': total,
    };
  }
}
