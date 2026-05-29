import 'dart:async';

import 'package:coffee_shop/core/repositories/local_order_store_repository.dart';
import 'package:coffee_shop/core/services/supabase_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OrderSyncService {
  OrderSyncService._();
  static final OrderSyncService instance = OrderSyncService._();

  RealtimeChannel? _channel;
  bool _started = false;

  Future<void> forceReconcile() async {
    await LocalOrderStoreRepository.instance.init();
    try {
      final sevenDaysAgo = DateTime.now().toUtc().subtract(
        const Duration(days: 7),
      );
      final sevenDaysAgoIso = sevenDaysAgo.toIso8601String();
      final rows = await supabase
          .from('orders')
          .select()
          .isFilter('deleted_at', null)
          .gte('created_at', sevenDaysAgoIso)
          .order('created_at', ascending: false);
      final mapped = rows
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      await LocalOrderStoreRepository.instance.reconcileOrders(mapped);

      // Prune local orders that are no longer present in the remote set.
      // This catches orders that were soft-deleted remotely while the device
      // was offline — the reconcile query excludes them (deleted_at IS NULL
      // filter), so without this step they would persist as ghost active orders.
      final remoteIds = mapped
          .map((r) => (r['id'] as num?)?.toInt())
          .whereType<int>()
          .toSet();
      final allLocal =
          await LocalOrderStoreRepository.instance.fetchAllOrders();
      for (final localOrder in allLocal) {
        final id = (localOrder['id'] as num?)?.toInt();
        if (id == null) continue;
        // Skip temporary offline IDs (epoch-ms based, 13 digits).
        if (id >= 1000000000000) continue;
        // Skip orders outside the reconcile window — they are not expected
        // to appear in the remote results.
        final createdAtStr = localOrder['created_at']?.toString();
        if (createdAtStr != null && createdAtStr.isNotEmpty) {
          final createdAt = DateTime.tryParse(createdAtStr)?.toUtc();
          if (createdAt != null && createdAt.isBefore(sevenDaysAgo)) continue;
        }
        if (!remoteIds.contains(id)) {
          await LocalOrderStoreRepository.instance.deleteOrder(id);
        }
      }
    } catch (e) {
      print('Order Sync forceReconcile error: $e');
    }
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await LocalOrderStoreRepository.instance.init();

    try {
      await forceReconcile();

      _channel = supabase.channel('public:orders');

      _channel!
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'orders',
            callback: (payload) async {
              final eventType = payload.eventType;
              final record = (eventType == PostgresChangeEvent.delete)
                  ? payload.oldRecord
                  : payload.newRecord;

              final id = record['id'];
              if (id == null) return;

              if (eventType == PostgresChangeEvent.delete ||
                  (record.containsKey('deleted_at') &&
                      record['deleted_at'] != null)) {
                await LocalOrderStoreRepository.instance.deleteOrder(id);
              } else {
                await LocalOrderStoreRepository.instance.upsertOrder(record);
              }
            },
          )
          .subscribe();
    } catch (e) {
      print('Order Sync Error during startup: $e');
    }
  }

  Future<void> stop() async {
    await _channel?.unsubscribe();
    _started = false;
  }
}
