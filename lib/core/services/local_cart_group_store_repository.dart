import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class LocalCartGroupStoreRepository {
  LocalCartGroupStoreRepository._();

  static final LocalCartGroupStoreRepository instance =
      LocalCartGroupStoreRepository._();

  static const String _dbName = 'local_cart_groups.db';
  static const int _dbVersion = 1;
  static const String groupsTable = 'local_cart_groups';
  static const String groupItemsTable = 'local_group_items';

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
          CREATE TABLE $groupsTable (
            id TEXT PRIMARY KEY,
            order_id INTEGER NOT NULL,
            group_index INTEGER NOT NULL,
            group_name TEXT,
            payment_status TEXT,
            amount_paid REAL,
            closed_at TEXT,
            closed_by INTEGER,
            payload_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE $groupItemsTable (
            id TEXT PRIMARY KEY,
            group_id TEXT NOT NULL,
            order_item_id INTEGER NOT NULL,
            assigned_qty INTEGER NOT NULL,
            payload_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      },
      onOpen: (db) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS $groupsTable (
            id TEXT PRIMARY KEY,
            order_id INTEGER NOT NULL,
            group_index INTEGER NOT NULL,
            group_name TEXT,
            payment_status TEXT,
            amount_paid REAL,
            closed_at TEXT,
            closed_by INTEGER,
            payload_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS $groupItemsTable (
            id TEXT PRIMARY KEY,
            group_id TEXT NOT NULL,
            order_item_id INTEGER NOT NULL,
            assigned_qty INTEGER NOT NULL,
            payload_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      },
    );
  }

  Database get _database {
    final db = _db;
    if (db == null)
      throw StateError('LocalCartGroupStoreRepository not initialized');
    return db;
  }

  Future<void> replaceForOrder({
    required int orderId,
    required List<Map<String, dynamic>> groups,
    required List<Map<String, dynamic>> groupItems,
  }) async {
    await init();
    final now = DateTime.now().toIso8601String();
    await _database.transaction((txn) async {
      final groupIds = <String>[];
      for (final g in groups) {
        if ((g['order_id'] as num?)?.toInt() != orderId) continue;
        final id = g['id']?.toString();
        if (id == null || id.isEmpty) continue;
        groupIds.add(id);
      }

      await txn.delete(
        groupsTable,
        where: 'order_id = ?',
        whereArgs: [orderId],
      );
      if (groupIds.isNotEmpty) {
        final placeholders = List.filled(groupIds.length, '?').join(',');
        await txn.delete(
          groupItemsTable,
          where: 'group_id IN ($placeholders)',
          whereArgs: groupIds,
        );
      }

      for (final group in groups) {
        if ((group['order_id'] as num?)?.toInt() != orderId) continue;
        final id = group['id']?.toString();
        if (id == null || id.isEmpty) continue;
        await txn.insert(groupsTable, {
          'id': id,
          'order_id': orderId,
          'group_index': (group['group_index'] as num?)?.toInt() ?? 0,
          'group_name': group['group_name']?.toString(),
          'payment_status': group['payment_status']?.toString(),
          'amount_paid': (group['amount_paid'] as num?)?.toDouble() ?? 0,
          'closed_at': group['closed_at']?.toString(),
          'closed_by': (group['closed_by'] as num?)?.toInt(),
          'payload_json': jsonEncode(group),
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      for (final gi in groupItems) {
        final groupId = gi['group_id']?.toString();
        final id = gi['id']?.toString();
        if (groupId == null || groupId.isEmpty || id == null || id.isEmpty) {
          continue;
        }
        await txn.insert(groupItemsTable, {
          'id': id,
          'group_id': groupId,
          'order_item_id': (gi['order_item_id'] as num?)?.toInt() ?? 0,
          'assigned_qty': (gi['assigned_qty'] as num?)?.toInt() ?? 0,
          'payload_json': jsonEncode(gi),
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<Map<String, dynamic>>> fetchGroupsByOrderId(int orderId) async {
    await init();
    final rows = await _database.query(
      groupsTable,
      where: 'order_id = ?',
      whereArgs: [orderId],
      orderBy: 'group_index ASC',
    );
    return rows
        .map(
          (row) => Map<String, dynamic>.from(
            jsonDecode(row['payload_json'] as String) as Map,
          ),
        )
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> fetchGroupItemsByGroupIds(
    List<String> groupIds,
  ) async {
    await init();
    if (groupIds.isEmpty) return const <Map<String, dynamic>>[];
    final placeholders = List.filled(groupIds.length, '?').join(',');
    final rows = await _database.query(
      groupItemsTable,
      where: 'group_id IN ($placeholders)',
      whereArgs: groupIds,
      orderBy: 'updated_at ASC',
    );
    return rows
        .map(
          (row) => Map<String, dynamic>.from(
            jsonDecode(row['payload_json'] as String) as Map,
          ),
        )
        .toList(growable: false);
  }

  Future<void> reassignOrderId({
    required int oldOrderId,
    required int newOrderId,
  }) async {
    await init();
    final groups = await fetchGroupsByOrderId(oldOrderId);
    if (groups.isEmpty) return;
    final groupIds = groups
        .map((g) => g['id'].toString())
        .toList(growable: false);
    final items = await fetchGroupItemsByGroupIds(groupIds);
    final remappedGroups = groups
        .map((g) => Map<String, dynamic>.from(g)..['order_id'] = newOrderId)
        .toList(growable: false);
    await replaceForOrder(
      orderId: newOrderId,
      groups: remappedGroups,
      groupItems: items,
    );
    await _database.delete(
      groupsTable,
      where: 'order_id = ?',
      whereArgs: [oldOrderId],
    );
  }
}
