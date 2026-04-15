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

      // SQL remains identical: highly optimized and clean.
      final rows = await db.rawQuery(r'''
        SELECT
          json_extract(payload_json, '$.shift_id') as shift_id,
          MIN(COALESCE(created_at, json_extract(payload_json, '$.created_at'))) as start_time,
          SUM(COALESCE(json_extract(payload_json, '$.total_price'), 0)) as shift_total,
          SUM(CASE
                WHEN json_extract(payload_json, '$.payment_method') = 'cash'
                THEN COALESCE(json_extract(payload_json, '$.total_price'), 0)
                ELSE 0
              END) as cash_total
        FROM local_orders
        WHERE COALESCE(json_extract(payload_json, '$.status'), status) IN ('completed', 'paid')
          AND json_extract(payload_json, '$.shift_id') IS NOT NULL
        GROUP BY shift_id
      ''');

      var total = 0.0;
      var cash = 0.0;

      // 1. Collect valid shifts into a list for safe chronological sorting
      List<Map<String, dynamic>> dailyShifts = [];

      for (final row in rows) {
        final shiftIdStr = row['shift_id']?.toString();
        if (shiftIdStr == null) continue;
        final shiftId = int.tryParse(shiftIdStr) ?? 0;

        final startRaw = row['start_time']?.toString();
        final localStart = _parseOrderDateToLocal(startRaw);

        // Discard invalid dates or dates outside our target day
        if (localStart == null) continue;
        if (targetDate != null && !_isSameCalendarDay(localStart, targetDate)) {
          continue;
        }

        final shiftTotal = (row['shift_total'] as num?)?.toDouble() ?? 0;
        final shiftCash = (row['cash_total'] as num?)?.toDouble() ?? 0;

        total += shiftTotal;
        cash += shiftCash;

        dailyShifts.add({
          'shift_id': shiftId,
          'start_time': localStart,
          'shift_total': shiftTotal,
        });
      }

      // 2. Sort strictly chronologically (earliest first)
      // If two shifts happen to start at the exact same millisecond, fallback to shift_id
      dailyShifts.sort((a, b) {
        final timeA = a['start_time'] as DateTime;
        final timeB = b['start_time'] as DateTime;
        int timeCompare = timeA.compareTo(timeB);
        if (timeCompare != 0) return timeCompare;
        return (a['shift_id'] as int).compareTo(b['shift_id'] as int);
      });

      var shift1Total = 0.0;
      var shift2Total = 0.0;

      // 3. Dynamically assign Shift 1 and Shift 2 based on order of appearance
      for (int i = 0; i < dailyShifts.length; i++) {
        final shift = dailyShifts[i];
        final startTime = shift['start_time'] as DateTime;
        final shiftTotal = shift['shift_total'] as double;

        if (i == 0) {
          // Earliest shift of the day.
          // Sunday exception: If it starts afternoon (>= 12:00), push to Shift 2.
          if (startTime.weekday == DateTime.sunday && startTime.hour >= 12) {
            shift2Total += shiftTotal;
          } else {
            shift1Total += shiftTotal;
          }
        } else {
          // Any subsequent shift opened on the same day goes to Shift 2
          shift2Total += shiftTotal;
        }
      }

      return {
        'expected_cash_drawer': cash,
        'actual_cash_drawer': cash, // Kept matching expected per your setup
        'total': total,
        'shift_1': shift1Total,
        'shift_2': shift2Total,
      };
    } on DatabaseException {
      return {
        'expected_cash_drawer': 0,
        'actual_cash_drawer': 0,
        'total': 0,
        'shift_1': 0,
        'shift_2': 0,
      };
    }
  }

  DateTime? _parseOrderDateToLocal(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final normalized = raw.replaceFirst(' ', 'T');

    // Add safety net: if missing timezone marker, force UTC so .toLocal() doesn't double-shift
    String safeString = normalized;
    if (safeString.endsWith('+00')) {
      safeString = safeString.substring(0, safeString.length - 3) + 'Z';
    } else if (!safeString.contains('Z') &&
        !safeString.contains('+') &&
        !safeString.contains('-')) {
      safeString += 'Z';
    }

    final parsed = DateTime.tryParse(safeString);
    return parsed?.toLocal();
  }

  bool _isSameCalendarDay(DateTime a, DateTime b) {
    final lhs = a.toLocal();
    final rhs = b.toLocal();
    return lhs.year == rhs.year && lhs.month == rhs.month && lhs.day == rhs.day;
  }
}
