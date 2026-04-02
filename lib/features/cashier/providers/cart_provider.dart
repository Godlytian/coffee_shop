import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '/features/cashier/models/models.dart';
import 'package:coffee_shop/core/services/local_order_store_repository.dart';
import 'package:coffee_shop/core/services/local_order_item_store_repository.dart';
import '../data/offline_order_queue_repository.dart';

class CartProvider extends ChangeNotifier {
  final OfflineOrderQueueRepository _offlineRepo =
      OfflineOrderQueueRepository();
  final Uuid _uuid = const Uuid();

  final Map<String, CartItem> _items = {};
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isSyncing = false;
  bool _hasNetworkConnection = true;
  bool _isServerReachable = true;
  DateTime? _lastSuccessfulSyncAt;
  int _syncTotalItems = 0;
  int _syncProcessedItems = 0;
  double _totalAmount = 0.0;

  CartProvider() {
    _bootstrapOffline();
  }

  Map<String, CartItem> get items => _items;

  int _pendingOfflineOrderCount = 0;

  int get pendingOfflineOrderCount => _pendingOfflineOrderCount;

  bool get isSyncingOfflineOrders => _isSyncing;
  bool get hasNetworkConnection => _hasNetworkConnection;
  bool get isServerReachable => _isServerReachable;
  DateTime? get lastSuccessfulSyncAt => _lastSuccessfulSyncAt;
  int get syncTotalItems => _syncTotalItems;
  int get syncProcessedItems => _syncProcessedItems;

