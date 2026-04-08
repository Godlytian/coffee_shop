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

  Future<List<int>> _fetchFinalizedOrderIdsInRange(DateTime date) async {
    try {
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
        r'''
        SELECT id
        FROM local_orders
        WHERE COALESCE(json_extract(payload_json, '$.status'), status) IN ('completed', 'paid')
          AND COALESCE(created_at, json_extract(payload_json, '$.created_at')) >= ?
          AND COALESCE(created_at, json_extract(payload_json, '$.created_at')) <= ?
        ''',
        [start, end],
      );
      return rows
          .map((row) => (row['id'] as num?)?.toInt())
          .whereType<int>()
          .toList(growable: false);
    } on DatabaseException {
      return const <int>[];
    }
  }

  Future<double> fetchDailySalesSummary(DateTime date) async {
    try {
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
        r'''
        SELECT SUM(COALESCE(json_extract(payload_json, '$.total_price'), 0)) as total
        FROM local_orders
        WHERE COALESCE(json_extract(payload_json, '$.status'), status) IN ('completed', 'paid')
          AND COALESCE(created_at, json_extract(payload_json, '$.created_at')) >= ?
          AND COALESCE(created_at, json_extract(payload_json, '$.created_at')) <= ?
        ''',
        [start, end],
      );
      return (rows.first['total'] as num?)?.toDouble() ?? 0;
    } on DatabaseException {
      return 0;
    }
  }

  Future<Map<String, double>> fetchPaymentMethodBreakdown(DateTime date) async {
    try {
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
        r'''
        SELECT COALESCE(json_extract(payload_json, '$.payment_method'), 'unknown') as method,
               SUM(COALESCE(json_extract(payload_json, '$.total_price'), 0)) as total
        FROM local_orders
        WHERE COALESCE(json_extract(payload_json, '$.status'), status) IN ('completed', 'paid')
          AND COALESCE(created_at, json_extract(payload_json, '$.created_at')) >= ?
          AND COALESCE(created_at, json_extract(payload_json, '$.created_at')) <= ?
        GROUP BY method
        ''',
        [start, end],
      );
      final total = rows.fold<double>(
        0,
        (sum, row) => sum + ((row['total'] as num?)?.toDouble() ?? 0),
      );
      if (total == 0) return {'cash': 0, 'qris': 0};
      final result = <String, double>{};
      for (final row in rows) {
        final method = row['method']?.toString() ?? 'unknown';
        final methodTotal = (row['total'] as num?)?.toDouble() ?? 0;
        result[method] = methodTotal / total;
      }
      return result;
    } on DatabaseException {
      return {'cash': 0, 'qris': 0};
    }
  }

  Future<List<Map<String, dynamic>>> fetchTopSellingItems({
    required DateTime date,
    int limit = 5,
  }) async {
    try {
      final finalizedOrderIds = await _fetchFinalizedOrderIdsInRange(date);
      if (finalizedOrderIds.isEmpty) {
        return const <Map<String, dynamic>>[];
      }

      final db = await _openItemsDb();
      final placeholders = List.filled(finalizedOrderIds.length, '?').join(',');
      final args = <Object>[...finalizedOrderIds, limit];
      final rows = await db.rawQuery('''
        SELECT
          COALESCE(json_extract(payload_json, '\$.products.name'),
                   json_extract(payload_json, '\$.name'),
                   'Product ' || COALESCE(json_extract(payload_json, '\$.product_id'), '?')) as product_name,
          json_extract(payload_json, '\$.product_id') as product_id,
          SUM(COALESCE(json_extract(payload_json, '\$.quantity'), 0)) as qty
        FROM local_order_items
        WHERE order_id IN ($placeholders)
        GROUP BY product_id, product_name
        ORDER BY qty DESC
        LIMIT ?
        ''', args);
      return rows
          .map(
            (row) => {
              'product_id': row['product_id'],
              'product_name': row['product_name'],
              'qty': row['qty'],
            },
          )
          .toList(growable: false);
    } on DatabaseException {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<Map<String, int>> fetchSyncStatusCounts() async {
    try {
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
    } on DatabaseException {
      return {'synced': 0, 'offline': 0};
    }
  }

  Future<Map<String, double>> fetchShiftSummary() async {
    try {
      final db = await _openOrdersDb();
      final rows = await db.rawQuery(r'''
        SELECT
          SUM(CASE
                WHEN json_extract(payload_json, '$.payment_method') = 'cash'
                THEN COALESCE(json_extract(payload_json, '$.total_price'), 0)
                ELSE 0
              END) as cash_total,
          SUM(COALESCE(json_extract(payload_json, '$.total_price'), 0)) as total
        FROM local_orders
        WHERE COALESCE(json_extract(payload_json, '$.status'), status) IN ('completed', 'paid')
        ''');
      final cash = (rows.first['cash_total'] as num?)?.toDouble() ?? 0;
      final total = (rows.first['total'] as num?)?.toDouble() ?? 0;
      return {
        'expected_cash_drawer': cash,
        'actual_cash_drawer': cash,
        'total': total,
      };
    } on DatabaseException {
      return {'expected_cash_drawer': 0, 'actual_cash_drawer': 0, 'total': 0};
    }
  }
}
