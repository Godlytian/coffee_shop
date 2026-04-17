import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OfflineShiftRepository {
  static const String _dbName = 'offline_shifts.db';
  static const int _dbVersion = 2;
  static const String _cashierTable = 'cached_cashiers';
  static const String _pendingShiftTable = 'offline_pending_shifts';
  static const String _cachedShiftTable = 'cached_shifts';

  Database? _db;

  Future<void> init() async {
    if (_db != null) return;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _dbName);
    _db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE $_cashierTable (
            cashier_id INTEGER PRIMARY KEY,
            name TEXT,
            pin_code TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            synced_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE $_pendingShiftTable (
            local_shift_id TEXT PRIMARY KEY,
            cashier_id INTEGER NOT NULL,
            branch_id TEXT NOT NULL,
            started_at TEXT NOT NULL,
            payload_json TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE $_cachedShiftTable (
            shift_id INTEGER PRIMARY KEY,
            status TEXT,
            branch_id TEXT,
            started_at TEXT,
            ended_at TEXT,
            current_cashier_id INTEGER,
            opened_by INTEGER,
            closed_by INTEGER,
            payload_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS $_cachedShiftTable (
              shift_id INTEGER PRIMARY KEY,
              status TEXT,
              branch_id TEXT,
              started_at TEXT,
              ended_at TEXT,
              current_cashier_id INTEGER,
              opened_by INTEGER,
              closed_by INTEGER,
              payload_json TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        }
      },
    );
  }

  Database get _database {
    final db = _db;
    if (db == null) throw StateError('OfflineShiftRepository not initialized');
    return db;
  }

  Future<void> cacheCashiers(List<Map<String, dynamic>> cashiers) async {
    await init();
    await _database.transaction((txn) async {
      for (final row in cashiers) {
        final cashierId = (row['id'] as num?)?.toInt();
        if (cashierId == null) continue;
        await txn.insert(_cashierTable, {
          'cashier_id': cashierId,
          'name': row['name']?.toString(),
          'pin_code': row['code']?.toString() ?? '',
          'payload_json': jsonEncode(row),
          'synced_at': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<Map<String, dynamic>>> getCachedCashiers() async {
    await init();
    final rows = await _database.query(_cashierTable, orderBy: 'name ASC');
    return rows
        .map(
          (row) => Map<String, dynamic>.from(
            jsonDecode(row['payload_json'] as String) as Map,
          ),
        )
        .toList(growable: false);
  }

  Future<bool> validateCashierPin({
    required int cashierId,
    required String pin,
  }) async {
    await init();
    final rows = await _database.query(
      _cashierTable,
      columns: ['pin_code'],
      where: 'cashier_id = ?',
      whereArgs: [cashierId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final expected = (rows.first['pin_code'] ?? '').toString();
    return expected == pin;
  }

  Future<String> enqueueOfflineShift({
    required int cashierId,
    required String branchId,
  }) async {
    await init();
    final localShiftId = DateTime.now().millisecondsSinceEpoch.toString();
    final payload = {
      'local_shift_id': localShiftId,
      'cashier_id': cashierId,
      'branch_id': branchId,
      'started_at': DateTime.now().toIso8601String(),
      'status': 'open',
    };

    await _database.insert(_pendingShiftTable, {
      'local_shift_id': localShiftId,
      'cashier_id': cashierId,
      'branch_id': branchId,
      'started_at': payload['started_at'],
      'payload_json': jsonEncode(payload),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    return localShiftId;
  }

  Future<void> downloadRecentShifts(SupabaseClient supabase) async {
    try {
      final sevenDaysAgo = DateTime.now().subtract(const Duration(days: 7));

      final response = await supabase
          .from('shifts')
          .select()
          // .eq('branch_id', yourBranchId) // Uncomment if you have multiple branches!
          .gte('started_at', sevenDaysAgo.toIso8601String())
          .order('started_at', ascending: false);

      final List<Map<String, dynamic>> fetchedShifts =
          List<Map<String, dynamic>>.from(response);

      if (fetchedShifts.isNotEmpty) {
        await replaceCachedShifts(fetchedShifts);
        print(
          'Successfully synced ${fetchedShifts.length} shifts for the last 7 days.',
        );
      }
    } catch (e) {
      print('=== Error downloading recent shifts ===');
      print(e.toString());
    }
  }

  Future<List<Map<String, dynamic>>> getPendingShifts() async {
    await init();
    final rows = await _database.query(
      _pendingShiftTable,
      orderBy: 'started_at ASC',
    );
    return rows
        .map(
          (row) => Map<String, dynamic>.from(
            jsonDecode(row['payload_json'] as String) as Map,
          ),
        )
        .toList(growable: false);
  }

  Future<void> removePendingShift(String localShiftId) async {
    await init();
    await _database.delete(
      _pendingShiftTable,
      where: 'local_shift_id = ?',
      whereArgs: [localShiftId],
    );
  }

  Future<int> syncPendingShifts(SupabaseClient supabase) async {
    final pending = await getPendingShifts();
    var synced = 0;
    for (final shift in pending) {
      final localShiftId = shift['local_shift_id']?.toString() ?? '';
      if (localShiftId.isEmpty) continue;
      await supabase.from('shifts').insert({
        'branch_id': shift['branch_id'],
        'started_at': shift['started_at'],
        'current_cashier_id': shift['cashier_id'],
        'status': 'open',
      });
      await removePendingShift(localShiftId);
      synced++;
    }
    return synced;
  }

  Future<void> replaceCachedShifts(List<Map<String, dynamic>> shifts) async {
    await init();
    await _database.transaction((txn) async {
      await txn.delete(_cachedShiftTable);
      for (final shift in shifts) {
        final shiftId = (shift['id'] as num?)?.toInt();
        if (shiftId == null) continue;
        await txn.insert(_cachedShiftTable, {
          'shift_id': shiftId,
          'status': shift['status']?.toString(),
          'branch_id': shift['branch_id']?.toString(),
          'started_at': shift['started_at']?.toString(),
          'ended_at': shift['ended_at']?.toString(),
          'current_cashier_id': (shift['current_cashier_id'] as num?)?.toInt(),
          'opened_by': (shift['opened_by'] as num?)?.toInt(),
          'closed_by': (shift['closed_by'] as num?)?.toInt(),
          'payload_json': jsonEncode(shift),
          'updated_at': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> upsertCachedShift(Map<String, dynamic> shift) async {
    await init();
    final shiftId = (shift['id'] as num?)?.toInt();
    if (shiftId == null) return;
    final existingRows = await _database.query(
      _cachedShiftTable,
      columns: ['payload_json'],
      where: 'shift_id = ?',
      whereArgs: [shiftId],
      limit: 1,
    );
    final existingPayload = existingRows.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(
            jsonDecode(existingRows.first['payload_json'] as String) as Map,
          );
    final merged = <String, dynamic>{...existingPayload, ...shift};
    await _database.insert(_cachedShiftTable, {
      'shift_id': shiftId,
      'status': merged['status']?.toString(),
      'branch_id': merged['branch_id']?.toString(),
      'started_at': merged['started_at']?.toString(),
      'ended_at': merged['ended_at']?.toString(),
      'current_cashier_id': (merged['current_cashier_id'] as num?)?.toInt(),
      'opened_by': (merged['opened_by'] as num?)?.toInt(),
      'closed_by': (merged['closed_by'] as num?)?.toInt(),
      'payload_json': jsonEncode(merged),
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getCachedShifts() async {
    await init();
    final rows = await _database.query(
      _cachedShiftTable,
      orderBy: 'started_at DESC',
      limit: 200,
    );
    return rows
        .map(
          (row) => Map<String, dynamic>.from(
            jsonDecode(row['payload_json'] as String) as Map,
          ),
        )
        .toList(growable: false);
  }

  Future<void> removeCachedShift(int shiftId) async {
    await init();
    await _database.delete(
      _cachedShiftTable,
      where: 'shift_id = ?',
      whereArgs: [shiftId],
    );
  }
}