  Future<void> _bootstrapOffline() async {
    await _offlineRepo.init();
    await _refreshOfflineCounters();
    await refreshConnectionStatus();

    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) async {
      final hasNetwork = !results.contains(ConnectivityResult.none);
      _hasNetworkConnection = hasNetwork;
      if (hasNetwork) {
        await refreshConnectionStatus();
        await syncOfflineOrders();
      } else {
        _isServerReachable = false;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  Future<void> _refreshOfflineCounters() async {
    _pendingOfflineOrderCount = await _offlineRepo.getPendingCount();
  }

  bool _isTransientError(Object error) {
    if (error is TimeoutException || error is SocketException) {
      return true;
    }
    final message = error.toString().toLowerCase();
    return message.contains('timeout') ||
        message.contains('network') ||
        message.contains('connection') ||
        message.contains('socket') ||
        message.contains('temporarily');
  }

  bool _isShiftForeignKeyViolation(Object error) {
    if (error is! PostgrestException) return false;
    final lower = error.message.toLowerCase();
    return error.code == '23503' && lower.contains('orders_shift_id_fkey');
  }

  bool _isLocalTemporaryOrderId(int? orderId) {
    if (orderId == null) return false;
    // Offline fallback ids are unix-epoch based (13 digits).
    return orderId >= 1000000000000;
  }

  Future<List<Map<String, dynamic>>> getPendingOfflineOrders() async {
    await _offlineRepo.init();
    return _offlineRepo.getPendingOrders();
  }

  Future<List<Map<String, dynamic>>> getFailedOfflineOrders() async {
    await _offlineRepo.init();
    return _offlineRepo.getFailedOrders();
  }

  Future<List<Map<String, dynamic>>> getPendingSyncQueue() async {
    await _offlineRepo.init();
    return _offlineRepo.getPendingEvents();
  }

  Future<List<Map<String, dynamic>>> getSyncLogs() async {
    await _offlineRepo.init();
    return _offlineRepo.getSyncLogs();
  }

  Future<void> clearSyncLogs() async {
    await _offlineRepo.init();
    await _offlineRepo.clearSyncLogs();
  }

  Future<void> enqueueOfflineShiftEvent({
    required String eventType,
    required Map<String, dynamic> payload,
    String? label,
  }) async {
    await _offlineRepo.init();
    final localTxnId = _uuid.v4();
    await _offlineRepo.enqueue({
      'local_txn_id': localTxnId,
      'event_type': eventType,
      'occurred_at_epoch': DateTime.now().millisecondsSinceEpoch,
      'queued_at': DateTime.now().toIso8601String(),
      ...payload,
    });
    await _offlineRepo.addLog(
      level: 'info',
      message: label == null
          ? 'Queued $eventType for sync'
          : 'Queued $label for sync',
      localTxnId: localTxnId,
      payload: payload,
    );
    await _refreshOfflineCounters();
    notifyListeners();
  }

  Future<void> refreshConnectionStatus() async {
    final result = await Connectivity().checkConnectivity();
    if (result is List<ConnectivityResult>) {
      _hasNetworkConnection = !result.contains(ConnectivityResult.none);
    } else {
      _hasNetworkConnection = result != ConnectivityResult.none;
    }

    if (!_hasNetworkConnection) {
      _isServerReachable = false;
      notifyListeners();
      return;
    }

    try {
      await Supabase.instance.client
          .from('orders')
          .select('id')
          .limit(1)
          .timeout(const Duration(seconds: 3));
      _isServerReachable = true;
    } catch (error) {
      _isServerReachable = !_isTransientError(error);
    }

    notifyListeners();
  }

  Future<Map<String, dynamic>> getSyncSummary() async {
    await _offlineRepo.init();
    final pending = await _offlineRepo.getPendingEvents();
    final failed = await _offlineRepo.getFailedOrders();

    var pendingOrders = 0;
    var pendingShiftEvents = 0;
    var pendingValue = 0.0;

    for (final event in pending) {
      final type = event['event_type']?.toString() ?? 'order';
      if (type == 'order') {
        pendingOrders++;
        final order = Map<String, dynamic>.from(
          event['order'] as Map? ?? <String, dynamic>{},
        );
        pendingValue += (order['total_price'] as num?)?.toDouble() ?? 0;
      } else {
        pendingShiftEvents++;
      }
    }

    return {
      'pending_total': pending.length,
      'pending_orders': pendingOrders,
      'pending_shift_events': pendingShiftEvents,
      'pending_value': pendingValue,
      'failed_total': failed.length,
      'last_successful_sync_at': _lastSuccessfulSyncAt,
    };
  }

  String toFriendlySyncError(Object error) {
    final text = error.toString();
    final lower = text.toLowerCase();

    if (lower.contains('jwt') || lower.contains('auth')) {
      return 'Cashier session expired. Please log in again.';
    }
    if (lower.contains('timeout') ||
        lower.contains('network') ||
        lower.contains('connection') ||
        lower.contains('socket')) {
      return 'No stable internet connection. Please reconnect and retry.';
    }
    if (lower.contains('duplicate') || lower.contains('23505')) {
      return 'This record was already synced.';
    }

    return 'Server rejected this record. Please retry or contact admin.';
  }

  Future<void> retryFailedOfflineOrder(String localTxnId) async {
    await _offlineRepo.init();
    await _offlineRepo.retryFailed(localTxnId);
    await _refreshOfflineCounters();
    notifyListeners();
  }

  Future<void> deleteFailedOfflineOrder(String localTxnId) async {
    await _offlineRepo.init();
    await _offlineRepo.deleteFailed(localTxnId);
    await _refreshOfflineCounters();
    notifyListeners();
  }

  Future<int> syncOfflineOrders() async {
    if (_isSyncing) return 0;
    await _offlineRepo.init();

    final pending = await _offlineRepo.getPendingEvents();
    _syncTotalItems = pending.length;
    _syncProcessedItems = 0;
    if (pending.isEmpty) {
      await _refreshOfflineCounters();
      notifyListeners();
      return 0;
    }

    _isSyncing = true;
    notifyListeners();

    final supabase = Supabase.instance.client;
    var synced = 0;
    final localShiftToRemoteShift = <int, int>{};

    try {
      for (final event in pending) {
        final localTxnId = event['local_txn_id']?.toString();
        if (localTxnId == null || localTxnId.isEmpty) {
          continue;
        }
        final eventType = event['event_type']?.toString() ?? 'order';

        try {
          if (eventType == 'order') {
            await _submitOfflinePayload(
              supabase,
              event,
              localShiftToRemoteShift: localShiftToRemoteShift,
            );
            await LocalOrderStoreRepository.instance.upsertOrder(
              Map<String, dynamic>.from(event['order'] as Map),
            );
          } else if (eventType == 'shift_open') {
            final shift = Map<String, dynamic>.from(event['shift'] as Map);
            final created = await supabase
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
          } else if (eventType == 'shift_close') {
            final shift = Map<String, dynamic>.from(event['shift'] as Map);
            final rawShiftId = (shift['shift_id'] as num?)?.toInt();
            final shiftId = rawShiftId == null
                ? null
                : (localShiftToRemoteShift[rawShiftId] ?? rawShiftId);
            var closed = false;
            if (shiftId != null) {
              final updated = await supabase
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
                final openRows = await supabase
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
                    final updated = await supabase
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
          }

          await _offlineRepo.removePending(localTxnId);
          _syncProcessedItems++;
          await _offlineRepo.addLog(
            level: 'success',
            message: 'Synced $eventType',
            localTxnId: localTxnId,
            payload: event,
          );
          synced++;
        } catch (error) {
          if (_isTransientError(error)) {
            await _offlineRepo.addLog(
              level: 'warning',
              message: 'Sync paused by connectivity issue: $error',
              localTxnId: localTxnId,
              payload: event,
            );
            await refreshConnectionStatus();
            break;
          }

          await _offlineRepo.moveToFailed(
            localTxnId: localTxnId,
            payload: event,
            reason: error.toString(),
          );
          _syncProcessedItems++;
          await _offlineRepo.addLog(
            level: 'error',
            message: 'Failed syncing $eventType: $error',
            localTxnId: localTxnId,
          );
          continue;
        }
      }
    } finally {
      _isSyncing = false;
      if (synced > 0) {
        _lastSuccessfulSyncAt = DateTime.now();
      }
      await _refreshOfflineCounters();
      await refreshConnectionStatus();
      notifyListeners();
    }

    return synced;
  }

  Future<void> _submitOfflinePayload(
    SupabaseClient supabase,
    Map<String, dynamic> payload, {
    required Map<int, int> localShiftToRemoteShift,
  }) async {
    final localTxnId = payload['local_txn_id']?.toString() ?? '';
    final order = Map<String, dynamic>.from(payload['order'] as Map);
    final rawShiftId = (order['shift_id'] as num?)?.toInt();
    if (rawShiftId != null && localShiftToRemoteShift.containsKey(rawShiftId)) {
      order['shift_id'] = localShiftToRemoteShift[rawShiftId];
    }

    final resolvedShiftId = (order['shift_id'] as num?)?.toInt();
    if (resolvedShiftId != null) {
      try {
        final existingShift = await supabase
            .from('shifts')
            .select('id')
            .eq('id', resolvedShiftId)
            .maybeSingle();
        if (existingShift == null) {
          order['shift_id'] = null;
        }
      } catch (_) {
        // keep original shift_id; insert path below will handle FK fallback.
      }
    }

    final rawOrderId = (order['id'] as num?)?.toInt();
    if (_isLocalTemporaryOrderId(rawOrderId)) {
      order['id'] = await _generateDailyUniqueOrderId(supabase);
    }

    final items = (payload['items'] as List<dynamic>)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);

    int? resolvedOrderId;

    dynamic existing;
    try {
      existing = await supabase
          .from('orders')
          .select('id')
          .or(
            'notes.ilike.%client_txn_id:$localTxnId%,idempotency_key.eq.$localTxnId',
          )
          .limit(1);
    } catch (_) {
      existing = await supabase
          .from('orders')
          .select('id')
          .ilike('notes', '%client_txn_id:$localTxnId%')
          .limit(1);
    }
    if (existing is List && existing.isNotEmpty) {
      final existingOrder = existing.first as Map<String, dynamic>;
      resolvedOrderId = (existingOrder['id'] as num?)?.toInt();
    }

    if (resolvedOrderId == null) {
      for (var attempt = 0; attempt < 5; attempt++) {
        try {
          Map<String, dynamic> inserted;
          try {
            inserted = await supabase
                .from('orders')
                .insert(order)
                .select('id')
                .single();
          } on PostgrestException catch (error) {
            if (error.message.toLowerCase().contains('idempotency_key')) {
              order.remove('idempotency_key');
              inserted = await supabase
                  .from('orders')
                  .insert(order)
                  .select('id')
                  .single();
            } else if (_isShiftForeignKeyViolation(error)) {
              order['shift_id'] = null;
              inserted = await supabase
                  .from('orders')
                  .insert(order)
                  .select('id')
                  .single();
            } else {
              rethrow;
            }
          }
          resolvedOrderId = (inserted['id'] as num?)?.toInt();
          break;
        } on PostgrestException catch (error) {
          if (_isShiftForeignKeyViolation(error)) {
            order['shift_id'] = null;
            continue;
          }
          final isDuplicateId =
              error.code == '23505' &&
              error.message.toLowerCase().contains('id');
          final duplicateTxn =
              error.code == '23505' &&
              error.message.toLowerCase().contains('client_txn_id');
          if (duplicateTxn) {
            final found = await supabase
                .from('orders')
                .select('id')
                .ilike('notes', '%client_txn_id:$localTxnId%')
                .limit(1);
            if (found is List && found.isNotEmpty) {
              resolvedOrderId =
                  ((found.first as Map<String, dynamic>)['id'] as num?)
                      ?.toInt();
            }
            break;
          }
          if (!isDuplicateId || attempt == 4) rethrow;

          final newOrderId = await _generateDailyUniqueOrderId(supabase);
          order['id'] = newOrderId;
        }
      }
    }

    if (resolvedOrderId == null) {
      throw Exception('Unable to resolve order id for offline payload sync');
    }

    final queuedOrder = Map<String, dynamic>.from(payload['order'] as Map);
    queuedOrder['id'] = resolvedOrderId;
    queuedOrder['shift_id'] = order['shift_id'];
    payload['order'] = queuedOrder;

    final orderItems = items
        .map((item) => {...item, 'order_id': resolvedOrderId})
        .toList(growable: false);
    payload['items'] = orderItems;

    final existingItemRows = await supabase
        .from('order_items')
        .select('id')
        .eq('order_id', resolvedOrderId);
    final existingCount = (existingItemRows as List).length;

    if (existingCount == 0 && orderItems.isNotEmpty) {
      await supabase.from('order_items').insert(orderItems);
    }

    final verifyRows = await supabase
        .from('order_items')
        .select('id')
        .eq('order_id', resolvedOrderId);
    if ((verifyRows as List).isEmpty && orderItems.isNotEmpty) {
      throw Exception('Post-sync consistency check failed: order_items empty');
    }
  }

  double get totalAmount => _totalAmount;

  double _modifierUnitPrice(CartItem item) {
    final data = item.modifiersData;
    if (data == null) {
      return 0;
    }

    return data.whereType<Map<String, dynamic>>().fold<double>(0, (
      sum,
      modifier,
    ) {
      final selected =
          modifier['selected_options'] as List<dynamic>? ?? <dynamic>[];
      final selectedTotal = selected
          .whereType<Map<String, dynamic>>()
          .fold<double>(
            0,
            (s, option) => s + ((option['price'] as num?)?.toDouble() ?? 0),
          );
      return sum + selectedTotal;
    });
  }

  double _lineUnitPrice(CartItem item) {
    return item.price + _modifierUnitPrice(item);
  }

  void _recalculateTotalAmount() {
    var total = 0.0;
    _items.forEach((_, item) {
      total += _lineUnitPrice(item) * item.quantity;
    });
    _totalAmount = total;
  }

  void addItem(
    Product product, {
    required int quantity,
    CartModifiers? modifiers,
    List<dynamic>? modifiersData,
  }) {
    if (quantity <= 0) return;

    final cartLineKey = _buildCartLineKey(product, modifiers, modifiersData);
    if (_items.containsKey(cartLineKey)) {
      final existing = _items[cartLineKey]!;
      _items.update(
        cartLineKey,
        (_) => _toCartItem(
          product,
          quantity: existing.quantity + quantity,
          existingCartId: existing.cartId,
          modifiers: existing.modifiers,
          modifiersData: existing.modifiersData,
        ),
      );
    } else {
      _items.putIfAbsent(
        cartLineKey,
        () => _toCartItem(
          product,
          quantity: quantity,
          modifiers: modifiers,
          modifiersData: modifiersData,
        ),
      );
    }

    _recalculateTotalAmount();
    notifyListeners();
  }

  void replaceItem({
    required String existingKey,
    required Product product,
    required int quantity,
    CartModifiers? modifiers,
    List<dynamic>? modifiersData,
  }) {
    if (quantity <= 0) return;

    final newKey = _buildCartLineKey(product, modifiers, modifiersData);
    final existing = _items[existingKey];
    _items.remove(existingKey);

    if (_items.containsKey(newKey)) {
      final target = _items[newKey]!;
      _items[newKey] = _toCartItem(
        product,
        quantity: target.quantity + quantity,
        existingCartId: target.cartId,
        modifiers: target.modifiers,
        modifiersData: target.modifiersData,
      );
    } else {
      _items[newKey] = _toCartItem(
        product,
        quantity: quantity,
        existingCartId: existing?.cartId,
        modifiers: modifiers,
        modifiersData: modifiersData,
      );
    }

    _recalculateTotalAmount();
    notifyListeners();
  }

  void removeItem(String key) {
    _items.remove(key);
    _recalculateTotalAmount();
    notifyListeners();
  }

  String _buildCartLineKey(
    Product product,
    CartModifiers? modifiers,
    List<dynamic>? modifiersData,
  ) {
    final modifiersPayload =
        modifiers?.toJson() ?? {'modifiers_data': modifiersData ?? <dynamic>[]};

    return '${product.id}::${jsonEncode(modifiersPayload)}';
  }

  CartItem _toCartItem(
    Product product, {
    required int quantity,
    String? existingCartId,
    CartModifiers? modifiers,
    List<dynamic>? modifiersData,
  }) {
    return CartItem(
      id: product.id,
      name: product.name,
      price: product.price,
      category: product.category,
      description: product.description,
      imageUrl: product.imageUrl,
      isAvailable: product.isAvailable,
      isBundle: product.isBundle,
      isRecommended: product.isRecommended,
      productBundles: product.productBundles,
      cartId: existingCartId ?? DateTime.now().toIso8601String(),
      quantity: quantity,
      modifiers: modifiers,
      modifiersData: modifiersData,
    );
  }

  String _datePrefix(DateTime now) {
    final year = (now.year % 100).toString().padLeft(2, '0');
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '$year$month$day';
  }

  Future<int> _generateDailyUniqueOrderId(SupabaseClient supabase) async {
    final now = DateTime.now();
    final prefix = _datePrefix(now);
    final prefixValue = int.parse(prefix);
    final minId = prefixValue * 1000;
    final maxId = minId + 999;

    final existingRows = await supabase
        .from('orders')
        .select('id')
        .gte('id', minId)
        .lte('id', maxId);

    final usedIds = existingRows
        .whereType<Map<String, dynamic>>()
        .map((row) => int.tryParse(row['id'].toString()))
        .whereType<int>()
        .toSet();

    if (usedIds.length >= 1000) {
      throw Exception('Daily order id capacity exhausted for $prefix');
    }

    final random = Random();
    for (var i = 0; i < 2000; i++) {
      final suffix = random.nextInt(1000);
      final candidate = minId + suffix;
      if (!usedIds.contains(candidate)) {
        return candidate;
      }
    }

    for (var suffix = 0; suffix < 1000; suffix++) {
      final candidate = minId + suffix;
      if (!usedIds.contains(candidate)) {
        return candidate;
      }
    }

    throw Exception('Unable to generate daily unique order id for $prefix');
  }

  dynamic _serializeItemModifiers(CartItem item) {
    final data = item.modifiersData;
    if (data != null && data.isNotEmpty) {
      return data;
    }
    return item.modifiers?.toJson();
  }

  List<Map<String, dynamic>> _buildOrderItemPayloadRows(int orderId) {
    return _items.values
        .map(
          (item) => {
            'order_id': orderId,
            'product_id': item.id,
            'quantity': item.quantity,
            'price_at_time': _lineUnitPrice(item),
            'modifiers': _serializeItemModifiers(item),
          },
        )
        .toList(growable: false);
  }

  Future<void> _updateQueuedOrderEventIfExists({
    required int orderId,
    required Map<String, dynamic> latestOrder,
    required List<Map<String, dynamic>> latestItems,
  }) async {
    await _offlineRepo.init();
    final pending = await _offlineRepo.getPendingEvents();

    Map<String, dynamic>? matched;
    for (final event in pending.reversed) {
      final type = event['event_type']?.toString() ?? 'order';
      if (type != 'order') continue;
      final queuedOrder = event['order'] as Map?;
      final queuedOrderId = (queuedOrder?['id'] as num?)?.toInt();
      if (queuedOrderId == orderId) {
        matched = event;
        break;
      }
    }

    if (matched == null) return;

    final localTxnId = matched['local_txn_id']?.toString();
    if (localTxnId == null || localTxnId.isEmpty) return;

    final existingOrder = Map<String, dynamic>.from(matched['order'] as Map);
    final mergedOrder = Map<String, dynamic>.from(existingOrder)
      ..addAll(latestOrder);

    final existingNotes = existingOrder['notes']?.toString();
    final mergedNotes = mergedOrder['notes']?.toString();
    if (existingNotes != null &&
        existingNotes.contains('client_txn_id:') &&
        (mergedNotes == null || !mergedNotes.contains('client_txn_id:'))) {
      final txnLine = existingNotes
          .split('\n')
          .firstWhere(
            (line) => line.contains('client_txn_id:'),
            orElse: () => 'client_txn_id:$localTxnId',
          );
      if (mergedNotes == null || mergedNotes.isEmpty) {
        mergedOrder['notes'] = txnLine;
      } else {
        mergedOrder['notes'] = '$mergedNotes\n$txnLine';
      }
    }

    if ((mergedOrder['idempotency_key']?.toString().isEmpty ?? true) &&
        existingOrder['idempotency_key'] != null) {
      mergedOrder['idempotency_key'] = existingOrder['idempotency_key'];
    }

    final updatedPayload = {
      ...matched,
      'local_txn_id': localTxnId,
      'event_type': 'order',
      'occurred_at_epoch':
          (matched['occurred_at_epoch'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      'queued_at': DateTime.now().toIso8601String(),
      'order': mergedOrder,
      'items': latestItems,
    };

    await _offlineRepo.enqueue(updatedPayload);
    await _offlineRepo.addLog(
      level: 'info',
      message: 'Updated queued order#$orderId with latest cart changes',
      localTxnId: localTxnId,
      payload: updatedPayload,
    );
  }

  List<Map<String, dynamic>> _buildOfflineOrderItemCacheRows(int orderId) {
    return _items.values
        .map(
          (item) => {
            'order_id': orderId,
            'quantity': item.quantity,
            'product_id': item.id,
            'modifiers': _serializeItemModifiers(item),
            'products': {
              'id': item.id,
              'name': item.name,
              'price': item.price,
              'category': item.category,
              'description': item.description,
              'image_url': item.imageUrl,
              'is_available': item.isAvailable,
              'is_bundle': item.isBundle,
              'is_recommended': item.isRecommended,
              'modifiers': item.productModifiers,
            },
          },
        )
        .toList(growable: false);
  }

  Future<int> updateExistingOrder({
    required int orderId,
    String? customerName,
    String? tableName,
    required String orderType,
    String? paymentMethod,
    num? totalPaymentReceived,
    num? changeAmount,
    String? status,
  }) async {
    final supabase = Supabase.instance.client;
    final normalizedTotal = totalAmount % 1 == 0
        ? totalAmount.toInt()
        : totalAmount;

    final existingOrders = await LocalOrderStoreRepository.instance
        .fetchAllOrders();
    final existingOrder = existingOrders.firstWhere(
      (row) => ((row['id'] as num?)?.toInt() ?? -1) == orderId,
      orElse: () => <String, dynamic>{},
    );
    final existingOrderSource = existingOrder['order_source']?.toString();

    final localOrderItems = _buildOfflineOrderItemCacheRows(orderId);
    final hasCartItems = _items.isNotEmpty;
    final orderItemsPayload = hasCartItems
        ? _items.values
              .map((item) {
                return {
                  'order_id': orderId,
                  'product_id': item.id,
                  'quantity': item.quantity,
                  'price_at_time': _lineUnitPrice(item),
                  'modifiers': _serializeItemModifiers(item),
                };
              })
              .toList(growable: false)
        : const <Map<String, dynamic>>[];
    final localOrderPayload = {
      'id': orderId,
      'total_price': normalizedTotal,
      'subtotal': normalizedTotal,
      'discount_total': 0,
      'points_earned': 0,
      'points_used': 0,
      'status': status ?? 'active',
      'type': orderType,
      'payment_method': paymentMethod,
      'total_payment_received': totalPaymentReceived,
      'change_amount': changeAmount,
      'customer_name': customerName,
      'notes': (tableName == null || tableName.isEmpty)
          ? null
          : 'Table: $tableName',
      'order_source': existingOrderSource ?? 'cashier',
      'created_at':
          existingOrder['created_at']?.toString() ??
          DateTime.now().toIso8601String(),
    };

    try {
      await supabase
          .from('orders')
          .update({
            'total_price': normalizedTotal,
            'subtotal': normalizedTotal,
            'discount_total': 0,
            'points_earned': 0,
            'points_used': 0,
            'status': status ?? 'active',
            'type': orderType,
            'payment_method': paymentMethod,
            'total_payment_received': totalPaymentReceived,
            'change_amount': changeAmount,
            'customer_name': customerName,
            'notes': (tableName == null || tableName.isEmpty)
                ? null
                : 'Table: $tableName',
          })
          .eq('id', orderId);

      if (hasCartItems) {
        await supabase.from('order_items').delete().eq('order_id', orderId);
        await supabase.from('order_items').insert(orderItemsPayload);
      }
    } catch (_) {}

    await LocalOrderStoreRepository.instance.upsertOrder(
      Map<String, dynamic>.from(localOrderPayload),
    );
    if (hasCartItems) {
      await LocalOrderItemStoreRepository.instance.replaceForOrder(
        orderId: orderId,
        rows: localOrderItems,
      );
    }
    if (hasCartItems) {
      await _updateQueuedOrderEventIfExists(
        orderId: orderId,
        latestOrder: Map<String, dynamic>.from(localOrderPayload),
        latestItems: _buildOrderItemPayloadRows(orderId),
      );
    }

    return orderId;
  }

  Future<int> submitOrder({
    String? customerName,
    String? tableName,
    required String orderType,
    String paymentMethod = 'cash',
    num? totalPaymentReceived,
    num? changeAmount,
    String status = 'active',
    int? parentOrderId,
    int? cashierId,
    int? shiftId,
    bool shouldClearCart = true,
  }) async {
    final supabase = Supabase.instance.client;
    final normalizedTotal = totalAmount % 1 == 0
        ? totalAmount.toInt()
        : totalAmount;
    final localTxnId = _uuid.v4();

    String composeNotes() {
      final tableNote = (tableName == null || tableName.isEmpty)
          ? ''
          : 'Table: $tableName';
      if (tableNote.isEmpty) {
        return 'client_txn_id:$localTxnId';
      }
      return '$tableNote\nclient_txn_id:$localTxnId';
    }

    Map<String, dynamic>? orderPayload;
    List<Map<String, dynamic>> orderItems = <Map<String, dynamic>>[];

    try {
      Map<String, dynamic>? orderResponse;
      for (var attempt = 0; attempt < 5; attempt++) {
        final generatedOrderId = await _generateDailyUniqueOrderId(supabase);
        final payload = {
          'id': generatedOrderId,
          'total_price': normalizedTotal,
          'subtotal': normalizedTotal,
          'discount_total': 0,
          'points_earned': 0,
          'points_used': 0,
          'status': status,
          'type': orderType,
          'order_source': 'cashier',
          'payment_method': paymentMethod,
          'total_payment_received': totalPaymentReceived,
          'change_amount': changeAmount,
          'customer_name': customerName,
          'parent_order_id': parentOrderId,
          'cashier_id': cashierId,
          'shift_id': shiftId,
          'notes': composeNotes(),
          'idempotency_key': localTxnId,
        };
        orderPayload = Map<String, dynamic>.from(payload);

        try {
          try {
            orderResponse = await supabase
                .from('orders')
                .insert(payload)
                .select()
                .single();
          } on PostgrestException catch (error) {
            if (error.message.toLowerCase().contains('idempotency_key')) {
              payload.remove('idempotency_key');
              orderResponse = await supabase
                  .from('orders')
                  .insert(payload)
                  .select()
                  .single();
            } else {
              rethrow;
            }
          }
          break;
        } on PostgrestException catch (error) {
          final isDuplicateId =
              error.code == '23505' &&
              error.message.toLowerCase().contains('id');
          if (!isDuplicateId || attempt == 4) {
            rethrow;
          }
        }
      }

      if (orderResponse == null) {
        throw Exception('Failed to create order id after retries');
      }

      final orderId = (orderResponse['id'] as num).toInt();
      final localOrderItems = _buildOfflineOrderItemCacheRows(orderId);

      orderItems = _items.values
          .map((item) {
            return {
              'order_id': orderId,
              'product_id': item.id,
              'quantity': item.quantity,
              'price_at_time': _lineUnitPrice(item),
              'modifiers': _serializeItemModifiers(item),
            };
          })
          .toList(growable: false);

      await supabase.from('order_items').insert(orderItems);
      final localOrderPayload = Map<String, dynamic>.from(orderResponse);
      await LocalOrderStoreRepository.instance.upsertOrder(localOrderPayload);
      await LocalOrderItemStoreRepository.instance.replaceForOrder(
        orderId: orderId,
        rows: localOrderItems,
      );

      if (shouldClearCart) {
        clearCart();
      }
      return orderId;
    } catch (_) {
      if (orderPayload == null) {
        final localOrderId = DateTime.now().millisecondsSinceEpoch;
        orderPayload = {
          'id': localOrderId,
          'total_price': normalizedTotal,
          'subtotal': normalizedTotal,
          'discount_total': 0,
          'points_earned': 0,
          'points_used': 0,
          'status': status,
          'type': orderType,
          'order_source': 'cashier',
          'payment_method': paymentMethod,
          'total_payment_received': totalPaymentReceived,
          'change_amount': changeAmount,
          'customer_name': customerName,
          'parent_order_id': parentOrderId,
          'cashier_id': cashierId,
          'shift_id': shiftId,
          'notes': composeNotes(),
          'idempotency_key': localTxnId,
        };
      }

      final offlineOrderId = (orderPayload['id'] as num?)?.toInt();
      if (offlineOrderId == null) {
        throw Exception('Unable to resolve local order id while offline');
      }

      final localOrderItems = _buildOfflineOrderItemCacheRows(offlineOrderId);

      if (orderItems.isEmpty) {
        orderItems = _items.values
            .map((item) {
              return {
                'order_id': offlineOrderId,
                'product_id': item.id,
                'quantity': item.quantity,
                'price_at_time': _lineUnitPrice(item),
                'modifiers': _serializeItemModifiers(item),
              };
            })
            .toList(growable: false);
      }

      final queuePayload = {
        'local_txn_id': localTxnId,
        'queued_at': DateTime.now().toIso8601String(),
        'order': orderPayload,
        'items': orderItems,
      };
      await _offlineRepo.enqueue(queuePayload);
      await _offlineRepo.addLog(
        level: 'info',
        message: 'Queued order#${orderPayload['id']} for sync',
        localTxnId: localTxnId,
        payload: queuePayload,
      );

      await LocalOrderStoreRepository.instance.upsertOrder(orderPayload);
      await LocalOrderItemStoreRepository.instance.replaceForOrder(
        orderId: offlineOrderId,
        rows: localOrderItems,
      );
      await _refreshOfflineCounters();
      notifyListeners();
      if (shouldClearCart) {
        clearCart();
      }
      return -1;
    }
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  void clearCart() {
    _items.clear();
    _totalAmount = 0;
    notifyListeners();
  }
}
