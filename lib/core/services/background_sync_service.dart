import 'package:coffee_shop/features/cashier/data/offline_order_queue_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

const String offlineSyncTask = 'offline_sync_task';

@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != offlineSyncTask) return true;

    try {
      await Supabase.initialize(
        url: 'https://iasodtouoikaeuxkuecy.supabase.co',
        anonKey:
            'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlhc29kdG91b2lrYWV1eGt1ZWN5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA0ODYxMzIsImV4cCI6MjA4NjA2MjEzMn0.iqm3zxfy-Xl2a_6GDmTj6io8vJW2B3Sr5SHq_4vjJW4',
      );
      final client = Supabase.instance.client;

      final queue = OfflineOrderQueueRepository();
      await queue.init();
      final pending = await queue.getPendingEvents();
      final localShiftToRemoteShift = <int, int>{};

      for (final payload in pending) {
        final localTxnId = payload['local_txn_id']?.toString();
        if (localTxnId == null || localTxnId.isEmpty) continue;

        final eventType = payload['event_type']?.toString() ?? 'order';
        if (eventType == 'order') {
          final order = Map<String, dynamic>.from(payload['order'] as Map);
          final rawShiftId = (order['shift_id'] as num?)?.toInt();
          if (rawShiftId != null &&
              localShiftToRemoteShift.containsKey(rawShiftId)) {
            order['shift_id'] = localShiftToRemoteShift[rawShiftId];
          }
          final items = (payload['items'] as List<dynamic>)
              .whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList(growable: false);

          int? resolvedOrderId;
          final localTxn = payload['local_txn_id']?.toString() ?? '';
          final existing = await client
              .from('orders')
              .select('id')
              .ilike('notes', '%client_txn_id:$localTxn%')
              .limit(1);
          if (existing is List && existing.isNotEmpty) {
            resolvedOrderId =
                ((existing.first as Map<String, dynamic>)['id'] as num?)
                    ?.toInt();
          }

          if (resolvedOrderId == null) {
            final inserted = await client
                .from('orders')
                .insert(order)
                .select('id')
                .single();
            resolvedOrderId = (inserted['id'] as num?)?.toInt();
          }

          if (resolvedOrderId != null && items.isNotEmpty) {
            final current = await client
                .from('order_items')
                .select('id')
                .eq('order_id', resolvedOrderId);
            if ((current as List).isEmpty) {
              final orderItems = items
                  .map((item) => {...item, 'order_id': resolvedOrderId})
                  .toList(growable: false);
              await client.from('order_items').insert(orderItems);
            }

            final verify = await client
                .from('order_items')
                .select('id')
                .eq('order_id', resolvedOrderId);
            if ((verify as List).isEmpty) {
              throw Exception(
                'Post-sync consistency check failed for order_items',
              );
            }
          }
          await queue.removePending(localTxnId);
        } else if (eventType == 'shift_open') {
          final shift = Map<String, dynamic>.from(payload['shift'] as Map);
          final created = await client
              .from('shifts')
              .insert({
                'branch_id': shift['branch_id'],
                'status': 'open',
                'current_cashier_id': shift['cashier_id'],
                'started_at': shift['started_at'],
                'opened_by': shift['opened_by'],
              })
              .select('id')
              .single();
          final localShiftId = (shift['local_shift_id'] as num?)?.toInt();
          final remoteShiftId = (created['id'] as num?)?.toInt();
          if (localShiftId != null && remoteShiftId != null) {
            localShiftToRemoteShift[localShiftId] = remoteShiftId;
          }
          await queue.removePending(localTxnId);
        } else if (eventType == 'shift_close') {
          final shift = Map<String, dynamic>.from(payload['shift'] as Map);
          final rawShiftId = (shift['shift_id'] as num?)?.toInt();
          final shiftId = rawShiftId == null
              ? null
              : (localShiftToRemoteShift[rawShiftId] ?? rawShiftId);
          var closed = false;
          if (shiftId != null) {
            final updated = await client
                .from('shifts')
                .update({
                  'status': 'closed',
                  'ended_at': shift['ended_at'],
                  'closed_by': shift['closed_by'],
                })
                .eq('id', shiftId)
                .eq('status', 'open')
                .select('id');
            closed = (updated as List).isNotEmpty;
          }

          if (!closed) {
            final cashierId = (shift['cashier_id'] as num?)?.toInt();
            if (cashierId != null) {
              final openRows = await client
                  .from('shifts')
                  .select('id')
                  .eq('status', 'open')
                  .eq('current_cashier_id', cashierId)
                  .order('started_at', ascending: false)
                  .limit(1);

              if (openRows is List && openRows.isNotEmpty) {
                final fallbackShiftId =
                    ((openRows.first as Map<String, dynamic>)['id'] as num?)
                        ?.toInt();
                if (fallbackShiftId != null) {
                  final updated = await client
                      .from('shifts')
                      .update({
                        'status': 'closed',
                        'ended_at': shift['ended_at'],
                        'closed_by': shift['closed_by'],
                      })
                      .eq('id', fallbackShiftId)
                      .eq('status', 'open')
                      .select('id');
                  closed = (updated as List).isNotEmpty;
                }
              }
            }
          }

          if (!closed) {
            throw Exception('Unable to apply shift_close to any open shift');
          }

          await queue.removePending(localTxnId);
        } else if (eventType == 'shift_delete') {
          final shift = Map<String, dynamic>.from(payload['shift'] as Map);
          final shiftId = (shift['shift_id'] as num?)?.toInt();
          if (shiftId == null) {
            throw Exception('Missing shift_id for shift_delete');
          }
          await client.from('shifts').delete().eq('id', shiftId);

          await queue.removePending(localTxnId);
        }
      }
    } catch (_) {}

    return true;
  });
}

class BackgroundSyncService {
  static Future<void> initialize() async {
    await Workmanager().initialize(
      backgroundSyncDispatcher,
      isInDebugMode: false,
    );
    await Workmanager().registerPeriodicTask(
      offlineSyncTask,
      offlineSyncTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }
}
