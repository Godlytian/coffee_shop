import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class OfflineOrderQueueRepository {
  static const String _dbName = 'offline_orders.db';
  static const int _dbVersion = 4;

  static const String pendingTable = 'offline_pending_orders';
  static const String failedTable = 'offline_failed_orders';
  static const String logsTable = 'offline_sync_logs';
  static const String syncLogsTable = 'sync_logs';

  Database? _db;

  Future<void> init() async {
    if (_db != null) return;

    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _dbName);

    _db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $pendingTable (
            local_txn_id TEXT PRIMARY KEY,
            event_type TEXT NOT NULL DEFAULT 'order',
            occurred_at_epoch INTEGER NOT NULL,
            queued_at TEXT NOT NULL,
            payload_json TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE $failedTable (
            local_txn_id TEXT PRIMARY KEY,
            failed_at TEXT NOT NULL,
            failure_reason TEXT,
            payload_json TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE $syncLogsTable (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            action TEXT NOT NULL,
            status TEXT NOT NULL,
            error_message TEXT,
            payload_json TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE $logsTable (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            level TEXT NOT NULL,
            message TEXT NOT NULL,
            local_txn_id TEXT,
            payload_json TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE $pendingTable ADD COLUMN event_type TEXT NOT NULL DEFAULT 'order'",
          );
          await db.execute(
            'ALTER TABLE $pendingTable ADD COLUMN occurred_at_epoch INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'UPDATE $pendingTable SET occurred_at_epoch = CAST(strftime("%s", queued_at) AS INTEGER) * 1000 WHERE occurred_at_epoch = 0',
          );
          await db.execute('''
            CREATE TABLE IF NOT EXISTS $logsTable (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              created_at TEXT NOT NULL,
              level TEXT NOT NULL,
              message TEXT NOT NULL,
              local_txn_id TEXT,
              payload_json TEXT
            )
          ''');
        }

        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE $logsTable ADD COLUMN payload_json TEXT',
          );
        }

        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS $syncLogsTable (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              timestamp TEXT NOT NULL,
              action TEXT NOT NULL,
              status TEXT NOT NULL,
              error_message TEXT,
              payload_json TEXT
            )
          ''');
        }
      },
    );
  }

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('OfflineOrderQueueRepository not initialized');
    }
    return db;
  }

  Future<int> getPendingCount() async {
    final result = await _database.rawQuery(
      'SELECT COUNT(*) AS c FROM $pendingTable',
    );
    return (result.first['c'] as int?) ?? 0;
  }

  Future<int> getFailedCount() async {
    final result = await _database.rawQuery(
      'SELECT COUNT(*) AS c FROM $failedTable',
    );
    return (result.first['c'] as int?) ?? 0;
  }

  Future<List<Map<String, dynamic>>> getPendingEvents() async {
    final rows = await _database.query(
      pendingTable,
      orderBy: 'occurred_at_epoch ASC, queued_at ASC',
    );

    return rows
        .map((row) {
          final payload = Map<String, dynamic>.from(
            jsonDecode(row['payload_json'] as String) as Map,
          );
          return {
            'local_txn_id': row['local_txn_id'],
            'event_type': row['event_type'] ?? 'order',
            'occurred_at_epoch': row['occurred_at_epoch'] ?? 0,
            ...payload,
          };
        })
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> getPendingOrders() async {
    final events = await getPendingEvents();
    return events
        .where((event) => event['event_type']?.toString() == 'order')
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> getFailedOrders() async {
    final rows = await _database.query(failedTable, orderBy: 'failed_at DESC');

    return rows
        .map((row) {
          final payload = jsonDecode(row['payload_json'] as String);
          return Map<String, dynamic>.from(payload as Map);
        })
        .toList(growable: false);
  }

  Future<void> addLog({
    required String level,
    required String message,
    String? localTxnId,
    Map<String, dynamic>? payload,
  }) async {
    final now = DateTime.now().toIso8601String();
    final encodedPayload = payload == null ? null : jsonEncode(payload);
    await _database.insert(logsTable, {
      'created_at': now,
      'level': level,
      'message': message,
      'local_txn_id': localTxnId,
      'payload_json': encodedPayload,
    });

    final normalizedStatus = switch (level.toLowerCase()) {
      'error' => 'FAILED',
      'warning' => 'PENDING',
      _ => 'SUCCESS',
    };
    await _database.insert(syncLogsTable, {
      'timestamp': now,
      'action': message,
      'status': normalizedStatus,
      'error_message': level.toLowerCase() == 'error' ? message : null,
      'payload_json': encodedPayload,
    });
  }

  Future<List<Map<String, dynamic>>> getSyncLogs({int limit = 200}) async {
    final rows = await _database.query(
      logsTable,
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows
        .map((row) {
          final mapped = Map<String, dynamic>.from(row);
          final rawPayload = mapped['payload_json']?.toString();
          if (rawPayload != null && rawPayload.isNotEmpty) {
            try {
              mapped['payload'] = Map<String, dynamic>.from(
                jsonDecode(rawPayload) as Map,
              );
            } catch (_) {
              // keep raw payload_json if malformed.
            }
          }
          return mapped;
        })
        .toList(growable: false);
  }

  Future<void> clearSyncLogs() async {
    await _database.delete(logsTable);
    await _database.delete(syncLogsTable);
  }

  Future<void> retryFailed(String localTxnId) async {
    await _database.transaction((txn) async {
      final rows = await txn.query(
        failedTable,
        where: 'local_txn_id = ?',
        whereArgs: [localTxnId],
        limit: 1,
      );
      if (rows.isEmpty) return;

      final payloadJson = rows.first['payload_json'] as String;
      final payload = Map<String, dynamic>.from(jsonDecode(payloadJson) as Map)
        ..remove('failed_at')
        ..remove('failure_reason')
        ..['queued_at'] = DateTime.now().toIso8601String();

      await txn.insert(pendingTable, {
        'local_txn_id': localTxnId,
        'event_type': payload['event_type']?.toString() ?? 'order',
        'occurred_at_epoch':
            (payload['occurred_at_epoch'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
        'queued_at': payload['queued_at'],
        'payload_json': jsonEncode(payload),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await txn.delete(
        failedTable,
        where: 'local_txn_id = ?',
        whereArgs: [localTxnId],
      );
    });
  }

  Future<void> deleteFailed(String localTxnId) async {
    await _database.delete(
      failedTable,
      where: 'local_txn_id = ?',
      whereArgs: [localTxnId],
    );
  }

  Future<void> enqueue(Map<String, dynamic> payload) async {
    final key = payload['local_txn_id']?.toString();
    if (key == null || key.isEmpty) {
      throw ArgumentError('local_txn_id is required');
    }

    await _database.insert(pendingTable, {
      'local_txn_id': key,
      'event_type': payload['event_type']?.toString() ?? 'order',
      'occurred_at_epoch':
          (payload['occurred_at_epoch'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      'queued_at':
          payload['queued_at']?.toString() ?? DateTime.now().toIso8601String(),
      'payload_json': jsonEncode(payload),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> removePending(String localTxnId) async {
    await _database.delete(
      pendingTable,
      where: 'local_txn_id = ?',
      whereArgs: [localTxnId],
    );
  }

  Future<void> moveToFailed({
    required String localTxnId,
    required Map<String, dynamic> payload,
    required String reason,
  }) async {
    await _database.transaction((txn) async {
      final failedPayload = Map<String, dynamic>.from(payload)
        ..['failed_at'] = DateTime.now().toIso8601String()
        ..['failure_reason'] = reason;

      await txn.insert(failedTable, {
        'local_txn_id': localTxnId,
        'failed_at': failedPayload['failed_at'],
        'failure_reason': reason,
        'payload_json': jsonEncode(failedPayload),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await txn.delete(
        pendingTable,
        where: 'local_txn_id = ?',
        whereArgs: [localTxnId],
      );
    });
  }
}
