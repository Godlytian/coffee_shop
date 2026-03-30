import 'package:coffee_shop/core/services/local_order_item_store_repository.dart';
import 'package:coffee_shop/core/services/local_order_store_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SyncManager {
  SyncManager({SupabaseClient? client})
    : _supabase = client ?? Supabase.instance.client;

  final SupabaseClient _supabase;

  Future<void> syncPendingOrders() async {
    final pendingOrders = await LocalOrderStoreRepository.instance
        .fetchUnsyncedOrders();

    final pendingInserts = pendingOrders
        .where((order) => ((order['id'] as num?)?.toInt() ?? 0) < 0)
        .toList(growable: false);
    for (final order in pendingInserts) {
      await _processPendingInsert(order);
    }

    final remaining = await LocalOrderStoreRepository.instance
        .fetchUnsyncedOrders();
    final pendingUpdates = remaining
        .where(
          (order) =>
              ((order['id'] as num?)?.toInt() ?? 0) > 0 &&
              order['sync_status']?.toString() == 'pending_update',
        )
        .toList(growable: false);

    for (final order in pendingUpdates) {
      await _processPendingUpdate(order);
    }
  }

  Future<void> _processPendingInsert(Map<String, dynamic> localOrder) async {
    final oldId = (localOrder['id'] as num?)?.toInt();
    if (oldId == null || oldId >= 0) return;

    final payload = _insertOrderPayload(localOrder);
    final inserted = await _supabase
        .from('orders')
        .insert(payload)
        .select('id')
        .single();
    final newId = (inserted['id'] as num?)?.toInt();
    if (newId == null || newId <= 0) {
      throw Exception(
        'Supabase insert did not return a valid positive order id',
      );
    }

    await LocalOrderStoreRepository.instance.swapOrderId(
      oldOrderId: oldId,
      newOrderId: newId,
      syncStatus: 'synced',
    );
    await LocalOrderStoreRepository.instance.reassignParentOrderId(
      oldParentOrderId: oldId,
      newParentOrderId: newId,
    );
    await LocalOrderItemStoreRepository.instance.reassignOrderId(
      oldOrderId: oldId,
      newOrderId: newId,
    );

    final items = await LocalOrderItemStoreRepository.instance.fetchByOrderId(
      newId,
    );
    if (items.isNotEmpty) {
      final itemPayload = items.map(_insertItemPayload).toList(growable: false);
      await _supabase.from('order_items').insert(itemPayload);
    }
    await LocalOrderItemStoreRepository.instance.markOrderItemsSyncStatus(
      orderId: newId,
      syncStatus: 'synced',
    );
  }

  Future<void> _processPendingUpdate(Map<String, dynamic> localOrder) async {
    final orderId = (localOrder['id'] as num?)?.toInt();
    if (orderId == null || orderId <= 0) return;

    final patch = _updateOrderPatch(localOrder);
    if (patch.isNotEmpty) {
      await _supabase.from('orders').update(patch).eq('id', orderId);
    }

    // Reflect the latest local item split composition without full order-row overwrite.
    final items = await LocalOrderItemStoreRepository.instance.fetchByOrderId(
      orderId,
    );
    await _supabase.from('order_items').delete().eq('order_id', orderId);
    if (items.isNotEmpty) {
      final itemPayload = items.map(_insertItemPayload).toList(growable: false);
      await _supabase.from('order_items').insert(itemPayload);
    }

    await LocalOrderStoreRepository.instance.markOrderSyncStatus(
      orderId,
      'synced',
    );
    await LocalOrderItemStoreRepository.instance.markOrderItemsSyncStatus(
      orderId: orderId,
      syncStatus: 'synced',
    );
  }

  Map<String, dynamic> _insertOrderPayload(Map<String, dynamic> localOrder) {
    final payload = Map<String, dynamic>.from(localOrder);
    payload.remove('id');
    payload.remove('sync_status');
    return payload;
  }

  Map<String, dynamic> _insertItemPayload(Map<String, dynamic> localItem) {
    final payload = Map<String, dynamic>.from(localItem);
    payload.remove('id');
    payload.remove('sync_status');
    return payload;
  }

  Map<String, dynamic> _updateOrderPatch(Map<String, dynamic> localOrder) {
    final patch = <String, dynamic>{};
    const allowedFields = <String>{
      'total_price',
      'subtotal',
      'discount_total',
      'status',
      'notes',
      'parent_order_id',
    };
    for (final key in allowedFields) {
      if (localOrder.containsKey(key)) {
        patch[key] = localOrder[key];
      }
    }
    return patch;
  }
}
