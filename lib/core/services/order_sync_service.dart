import 'dart:async';

import 'package:coffee_shop/core/services/local_order_store_repository.dart';
import 'package:coffee_shop/core/services/supabase_client.dart';

class OrderSyncService {
  OrderSyncService._();
  static final OrderSyncService instance = OrderSyncService._();

  StreamSubscription<List<Map<String, dynamic>>>? _subscription;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await LocalOrderStoreRepository.instance.init();

    try {
      _subscription = supabase
          .from('orders')
          .stream(primaryKey: ['id'])
          .order('created_at', ascending: false)
          .listen((rows) async {
            final mapped = rows
                .map((row) => Map<String, dynamic>.from(row))
                .toList(growable: false);
            await LocalOrderStoreRepository.instance.upsertOrders(mapped);
          });
    } catch (_) {}
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _started = false;
  }
}
