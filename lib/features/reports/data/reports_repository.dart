import 'package:coffee_shop/features/cashier/data/offline_shift_repository.dart';
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

  Future<Map<String, double>> fetchShiftSummary([DateTime? targetDate]) async {
    try {
      final db = await _openOrdersDb();

      // Default to today if no specific date is passed from the UI
      final queryDate = targetDate ?? DateTime.now();

      // 1. Pull aggregated totals per shift
      String query = r'''
      SELECT
        json_extract(payload_json, '$.shift_id') as shift_id,
        SUM(COALESCE(json_extract(payload_json, '$.total_price'), 0)) as shift_total,
        SUM(CASE
              WHEN json_extract(payload_json, '$.payment_method') = 'cash'
              THEN COALESCE(json_extract(payload_json, '$.total_price'), 0)
              ELSE 0
            END) as cash_total
      FROM local_orders
      WHERE COALESCE(json_extract(payload_json, '$.status'), status) IN ('completed', 'paid')
        AND json_extract(payload_json, '$.shift_id') IS NOT NULL
      GROUP BY json_extract(payload_json, '$.shift_id')
    ''';

      final rows = await db.rawQuery(query);

      // 2. Pull the cached shifts mapping
      final shiftRepo = OfflineShiftRepository();
      final cachedShifts = await shiftRepo.getCachedShifts();

      final shiftTimeMap = <String, String>{};
      for (final shift in cachedShifts) {
        final sIdStr = shift['shift_id']?.toString() ?? shift['id']?.toString();
        final startedAt = shift['started_at']?.toString();
        if (sIdStr != null && startedAt != null) {
          shiftTimeMap[sIdStr] = startedAt;
        }
      }

      var total = 0.0;
      var cash = 0.0;
      var shift1Total = 0.0;
      var shift2Total = 0.0;

      for (final row in rows) {
        final shiftIdStr = row['shift_id']?.toString();
        if (shiftIdStr == null) continue;

        final startedAtStr = shiftTimeMap[shiftIdStr];
        if (startedAtStr == null)
          continue; // Skip if we can't find the shift time

        final utcTime = DateTime.tryParse(startedAtStr)?.toUtc();
        if (utcTime == null) continue;

        // 3. Convert to WITA (UTC+8)
        final witaTime = utcTime.add(const Duration(hours: 8));

        // ==========================================
        // THE FIX: strictly filter by the requested day!
        // ==========================================
        if (witaTime.year != queryDate.year ||
            witaTime.month != queryDate.month ||
            witaTime.day != queryDate.day) {
          // If the shift didn't happen on the targetDate, skip it entirely.
          continue;
        }

        // If we pass the date check, add up the totals
        final shiftTotal = (row['shift_total'] as num?)?.toDouble() ?? 0;
        final shiftCash = (row['cash_total'] as num?)?.toDouble() ?? 0;

        total += shiftTotal;
        cash += shiftCash;

        // 4. Categorize by hour block
        int shiftNumber = 2; // Default to shift 2
        if (witaTime.hour >= 6 && witaTime.hour <= 12) {
          shiftNumber = 1;
        }

        if (shiftNumber == 1) {
          shift1Total += shiftTotal;
        } else {
          shift2Total += shiftTotal;
        }
      }

      return {
        'expected_cash_drawer': cash,
        'actual_cash_drawer': cash,
        'total': total,
        'shift_1': shift1Total,
        'shift_2': shift2Total,
      };
    } catch (e) {
      print('=== FetchShiftSummary Error ===');
      print(e.toString());

      return {
        'expected_cash_drawer': 0,
        'actual_cash_drawer': 0,
        'total': 0,
        'shift_1': 0,
        'shift_2': 0,
      };
    }
  }
}
