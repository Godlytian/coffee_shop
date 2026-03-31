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
      final initialData = await supabase
          .from('orders')
          .select()
          .isFilter('deleted_at', null)
          .order('created_at', ascending: false);

      final mappedInitial = initialData
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);

      await LocalOrderStoreRepository.instance.reconcileOrders(mappedInitial);

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
