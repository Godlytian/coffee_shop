import 'package:coffee_shop/features/cashier/data/offline_shift_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class ReportsRepository {
  ReportsRepository._();
  static final ReportsRepository instance = ReportsRepository._();

  Future<Database> _openOrdersDb() async {
    final dbPath = await getDatabasesPath();
    return openDatabase(
      p.join(dbPath, 'local_orders.db'),
      onOpen: (db) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS local_orders (
            id INTEGER PRIMARY KEY,
            status TEXT,
            sync_status TEXT NOT NULL DEFAULT 'synced',
            order_source TEXT,
            created_at TEXT,
            payload_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      },
    );
  }

  Future<Database> _openItemsDb() async {
    final dbPath = await getDatabasesPath();
    return openDatabase(
      p.join(dbPath, 'local_order_items.db'),
      onOpen: (db) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS local_order_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            order_id INTEGER NOT NULL,
            sync_status TEXT NOT NULL DEFAULT 'synced',
            payload_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      },
    );
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

  Future<List<int>> _fetchFinalizedOrderIdsInDateRange(
    DateTime start,
    DateTime end,
  ) async {
    try {
      final db = await _openOrdersDb();
      final startStr =
          DateTime(start.year, start.month, start.day).toIso8601String();
      final endStr =
          DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
      final rows = await db.rawQuery(
        r'''
        SELECT id FROM local_orders
        WHERE COALESCE(json_extract(payload_json, '$.status'), status) IN ('completed', 'paid')
          AND COALESCE(created_at, json_extract(payload_json, '$.created_at')) >= ?
          AND COALESCE(created_at, json_extract(payload_json, '$.created_at')) <= ?
        ''',
        [startStr, endStr],
      );
      return rows
          .map((r) => (r['id'] as num?)?.toInt())
          .whereType<int>()
          .toList(growable: false);
    } on DatabaseException {
      return const <int>[];
    }
  }

  Future<double> fetchSalesInRange(DateTime start, DateTime end) async {
    try {
      final db = await _openOrdersDb();
      final startStr =
          DateTime(start.year, start.month, start.day).toIso8601String();
      final endStr =
          DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
      final rows = await db.rawQuery(
        r'''
        SELECT SUM(COALESCE(json_extract(payload_json, '$.total_price'), 0)) as total
        FROM local_orders
        WHERE COALESCE(json_extract(payload_json, '$.status'), status) IN ('completed', 'paid')
          AND COALESCE(created_at, json_extract(payload_json, '$.created_at')) >= ?
          AND COALESCE(created_at, json_extract(payload_json, '$.created_at')) <= ?
        ''',
        [startStr, endStr],
      );
      return (rows.first['total'] as num?)?.toDouble() ?? 0;
    } on DatabaseException {
      return 0;
    }
  }

  Future<Map<String, double>> fetchPaymentMethodBreakdownRange(
    DateTime start,
    DateTime end,
  ) async {
    try {
      final db = await _openOrdersDb();
      final startStr =
          DateTime(start.year, start.month, start.day).toIso8601String();
      final endStr =
          DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
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
        [startStr, endStr],
      );
      final totalAmt = rows.fold<double>(
        0,
        (sum, r) => sum + ((r['total'] as num?)?.toDouble() ?? 0),
      );
      if (totalAmt == 0) return {'cash': 0, 'qris': 0};
      final result = <String, double>{};
      for (final r in rows) {
        final method = r['method']?.toString() ?? 'unknown';
        result[method] = ((r['total'] as num?)?.toDouble() ?? 0) / totalAmt;
      }
      return result;
    } on DatabaseException {
      return {'cash': 0, 'qris': 0};
    }
  }

  Future<List<Map<String, dynamic>>> fetchTopSellingItemsInRange(
    DateTime start,
    DateTime end, {
    int limit = 5,
  }) async {
    try {
      final orderIds = await _fetchFinalizedOrderIdsInDateRange(start, end);
      if (orderIds.isEmpty) return const <Map<String, dynamic>>[];
      final db = await _openItemsDb();
      final placeholders = List.filled(orderIds.length, '?').join(',');
      final args = <Object>[...orderIds, limit];
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
            (r) => {
              'product_id': r['product_id'],
              'product_name': r['product_name'],
              'qty': r['qty'],
            },
          )
          .toList(growable: false);
    } on DatabaseException {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<Map<String, double>> fetchShiftSummaryInRange(
    DateTime start,
    DateTime end,
  ) async {
    try {
      final db = await _openOrdersDb();
      final startStr =
          DateTime(start.year, start.month, start.day).toIso8601String();
      final endStr =
          DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();

      final rows = await db.rawQuery(
        r'''
        SELECT
          json_extract(payload_json, '$.shift_id') as shift_id,
          MIN(COALESCE(created_at, json_extract(payload_json, '$.created_at'))) as fallback_time,
          SUM(COALESCE(json_extract(payload_json, '$.total_price'), 0)) as shift_total
        FROM local_orders
        WHERE COALESCE(json_extract(payload_json, '$.status'), status) IN ('completed', 'paid')
          AND json_extract(payload_json, '$.shift_id') IS NOT NULL
          AND COALESCE(created_at, json_extract(payload_json, '$.created_at')) >= ?
          AND COALESCE(created_at, json_extract(payload_json, '$.created_at')) <= ?
        GROUP BY json_extract(payload_json, '$.shift_id')
        ''',
        [startStr, endStr],
      );

      final shiftRepo = OfflineShiftRepository();
      final cachedShifts = await shiftRepo.getCachedShifts();
      final shiftTimeMap = <String, String>{};
      for (final shift in cachedShifts) {
        final sId =
            shift['shift_id']?.toString() ?? shift['id']?.toString();
        final startedAt = shift['started_at']?.toString();
        if (sId != null && startedAt != null) shiftTimeMap[sId] = startedAt;
      }

      double shift1Total = 0;
      double shift2Total = 0;

      for (final row in rows) {
        final shiftIdStr = row['shift_id']?.toString();
        if (shiftIdStr == null) continue;
        final startedAtStr =
            shiftTimeMap[shiftIdStr] ?? row['fallback_time']?.toString();
        if (startedAtStr == null) continue;
        final parsed = DateTime.tryParse(startedAtStr);
        if (parsed == null) continue;
        final wita = (parsed.isUtc ? parsed : parsed.toUtc())
            .add(const Duration(hours: 8));
        final shiftTotal = (row['shift_total'] as num?)?.toDouble() ?? 0;
        if (wita.hour >= 6 && wita.hour <= 12) {
          shift1Total += shiftTotal;
        } else {
          shift2Total += shiftTotal;
        }
      }

      return {'shift_1': shift1Total, 'shift_2': shift2Total};
    } catch (_) {
      return {'shift_1': 0, 'shift_2': 0};
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

      final queryDate = targetDate ?? DateTime.now();

      String query = r'''
      SELECT
        json_extract(payload_json, '$.shift_id') as shift_id,
        MIN(COALESCE(created_at, json_extract(payload_json, '$.created_at'))) as fallback_time,
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

        String? startedAtStr = shiftTimeMap[shiftIdStr];
        if (startedAtStr == null || startedAtStr.isEmpty) {
          startedAtStr = row['fallback_time']?.toString();
        }

        if (startedAtStr == null) continue;

        final parsedTime = DateTime.tryParse(startedAtStr);
        if (parsedTime == null) continue;

        final utcTime = parsedTime.isUtc ? parsedTime : parsedTime.toUtc();

        final witaTime = utcTime.add(const Duration(hours: 8));

        if (witaTime.year != queryDate.year ||
            witaTime.month != queryDate.month ||
            witaTime.day != queryDate.day) {
          continue;
        }

        final shiftTotal = (row['shift_total'] as num?)?.toDouble() ?? 0;
        final shiftCash = (row['cash_total'] as num?)?.toDouble() ?? 0;

        total += shiftTotal;
        cash += shiftCash;

        int shiftNumber = 2;
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
