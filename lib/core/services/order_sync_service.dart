import 'dart:async';

import 'package:coffee_shop/core/services/local_order_store_repository.dart';
import 'package:coffee_shop/core/services/supabase_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OrderSyncService {
  OrderSyncService._();
  static final OrderSyncService instance = OrderSyncService._();

  RealtimeChannel? _channel;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await LocalOrderStoreRepository.instance.init();

    try {
      // 1. Initial Fetch (Fixed Syntax)
      // Use .is_() which is the strict Supabase Flutter standard for IS NULL
      final initialData = await supabase
          .from('orders')
          .select()
          .isFilter('deleted_at', null)
          .order('created_at', ascending: false);

      final mappedInitial = initialData
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);

      // PHASE 3 TRIGGER: Reconcile instead of just upserting!
      // This guarantees the local cache perfectly mirrors the cloud on startup.
      await LocalOrderStoreRepository.instance.reconcileOrders(mappedInitial);

      // 2. Subscribe to discrete Postgres changes...
      // [Keep your existing Realtime code here]

      // 2. Subscribe to discrete Postgres changes for active sync (Phase 2)
      _channel = supabase.channel('public:orders');
      _channel!
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'orders',
            callback: (payload) async {
              final eventType = payload.eventType;

              if (eventType == PostgresChangeEvent.insert ||
                  eventType == PostgresChangeEvent.update) {
                final newRecord = payload.newRecord;

                // Phase 1 Cache Logic: If updated with a deleted_at timestamp, remove locally
                if (newRecord.containsKey('deleted_at') &&
                    newRecord['deleted_at'] != null) {
                  await LocalOrderStoreRepository.instance.deleteOrder(
                    newRecord['id'],
                  );
                } else {
                  // Otherwise, update or insert the order into the local cache
                  await LocalOrderStoreRepository.instance.upsertOrder(
                    newRecord,
                  );
                }
              }
              // Phase 2 Cache Logic: Catch accidental hard deletes directly
              else if (eventType == PostgresChangeEvent.delete) {
                final oldRecord = payload.oldRecord;
                if (oldRecord.containsKey('id')) {
                  await LocalOrderStoreRepository.instance.deleteOrder(
                    oldRecord['id'],
                  );
                }
              }
            },
          )
          .subscribe();
    } catch (e) {
      print('Order Sync Error during startup: $e'); // <-- Add this!
    }
  }

  Future<void> stop() async {
    await _channel?.unsubscribe();
    _started = false;
  }
}
