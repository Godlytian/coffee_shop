import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class LocalOrderItemStoreRepository {
  LocalOrderItemStoreRepository._();

  static final LocalOrderItemStoreRepository instance =
      LocalOrderItemStoreRepository._();

  static const String _dbName = 'local_order_items.db';
  static const int _dbVersion = 2;
  static const String _table = 'local_order_items';

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
          CREATE TABLE $_table (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            order_id INTEGER NOT NULL,
            sync_status TEXT NOT NULL DEFAULT 'synced',
            payload_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE $_table ADD COLUMN sync_status TEXT NOT NULL DEFAULT 'synced'",
          );
        }
      },
      onOpen: (db) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS $_table (
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

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('LocalOrderItemStoreRepository not initialized');
    }
    return db;
  }

  Future<void> replaceAll(
    List<Map<String, dynamic>> rows, {
    String syncStatus = 'synced',
  }) async {
    await init();
    await _database.transaction((txn) async {
      await txn.delete(_table);
      final now = DateTime.now().toIso8601String();
      for (final row in rows) {
        final orderId = (row['order_id'] as num?)?.toInt();
        if (orderId == null) continue;
        final resolvedSyncStatus = row['sync_status']?.toString() ?? syncStatus;
        final payload = Map<String, dynamic>.from(row)
          ..['sync_status'] = resolvedSyncStatus;
        await txn.insert(_table, {
          'order_id': orderId,
          'sync_status': resolvedSyncStatus,
          'payload_json': jsonEncode(payload),
          'updated_at': now,
        });
      }
    });
  }

  Future<void> replaceForOrder({
    required int orderId,
    required List<Map<String, dynamic>> rows,
    String syncStatus = 'synced',
  }) async {
    await init();
    await _database.transaction((txn) async {
      await txn.delete(_table, where: 'order_id = ?', whereArgs: [orderId]);
      final now = DateTime.now().toIso8601String();
      for (final row in rows) {
        final resolvedSyncStatus = row['sync_status']?.toString() ?? syncStatus;
        final payload = Map<String, dynamic>.from(row)
          ..['sync_status'] = resolvedSyncStatus;
        await txn.insert(_table, {
          'order_id': orderId,
          'sync_status': resolvedSyncStatus,
          'payload_json': jsonEncode(payload),
          'updated_at': now,
        });
      }
    });
  }

  Future<List<Map<String, dynamic>>> fetchByOrderId(int orderId) async {
    await init();
    final rows = await _database.query(
      _table,
      where: 'order_id = ?',
      whereArgs: [orderId],
      orderBy: 'id ASC',
    );

    return rows
        .map((row) {
          final payload = Map<String, dynamic>.from(
            jsonDecode(row['payload_json'] as String) as Map,
          );
          payload['sync_status'] =
              row['sync_status']?.toString() ??
              payload['sync_status']?.toString() ??
              'synced';
          return payload;
        })
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> fetchBySyncStatus(
    String syncStatus,
  ) async {
    await init();
    final rows = await _database.query(
      _table,
      where: 'sync_status = ?',
      whereArgs: [syncStatus],
      orderBy: 'id ASC',
    );
    return rows
        .map((row) {
          final payload = Map<String, dynamic>.from(
            jsonDecode(row['payload_json'] as String) as Map,
          );
          payload['sync_status'] = syncStatus;
          return payload;
        })
        .toList(growable: false);
  }

  Future<void> reassignOrderId({
    required int oldOrderId,
    required int newOrderId,
  }) async {
    await init();
    final rows = await fetchByOrderId(oldOrderId);
    if (rows.isEmpty) return;
    await replaceForOrder(
      orderId: newOrderId,
      rows: rows
          .map(
            (row) => Map<String, dynamic>.from(row)..['order_id'] = newOrderId,
          )
          .toList(growable: false),
      syncStatus: rows.first['sync_status']?.toString() ?? 'pending_insert',
    );
    await _database.delete(
      _table,
      where: 'order_id = ?',
      whereArgs: [oldOrderId],
    );
  }

  Future<void> markOrderItemsSyncStatus({
    required int orderId,
    required String syncStatus,
  }) async {
    await init();
    final rows = await fetchByOrderId(orderId);
    await replaceForOrder(
      orderId: orderId,
      rows: rows
          .map(
            (row) =>
                Map<String, dynamic>.from(row)..['sync_status'] = syncStatus,
          )
          .toList(growable: false),
      syncStatus: syncStatus,
    );
  }
}
