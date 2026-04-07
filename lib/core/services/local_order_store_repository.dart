import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class LocalOrderStoreRepository {
  LocalOrderStoreRepository._();
  static final LocalOrderStoreRepository instance =
      LocalOrderStoreRepository._();

  static const String _dbName = 'local_orders.db';
  static const int _dbVersion = 2;
  static const String _table = 'local_orders';

  Database? _db;
  final StreamController<List<Map<String, dynamic>>> _allController =
      StreamController<List<Map<String, dynamic>>>.broadcast();

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

    await _emitAll();
  }

  Database get _database {
    final db = _db;
    if (db == null)
      throw StateError('LocalOrderStoreRepository not initialized');
    return db;
  }

  Future<void> upsertOrder(
    Map<String, dynamic> order, {
    String syncStatus = 'synced',
  }) async {
    await init();
    final id = (order['id'] as num?)?.toInt();
    if (id == null) return;

    // 🔥 THE FIREWALL: If this order is soft-deleted, destroy it locally and abort the save.
    if (order.containsKey('deleted_at') && order['deleted_at'] != null) {
      await deleteOrder(id);
      return;
    }

    final resolvedSyncStatus = order['sync_status']?.toString() ?? syncStatus;
    final payload = Map<String, dynamic>.from(order)
      ..['sync_status'] = resolvedSyncStatus;

    await _database.insert(_table, {
      'id': id,
      'status': payload['status']?.toString(),
      'sync_status': resolvedSyncStatus,
      'order_source': payload['order_source']?.toString(),
      'created_at': payload['created_at']?.toString(),
      'payload_json': jsonEncode(payload),
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    await _emitAll();
  }

  Future<void> upsertOrders(
    List<Map<String, dynamic>> orders, {
    String syncStatus = 'synced',
  }) async {
    await init();
    await _database.transaction((txn) async {
      for (final order in orders) {
        final id = (order['id'] as num?)?.toInt();
        if (id == null) continue;

        final resolvedSyncStatus =
            order['sync_status']?.toString() ?? syncStatus;
        final payload = Map<String, dynamic>.from(order)
          ..['sync_status'] = resolvedSyncStatus;

        await txn.insert(_table, {
          'id': id,
          'status': payload['status']?.toString(),
          'sync_status': resolvedSyncStatus,
          'order_source': payload['order_source']?.toString(),
          'created_at': payload['created_at']?.toString(),
          'payload_json': jsonEncode(payload),
          'updated_at': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    await _emitAll();
  }

  Future<void> deleteOrder(int orderId) async {
    await init();
    await _database.delete(_table, where: 'id = ?', whereArgs: [orderId]);
    await _emitAll();
  }

  Future<void> reconcileOrders(
    List<Map<String, dynamic>> activeRemoteOrders,
  ) async {
    await init();

    final remoteIds = activeRemoteOrders
        .map((o) => (o['id'] as num).toInt())
        .toSet();

    final localRows = await _database.query(_table, columns: ['id']);
    final localIds = localRows.map((row) => (row['id'] as num).toInt()).toSet();

    final ghostIds = localIds
        .difference(remoteIds)
        .where((id) => id > 0)
        .toSet();

    if (ghostIds.isNotEmpty) {
      final batch = _database.batch();
      for (final id in ghostIds) {
        batch.delete(_table, where: 'id = ?', whereArgs: [id]);
      }
      await batch.commit();
      print('Reconciled & Deleted Ghost Orders: $ghostIds');
    }

    await upsertOrders(activeRemoteOrders);

    await _emitAll();
  }

  Future<List<Map<String, dynamic>>> fetchAllOrders() async {
    await init();
    final rows = await _database.query(_table, orderBy: 'id DESC');
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

  Future<List<Map<String, dynamic>>> fetchUnsyncedOrders() async {
    await init();
    final rows = await _database.query(
      _table,
      where: "sync_status != ?",
      whereArgs: const ['synced'],
      orderBy: 'updated_at ASC',
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

  Future<void> markOrderSyncStatus(int orderId, String syncStatus) async {
    await init();
    final rows = await _database.query(
      _table,
      where: 'id = ?',
      whereArgs: [orderId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final existing = Map<String, dynamic>.from(
      jsonDecode(rows.first['payload_json'] as String) as Map,
    )..['sync_status'] = syncStatus;

    await _database.update(
      _table,
      {
        'sync_status': syncStatus,
        'payload_json': jsonEncode(existing),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [orderId],
    );
    await _emitAll();
  }

  Future<void> swapOrderId({
    required int oldOrderId,
    required int newOrderId,
    String syncStatus = 'synced',
  }) async {
    await init();
    await _database.transaction((txn) async {
      final rows = await txn.query(
        _table,
        where: 'id = ?',
        whereArgs: [oldOrderId],
        limit: 1,
      );
      if (rows.isEmpty) return;

      final payload =
          Map<String, dynamic>.from(
              jsonDecode(rows.first['payload_json'] as String) as Map,
            )
            ..['id'] = newOrderId
            ..['sync_status'] = syncStatus;

      await txn.delete(_table, where: 'id = ?', whereArgs: [oldOrderId]);
      await txn.insert(_table, {
        'id': newOrderId,
        'status': payload['status']?.toString(),
        'sync_status': syncStatus,
        'order_source': payload['order_source']?.toString(),
        'created_at': payload['created_at']?.toString(),
        'payload_json': jsonEncode(payload),
        'updated_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await _emitAll();
  }

  Future<void> reassignParentOrderId({
    required int oldParentOrderId,
    required int newParentOrderId,
  }) async {
    await init();
    final rows = await fetchAllOrders();
    for (final row in rows) {
      final parentId = (row['parent_order_id'] as num?)?.toInt();
      if (parentId != oldParentOrderId) continue;
      final updated = Map<String, dynamic>.from(row)
        ..['parent_order_id'] = newParentOrderId
        ..['sync_status'] = 'pending_update';
      await upsertOrder(updated, syncStatus: 'pending_update');
    }
  }

  Stream<List<Map<String, dynamic>>> watchAllOrders() async* {
    await init();
    yield await fetchAllOrders();
    yield* _allController.stream;
  }

  // Replace the existing watchActiveOrders() method with this:

  Stream<List<Map<String, dynamic>>> watchActiveOrders() {
    return watchAllOrders().map(
      (rows) => rows
          .where((row) {
            // 1. Ignore deleted orders
            if (row['deleted_at'] != null) return false;

            final status = row['status']?.toString();
            final sessionStatus = row['session_status']?.toString();
            final type = row['type']?.toString();

            // 2. Already marked explicitly as active
            if (status == 'active') return true;

            // 3. QR Code / Dine-in flows (Open Tabs) that are waiting for payment/processing
            if ((sessionStatus == 'open' || type == 'dine_in') &&
                (status == 'pending' || status == 'paid')) {
              return true;
            }

            return false;
          })
          .toList(growable: false),
    );
  }

  Future<void> _emitAll() async {
    if (_allController.isClosed) return;
    _allController.add(await fetchAllOrders());
  }
}
