part of '../presentation/screens/cashier_screen.dart';

extension CashierControllerMethods on _ProductListScreenState {
  Future<List<Map<String, dynamic>>> _fetchOtherActiveOrders() async {
    if (_activeCashierId == null) {
      return const <Map<String, dynamic>>[];
    }

    try {
      final rows = await supabase
          .from('orders')
          .select(
            'id, customer_name, total_price, order_source, type, notes, cashier_id, shift_id, created_at',
          )
          .eq('status', 'active')
          .neq('id', _currentActiveOrderId ?? -1)
          .order('created_at', ascending: false);

      return (rows as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .where((row) {
            final rowCashierId = (row['cashier_id'] as num?)?.toInt();
            final rowShiftId = (row['shift_id'] as num?)?.toInt();
            final matchesShift = _activeShiftId == null
                ? true
                : rowShiftId == _activeShiftId;
            final fallbackLegacyCashierMatch =
                _activeShiftId != null &&
                rowShiftId == null &&
                rowCashierId == _activeCashierId;
            final matchesCashier = _activeShiftId == null
                ? rowCashierId == _activeCashierId
                : true;
            return (matchesShift && matchesCashier) ||
                fallbackLegacyCashierMatch;
          })
          .toList(growable: false);
    } catch (_) {
      return _cashierRepository.fetchOtherActiveOrders(
        excludedOrderId: _currentActiveOrderId,
        cashierId: _activeCashierId,
        shiftId: _activeShiftId,
      );
    }
  }

  Future<List<Map<String, dynamic>>> _fetchOrderItemRows(int orderId) async {
    try {
      final rows = await supabase
          .from('order_items')
          .select('id, product_id, quantity, price_at_time, modifiers')
          .eq('order_id', orderId);
      return (rows as List<dynamic>).whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      if (!_isOfflineMode) rethrow;
      final localRows =
          await LocalOrderItemStoreRepository.instance.fetchByOrderId(orderId);
      // Assign synthetic 1-based IDs so offline callers can use id-keyed maps.
      return localRows.asMap().entries.map((e) {
        final row = Map<String, dynamic>.from(e.value);
        row['id'] ??= e.key + 1;
        return row;
      }).toList();
    }
  }

  bool get _isOfflineMode {
    final cart = context.read<CartProvider>();
    return !cart.hasNetworkConnection || !cart.isServerReachable;
  }

  Map<String, dynamic> _cartItemToLocalRow(CartItem item, int orderId) {
    return {
      'order_id': orderId,
      'quantity': item.quantity,
      'product_id': item.id,
      'modifiers': item.modifiersData ?? item.modifiers?.toJson(),
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
    };
  }

  double _localModifierExtra(dynamic modifiersRaw) {
    if (modifiersRaw is! List) return 0;
    return modifiersRaw.whereType<Map<String, dynamic>>().fold<double>(0, (
      sum,
      modifier,
    ) {
      final selected =
          modifier['selected_options'] as List<dynamic>? ?? <dynamic>[];
      return sum +
          selected.whereType<Map<String, dynamic>>().fold<double>(
            0,
            (s, option) => s + ((option['price'] as num?)?.toDouble() ?? 0),
          );
    });
  }

  double _calculateTotalFromLocalRows(List<Map<String, dynamic>> rows) {
    var total = 0.0;
    for (final row in rows) {
      final qty = (row['quantity'] as num?)?.toDouble() ?? 0;
      final priceAtTime = (row['price_at_time'] as num?)?.toDouble();
      final basePrice =
          (row['products']?['price'] as num?)?.toDouble() ?? 0.0;
      final price =
          priceAtTime ?? (basePrice + _localModifierExtra(row['modifiers']));
      total += qty * price;
    }
    return total;
  }

  // Matches each cart item to a DB row by signature, returning rowId → moveQty.
  Map<int, int> _matchCartItemsToRowIds(
    List<CartItem> items,
    List<Map<String, dynamic>> rows,
    Map<String, int> moveQtys,
  ) {
    final rowBuckets = <String, List<int>>{};
    for (final row in rows) {
      final rowId = (row['id'] as num?)?.toInt();
      if (rowId == null) continue;
      rowBuckets.putIfAbsent(_orderItemRowSignature(row), () => []).add(rowId);
    }
    final result = <int, int>{};
    for (final item in items) {
      final moveQty = moveQtys[item.cartId] ?? item.quantity;
      if (moveQty <= 0) continue;
      final bucket = rowBuckets[_selectedCartItemSignature(item)];
      if (bucket == null || bucket.isEmpty) continue;
      result[bucket.removeAt(0)] = moveQty;
    }
    return result;
  }

  String _modifierSignature(dynamic rawModifiers) {
    final normalized = _normalizeRawModifiers(rawModifiers);
    // Treat null and empty collections identically — the DB stores NULL when
    // there are no modifiers, but the cart may carry an empty list or map.
    if (normalized == null ||
        (normalized is List && normalized.isEmpty) ||
        (normalized is Map && normalized.isEmpty)) {
      return 'null';
    }
    final canonical = _canonicalizeJsonValue(normalized);
    return jsonEncode(canonical);
  }

  String _orderItemRowSignature(Map<String, dynamic> row) {
    final productId = (row['product_id'] as num?)?.toInt() ?? 0;
    final quantity = (row['quantity'] as num?)?.toInt() ?? 0;
    final localProduct = row['products'] as Map<String, dynamic>?;
    final priceAtTime =
        (row['price_at_time'] as num?)?.toDouble() ??
        (localProduct?['price'] as num?)?.toDouble() ??
        0;

    return [
      productId,
      quantity,
      priceAtTime.toStringAsFixed(6),
      _modifierSignature(row['modifiers']),
    ].join('|');
  }

  String _selectedCartItemSignature(CartItem item) {
    final rawModifiers = item.modifiersData ?? item.modifiers?.toJson();
    // Use line price (base + modifier extras) to match what updateExistingOrder
    // stores as price_at_time, which _orderItemRowSignature also reads.
    final linePrice = item.price + _localModifierExtra(rawModifiers);
    return [
      item.id,
      item.quantity,
      linePrice.toStringAsFixed(6),
      _modifierSignature(rawModifiers),
    ].join('|');
  }

  Future<void> _recalculateAndPersistOrderTotals(int orderId) async {
    if (_isOfflineMode) {
      final localRows =
          await LocalOrderItemStoreRepository.instance.fetchByOrderId(orderId);
      final total = _calculateTotalFromLocalRows(localRows);
      final normalizedTotal = _normalizeNum(total);
      final allOrders =
          await LocalOrderStoreRepository.instance.fetchAllOrders();
      final existing = allOrders.firstWhere(
        (r) => ((r['id'] as num?)?.toInt() ?? -1) == orderId,
        orElse: () => <String, dynamic>{},
      );
      await LocalOrderStoreRepository.instance.upsertOrder({
        ...existing,
        'id': orderId,
        'total_price': normalizedTotal,
        'subtotal': normalizedTotal,
        'discount_total': 0,
      });
      return;
    }

    final rows = await supabase
        .from('order_items')
        .select('quantity, price_at_time')
        .eq('order_id', orderId);

    var total = 0.0;
    for (final row
        in (rows as List<dynamic>).whereType<Map<String, dynamic>>()) {
      final quantity = (row['quantity'] as num?)?.toDouble() ?? 0;
      final price = (row['price_at_time'] as num?)?.toDouble() ?? 0;
      total += quantity * price;
    }

    final normalizedTotal = _normalizeNum(total);

    await supabase
        .from('orders')
        .update({
          'total_price': normalizedTotal,
          'subtotal': normalizedTotal,
          'discount_total': 0,
        })
        .eq('id', orderId);

    try {
      final latest = await supabase
          .from('orders')
          .select()
          .eq('id', orderId)
          .maybeSingle();
      if (latest != null) {
        await LocalOrderStoreRepository.instance.upsertOrder(
          Map<String, dynamic>.from(latest),
        );
      }
    } catch (_) {}
  }

  Future<int> _generateDailyUniqueOrderId() async {
    final now = DateTime.now();
    final year = (now.year % 100).toString().padLeft(2, '0');
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final prefix = '$year$month$day';
    final prefixValue = int.parse(prefix);
    final minId = prefixValue * 1000;
    final maxId = minId + 999;

    final existingRows = await supabase
        .from('orders')
        .select('id')
        .gte('id', minId)
        .lte('id', maxId);

    final usedIds = (existingRows as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map((row) => int.tryParse(row['id'].toString()))
        .whereType<int>()
        .toSet();

    if (usedIds.length >= 1000) {
      throw Exception('Daily order id capacity exhausted for $prefix');
    }

    for (var suffix = 0; suffix < 1000; suffix++) {
      final candidate = minId + suffix;
      if (!usedIds.contains(candidate)) {
        return candidate;
      }
    }

    throw Exception('Unable to generate daily unique order id for $prefix');
  }

  Future<String?> _showCancelReasonDialog() async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Batal pesanan'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Alasan batal (opsional)',
              hintText: 'Contoh: Customer ubah pesanan',
            ),
            maxLines: 2,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Tutup'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('Konfirmasi'),
            ),
          ],
        );
      },
    );

    controller.dispose();
    return reason;
  }

  Future<void> _handleMergeBill() async {
    final cart = context.read<CartProvider>();
    if (cart.items.isEmpty && _currentActiveOrderId == null) {
      _showDropdownSnackbar('Cart kosong. Tidak ada item untuk digabung.');
      return;
    }

    final targetCandidates = await _fetchOtherActiveOrders();
    if (!mounted) return;
    if (targetCandidates.isEmpty) {
      _showDropdownSnackbar('Tidak ada order aktif tujuan gabung.');
      return;
    }

    final target = await _showSelectOrderDialog(
      title: 'Gabung ke order aktif',
      orders: targetCandidates,
    );
    if (!mounted || target == null) return;

    final targetOrderId = int.tryParse(target['id'].toString());
    if (targetOrderId == null) {
      _showDropdownSnackbar('Order tujuan tidak valid.');
      return;
    }

    // Ask whether to merge everything or let the user pick specific items.
    final mergeChoice = await _showMergeOptionsDialog();
    if (!mounted || mergeChoice == null) return;

    try {
      if (mergeChoice == 'all') {
        await _mergeAllToOrder(targetOrderId);
      } else {
        await _mergeSelectedToOrder(targetOrderId);
      }
    } catch (error) {
      if (!mounted) return;
      _showDropdownSnackbar('Gagal gabung nota: $error', isError: true);
      return;
    }

    if (!mounted) return;
    _showDropdownSnackbar('Berhasil digabung ke Order #$targetOrderId');
  }

  Future<String?> _showMergeOptionsDialog() {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Gabung Nota'),
        content: const Text(
          'Pilih cara penggabungan:',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Batal'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, 'select'),
            child: const Text('Pindah Beberapa Item'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'all'),
            child: const Text('Gabung Semua'),
          ),
        ],
      ),
    );
  }

  /// Moves ALL items from the current order/cart into [targetOrderId] and
  /// cancels the source order.
  Future<void> _mergeAllToOrder(int targetOrderId) async {
    final cart = context.read<CartProvider>();

    if (_currentActiveOrderId != null) {
      await cart.updateExistingOrder(
        orderId: _currentActiveOrderId!,
        customerName: _customerName,
        tableName: _tableName,
        orderType: _orderType,
      );

      final sourceRows = await _fetchOrderItemRows(_currentActiveOrderId!);
      await _mergeRowsIntoOrder(sourceRows, targetOrderId);
      await _recalculateAndPersistOrderTotals(targetOrderId);

      final mergedSourceId = _currentActiveOrderId!;
      final cancelNotes = _buildOrderNotes(
        tableName: _tableName,
        extraNote: 'Merged into Order #$targetOrderId',
      );

      if (_isOfflineMode) {
        // Queue target items replace and source cancel for sync.
        final newTargetRows =
            await LocalOrderItemStoreRepository.instance.fetchByOrderId(
              targetOrderId,
            );
        final targetTotal = _calculateTotalFromLocalRows(newTargetRows);
        final normTarget = _normalizeNum(targetTotal);
        await cart.enqueueOrderItemsReplace(
          orderId: targetOrderId,
          items: newTargetRows
              .map((r) => {
                    'order_id': targetOrderId,
                    'product_id': r['product_id'],
                    'quantity': r['quantity'],
                    'price_at_time': r['price_at_time'],
                    'modifiers': r['modifiers'],
                  })
              .toList(),
          orderUpdates: {
            'total_price': normTarget,
            'subtotal': normTarget,
            'discount_total': 0,
          },
        );
        await LocalOrderStoreRepository.instance.deleteOrder(mergedSourceId);
        await cart.enqueueOrderCancel(
          orderId: mergedSourceId,
          notes: cancelNotes,
        );
      } else {
        await supabase
            .from('orders')
            .update({'status': OrderStatus.cancelled, 'notes': cancelNotes})
            .eq('id', mergedSourceId);
        await LocalOrderStoreRepository.instance.deleteOrder(mergedSourceId);
      }

      _resetCurrentOrderDraft(showMessage: false);
    } else {
      // Draft mode — upsert cart items into target, merging qtys where possible.
      await _upsertCartItemsIntoOrder(
        targetOrderId: targetOrderId,
        items: cart.items.values,
      );
      await _recalculateAndPersistOrderTotals(targetOrderId);
      cart.clearCart();
    }
  }

  /// Moves [sourceRows] into [targetOrderId].
  ///
  /// [moveQtys] maps rowId → qty to move. When null every row is fully moved.
  /// For partial moves the source row qty is reduced in-place; for full moves
  /// the source row is deleted (online) or omitted from local cache (offline).
  ///
  /// Offline: updates the target's local item cache. Source row changes are
  /// the caller's responsibility.
  Future<void> _mergeRowsIntoOrder(
    List<Map<String, dynamic>> sourceRows,
    int targetOrderId, {
    Map<int, int>? moveQtys,
  }) async {
    final targetRows = await _fetchOrderItemRows(targetOrderId);

    final targetByKey = <String, Map<String, dynamic>>{};
    for (final row in targetRows) {
      final productId = (row['product_id'] as num?)?.toInt() ?? 0;
      final key = '$productId::${_modifierSignature(row['modifiers'])}';
      targetByKey[key] = row;
    }

    if (_isOfflineMode) {
      for (final sourceRow in sourceRows) {
        final sourceRowId = (sourceRow['id'] as num?)?.toInt();
        if (sourceRowId == null) continue;
        final sourceQty = (sourceRow['quantity'] as num?)?.toInt() ?? 0;
        final moveQty = moveQtys?[sourceRowId] ?? sourceQty;
        final productId = (sourceRow['product_id'] as num?)?.toInt() ?? 0;
        final key = '$productId::${_modifierSignature(sourceRow['modifiers'])}';
        final existing = targetByKey[key];
        final existingQty = (existing?['quantity'] as num?)?.toInt() ?? 0;
        targetByKey[key] = {
          ...(existing ?? {}),
          'order_id': targetOrderId,
          'product_id': productId,
          'quantity': existingQty + moveQty,
          'price_at_time':
              existing?['price_at_time'] ?? sourceRow['price_at_time'],
          'modifiers': existing?['modifiers'] ?? sourceRow['modifiers'],
          if (sourceRow.containsKey('products'))
            'products': sourceRow['products'],
        };
      }
      await LocalOrderItemStoreRepository.instance.replaceForOrder(
        orderId: targetOrderId,
        rows: targetByKey.values
            .map((r) => {...r, 'order_id': targetOrderId})
            .toList(),
      );
      return;
    }

    // Online path
    for (final sourceRow in sourceRows) {
      final sourceRowId = (sourceRow['id'] as num?)?.toInt();
      if (sourceRowId == null) continue;
      final sourceQty = (sourceRow['quantity'] as num?)?.toInt() ?? 0;
      final moveQty = moveQtys?[sourceRowId] ?? sourceQty;
      final isFullMove = moveQty >= sourceQty;
      final productId = (sourceRow['product_id'] as num?)?.toInt() ?? 0;
      final key = '$productId::${_modifierSignature(sourceRow['modifiers'])}';

      final existingTarget = targetByKey[key];
      if (existingTarget != null) {
        final targetRowId = (existingTarget['id'] as num?)?.toInt();
        if (targetRowId != null) {
          final newQty =
              ((existingTarget['quantity'] as num?)?.toInt() ?? 0) + moveQty;
          await supabase
              .from('order_items')
              .update({'quantity': newQty})
              .eq('id', targetRowId);
          targetByKey[key] = {...existingTarget, 'quantity': newQty};
        }
        if (isFullMove) {
          await supabase.from('order_items').delete().eq('id', sourceRowId);
        } else {
          await supabase
              .from('order_items')
              .update({'quantity': sourceQty - moveQty})
              .eq('id', sourceRowId);
        }
      } else {
        if (isFullMove) {
          await supabase
              .from('order_items')
              .update({'order_id': targetOrderId})
              .eq('id', sourceRowId);
          targetByKey[key] = {...sourceRow, 'order_id': targetOrderId};
        } else {
          await supabase
              .from('order_items')
              .update({'quantity': sourceQty - moveQty})
              .eq('id', sourceRowId);
          await supabase.from('order_items').insert({
            'order_id': targetOrderId,
            'product_id': productId,
            'quantity': moveQty,
            'price_at_time': sourceRow['price_at_time'],
            'modifiers': sourceRow['modifiers'],
          });
          targetByKey[key] = {
            'order_id': targetOrderId,
            'product_id': productId,
            'quantity': moveQty,
            'price_at_time': sourceRow['price_at_time'],
            'modifiers': sourceRow['modifiers'],
          };
        }
      }
    }
  }

  /// Inserts [items] into [targetOrderId], merging quantities for items that
  /// already exist in the target (same product + modifiers), creating a new
  /// line when modifiers differ.
  Future<void> _upsertCartItemsIntoOrder({
    required int targetOrderId,
    required Iterable<CartItem> items,
  }) async {
    final targetRows = await _fetchOrderItemRows(targetOrderId);

    final targetByKey = <String, Map<String, dynamic>>{};
    for (final row in targetRows) {
      final productId = (row['product_id'] as num?)?.toInt() ?? 0;
      final key = '$productId::${_modifierSignature(row['modifiers'])}';
      targetByKey[key] = row;
    }

    if (_isOfflineMode) {
      for (final item in items) {
        final rawModifiers = item.modifiersData ?? item.modifiers?.toJson();
        final key = '${item.id}::${_modifierSignature(rawModifiers)}';
        final linePrice = item.price + _localModifierExtra(rawModifiers);
        final existing = targetByKey[key];
        final existingQty = (existing?['quantity'] as num?)?.toInt() ?? 0;
        targetByKey[key] = {
          ...(existing ?? {}),
          'order_id': targetOrderId,
          'product_id': item.id,
          'quantity': existingQty + item.quantity,
          'price_at_time': existing?['price_at_time'] ?? linePrice,
          'modifiers': rawModifiers,
        };
      }
      await LocalOrderItemStoreRepository.instance.replaceForOrder(
        orderId: targetOrderId,
        rows: targetByKey.values
            .map((r) => {...r, 'order_id': targetOrderId})
            .toList(),
      );
      return;
    }

    final toInsert = <Map<String, dynamic>>[];
    for (final item in items) {
      final rawModifiers = item.modifiersData ?? item.modifiers?.toJson();
      final key = '${item.id}::${_modifierSignature(rawModifiers)}';
      final linePrice = item.price + _localModifierExtra(rawModifiers);

      final existing = targetByKey[key];
      if (existing != null) {
        final targetRowId = (existing['id'] as num?)?.toInt();
        if (targetRowId != null) {
          final newQty =
              ((existing['quantity'] as num?)?.toInt() ?? 0) + item.quantity;
          await supabase
              .from('order_items')
              .update({'quantity': newQty})
              .eq('id', targetRowId);
          targetByKey[key] = {...existing, 'quantity': newQty};
        }
      } else {
        toInsert.add({
          'order_id': targetOrderId,
          'product_id': item.id,
          'quantity': item.quantity,
          'price_at_time': linePrice,
          'modifiers': rawModifiers,
        });
        targetByKey[key] = {
          'product_id': item.id,
          'quantity': item.quantity,
          'price_at_time': linePrice,
          'modifiers': rawModifiers,
        };
      }
    }

    if (toInsert.isNotEmpty) {
      await supabase.from('order_items').insert(toInsert);
    }
  }

  /// Shows an item-selection dialog (with qty control) so the user can pick
  /// which items — and how many — to move into [targetOrderId].
  Future<void> _mergeSelectedToOrder(int targetOrderId) async {
    final cart = context.read<CartProvider>();
    final allItems = cart.items.values.toList(growable: false);
    if (allItems.isEmpty) return;

    // Returns Map<cartId, moveQty>
    final moveQtys = await _showMergeItemSelectionDialog(allItems);
    if (!mounted || moveQtys == null || moveQtys.isEmpty) return;

    final selectedItems = allItems
        .where((item) => moveQtys.containsKey(item.cartId))
        .toList(growable: false);

    if (_currentActiveOrderId != null) {
      await cart.updateExistingOrder(
        orderId: _currentActiveOrderId!,
        customerName: _customerName,
        tableName: _tableName,
        orderType: _orderType,
      );

      final rows = await _fetchOrderItemRows(_currentActiveOrderId!);

      // Match each selected cart item to its DB row, respecting move qty.
      final rowMoves = _matchCartItemsToRowIds(selectedItems, rows, moveQtys);
      if (rowMoves.isEmpty) {
        throw Exception('Tidak menemukan item yang dipilih di database.');
      }

      final selectedRows = rows
          .where((r) => rowMoves.containsKey((r['id'] as num?)?.toInt()))
          .toList(growable: false);

      await _mergeRowsIntoOrder(
        selectedRows,
        targetOrderId,
        moveQtys: rowMoves,
      );

      if (_isOfflineMode) {
        // Build the updated source item list after the move.
        final updatedSourceRows = <Map<String, dynamic>>[];
        for (final row in rows) {
          final rowId = (row['id'] as num?)?.toInt();
          if (rowId == null) continue;
          final origQty = (row['quantity'] as num?)?.toInt() ?? 0;
          final moved = rowMoves[rowId] ?? 0;
          final remaining = origQty - moved;
          if (remaining > 0) {
            updatedSourceRows.add({...row, 'quantity': remaining});
          }
        }
        await LocalOrderItemStoreRepository.instance.replaceForOrder(
          orderId: _currentActiveOrderId!,
          rows: updatedSourceRows
              .map((r) => {...r, 'order_id': _currentActiveOrderId!})
              .toList(),
        );

        // Queue both orders for sync.
        final newSrcRows =
            await LocalOrderItemStoreRepository.instance.fetchByOrderId(
              _currentActiveOrderId!,
            );
        final srcTotal = _calculateTotalFromLocalRows(newSrcRows);
        final normSrc = _normalizeNum(srcTotal);

        final newTgtRows =
            await LocalOrderItemStoreRepository.instance.fetchByOrderId(
              targetOrderId,
            );
        final tgtTotal = _calculateTotalFromLocalRows(newTgtRows);
        final normTgt = _normalizeNum(tgtTotal);

        await cart.enqueueOrderItemsReplace(
          orderId: targetOrderId,
          items: newTgtRows
              .map((r) => {
                    'order_id': targetOrderId,
                    'product_id': r['product_id'],
                    'quantity': r['quantity'],
                    'price_at_time': r['price_at_time'],
                    'modifiers': r['modifiers'],
                  })
              .toList(),
          orderUpdates: {
            'total_price': normTgt,
            'subtotal': normTgt,
            'discount_total': 0,
          },
        );

        if (newSrcRows.isEmpty) {
          final allOrders =
              await LocalOrderStoreRepository.instance.fetchAllOrders();
          final src = allOrders.firstWhere(
            (r) => ((r['id'] as num?)?.toInt() ?? -1) == _currentActiveOrderId,
            orElse: () => <String, dynamic>{},
          );
          final cancelNotes = _buildOrderNotes(
            tableName: _tableNameFromNotes(src['notes']?.toString()),
            extraNote: 'Partially merged into Order #$targetOrderId',
          );
          await LocalOrderStoreRepository.instance.deleteOrder(
            _currentActiveOrderId!,
          );
          await cart.enqueueOrderCancel(
            orderId: _currentActiveOrderId!,
            notes: cancelNotes,
          );
          _resetCurrentOrderDraft(showMessage: false);
          return;
        }

        await cart.enqueueOrderItemsReplace(
          orderId: _currentActiveOrderId!,
          items: newSrcRows
              .map((r) => {
                    'order_id': _currentActiveOrderId!,
                    'product_id': r['product_id'],
                    'quantity': r['quantity'],
                    'price_at_time': r['price_at_time'],
                    'modifiers': r['modifiers'],
                  })
              .toList(),
          orderUpdates: {
            'total_price': normSrc,
            'subtotal': normSrc,
            'discount_total': 0,
          },
        );
        await _recalculateAndPersistOrderTotals(_currentActiveOrderId!);
        await _recalculateAndPersistOrderTotals(targetOrderId);
        await _reloadCurrentOrderCart();
        return;
      }

      await _recalculateAndPersistOrderTotals(_currentActiveOrderId!);
      await _recalculateAndPersistOrderTotals(targetOrderId);

      final sourceCancelled = await _cancelSourceIfNoRemainingItems(
        _currentActiveOrderId!,
        extraNote: 'Partially merged into Order #$targetOrderId',
      );
      if (sourceCancelled) {
        _resetCurrentOrderDraft(showMessage: false);
      } else {
        await _reloadCurrentOrderCart();
      }
    } else {
      // Draft mode — upsert selected items into target, merging qtys where possible.
      // For partial qty, honour the user's chosen move qty.
      final partialItems = selectedItems.map((item) {
        final mq = moveQtys[item.cartId] ?? item.quantity;
        if (mq == item.quantity) return item;
        return CartItem(
          id: item.id,
          name: item.name,
          price: item.price,
          category: item.category,
          description: item.description,
          imageUrl: item.imageUrl,
          isAvailable: item.isAvailable,
          isBundle: item.isBundle,
          isRecommended: item.isRecommended,
          productBundles: item.productBundles,
          cartId: item.cartId,
          quantity: mq,
          modifiers: item.modifiers,
          modifiersData: item.modifiersData,
        );
      }).toList(growable: false);

      await _upsertCartItemsIntoOrder(
        targetOrderId: targetOrderId,
        items: partialItems,
      );
      await _recalculateAndPersistOrderTotals(targetOrderId);

      for (final item in selectedItems) {
        final mq = moveQtys[item.cartId] ?? item.quantity;
        final key = cart.items.entries
            .firstWhere((e) => e.value.cartId == item.cartId)
            .key;
        if (mq >= item.quantity) {
          cart.removeItem(key);
        } else {
          cart.replaceItem(
            existingKey: key,
            product: Product(
              id: item.id,
              name: item.name,
              price: item.price,
              category: item.category,
              description: item.description,
              imageUrl: item.imageUrl,
              isAvailable: item.isAvailable,
              isBundle: item.isBundle,
              isRecommended: item.isRecommended,
              productBundles: item.productBundles,
              productModifiers: item.productModifiers,
            ),
            quantity: item.quantity - mq,
            modifiers: item.modifiers,
            modifiersData: item.modifiersData,
          );
        }
      }
    }
  }

  /// Reloads the cart from Supabase for the current active order.
  /// Unlike [_switchToActiveOrder], this does not check for "already active"
  /// and is used after operations that mutate the current order's items in DB.
  Future<void> _reloadCurrentOrderCart() async {
    if (_currentActiveOrderId == null || !mounted) return;
    final cart = context.read<CartProvider>();
    final items = await _fetchOrderItems(_currentActiveOrderId!);
    if (!mounted) return;
    cart.clearCart();
    for (final item in items) {
      cart.addItem(
        item.product,
        quantity: item.quantity,
        modifiers: item.modifiers,
        modifiersData: item.modifiersData,
      );
    }
  }

  Future<Map<String, int>?> _showMergeItemSelectionDialog(
    List<CartItem> items,
  ) async {
    // Map<cartId, moveQty>; an entry means item is selected.
    final moveQtys = <String, int>{};

    return showDialog<Map<String, int>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, setDialogState) => AlertDialog(
          title: const Text('Pilih item yang ingin dipindah'),
          content: SizedBox(
            width: 400,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: items.length,
              itemBuilder: (_, index) {
                final item = items[index];
                final isSelected = moveQtys.containsKey(item.cartId);
                final currentQty = moveQtys[item.cartId] ?? 1;
                final linePrice =
                    item.price + _modifierExtraFromData(item.modifiersData);
                final modNames = (item.modifiersData ?? const <dynamic>[])
                    .whereType<Map<String, dynamic>>()
                    .expand((mod) {
                      final opts =
                          mod['selected_options'] as List<dynamic>? ??
                          const [];
                      return opts
                          .whereType<Map<String, dynamic>>()
                          .map((o) => o['name']?.toString() ?? '')
                          .where((n) => n.isNotEmpty);
                    })
                    .join(', ');
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CheckboxListTile(
                      title: Text(item.name),
                      subtitle: Text(
                        '${_formatRupiah(linePrice)}'
                        '${modNames.isNotEmpty ? '\n$modNames' : ''}',
                        maxLines: 2,
                      ),
                      value: isSelected,
                      onChanged: (checked) => setDialogState(() {
                        if (checked == true) {
                          moveQtys[item.cartId] = item.quantity;
                        } else {
                          moveQtys.remove(item.cartId);
                        }
                      }),
                    ),
                    if (isSelected && item.quantity > 1)
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 16,
                          right: 16,
                          bottom: 8,
                        ),
                        child: Row(
                          children: [
                            const SizedBox(width: 40),
                            const Text('Qty:'),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: currentQty > 1
                                  ? () => setDialogState(() {
                                      moveQtys[item.cartId] = currentQty - 1;
                                    })
                                  : null,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '$currentQty',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed: currentQty < item.quantity
                                  ? () => setDialogState(() {
                                      moveQtys[item.cartId] = currentQty + 1;
                                    })
                                  : null,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '/ ${item.quantity}',
                              style: const TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: moveQtys.isEmpty
                  ? null
                  : () => Navigator.pop(
                      dialogContext,
                      Map<String, int>.from(moveQtys),
                    ),
              child: const Text('Pindah'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleSplitBill() async {
    if (_currentActiveOrderId == null) {
      _showDropdownSnackbar(
        'Pisah nota membutuhkan order aktif. Simpan order dulu lalu coba lagi.',
      );
      return;
    }

    // Clear any leftover groups before opening the split screen so the user
    // starts fresh each time.
    if (!mounted) return;
    context.read<CartProvider>().clearGroups();

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SplitBillScreen(
          onConfirmSplit: _processSplitFromGroups,
        ),
      ),
    );
  }

  /// Called by SplitBillScreen when the user confirms the group-based split.
  /// Creates one new active order per group and moves the assigned items into
  /// those new orders. Unassigned items stay in the source order.
  Future<bool> _processSplitFromGroups() async {
    final sourceOrderId = _currentActiveOrderId;
    if (sourceOrderId == null) {
      _showDropdownSnackbar('Tidak ada order aktif.', isError: true);
      return false;
    }

    final cart = context.read<CartProvider>();
    final groups = List<CartGroup>.from(cart.cartGroups);
    final groupItems = List<GroupItem>.from(cart.groupItems);

    final activeGroups = groups
        .where(
          (g) => groupItems.any((gi) => gi.groupId == g.id && gi.assignedQty > 0),
        )
        .toList(growable: false);

    if (activeGroups.isEmpty) {
      _showDropdownSnackbar(
        'Tetapkan item ke grup terlebih dahulu.',
        isError: true,
      );
      return false;
    }

    final isOffline = _isOfflineMode;

    try {
      // Persist cart to source order before touching DB rows.
      await cart.updateExistingOrder(
        orderId: sourceOrderId,
        customerName: _customerName,
        tableName: _tableName,
        orderType: _orderType,
      );

      final sourceRows = await _fetchOrderItemRows(sourceOrderId);
      if (sourceRows.isEmpty) {
        throw Exception('Item pada order sumber tidak ditemukan.');
      }

      // remainingQty tracks how many units of each DB row are still in source.
      final remainingQty = <int, int>{};
      final rowsByProductId = <int, List<Map<String, dynamic>>>{};
      for (final row in sourceRows) {
        final rowId = (row['id'] as num?)?.toInt();
        final productId = (row['product_id'] as num?)?.toInt();
        if (rowId == null || productId == null) continue;
        remainingQty[rowId] = (row['quantity'] as num?)?.toInt() ?? 0;
        rowsByProductId.putIfAbsent(productId, () => []).add(row);
      }

      // For offline queuing: collect (orderRow, itemRows) per new order.
      final newOrderRowsForQueue = <Map<String, dynamic>>[];
      final newItemsForQueue = <List<Map<String, dynamic>>>[];

      for (final group in activeGroups) {
        final lines = groupItems
            .where((gi) => gi.groupId == group.id && gi.assignedQty > 0)
            .toList(growable: false);
        if (lines.isEmpty) continue;

        // Collect item rows in memory before persisting.
        final newItemRows = <Map<String, dynamic>>[];
        for (final gi in lines) {
          int qtyLeft = gi.assignedQty;
          final candidateRows = rowsByProductId[gi.orderItemId] ?? [];
          for (final row in candidateRows) {
            if (qtyLeft <= 0) break;
            final rowId = (row['id'] as num?)?.toInt();
            if (rowId == null) continue;
            final available = remainingQty[rowId] ?? 0;
            if (available <= 0) continue;
            final take = min(qtyLeft, available);
            remainingQty[rowId] = available - take;
            qtyLeft -= take;
            newItemRows.add({
              'product_id': row['product_id'],
              'quantity': take,
              'price_at_time': row['price_at_time'],
              'modifiers': row['modifiers'],
              // Preserve joined product data for the local cache so the order
              // detail view can display items without a network round-trip.
              if (row['products'] != null) 'products': row['products'],
            });
          }
        }

        final newOrderId = await _createActiveOrderDraft(
          orderType: _orderType,
          customerName: _customerName,
          tableName: _tableName,
          parentOrderId: sourceOrderId,
        );

        if (isOffline) {
          await LocalOrderItemStoreRepository.instance.replaceForOrder(
            orderId: newOrderId,
            rows: newItemRows
                .map((r) => {...r, 'order_id': newOrderId})
                .toList(),
          );
          final allOrders =
              await LocalOrderStoreRepository.instance.fetchAllOrders();
          final orderRow = allOrders.firstWhere(
            (r) => ((r['id'] as num?)?.toInt() ?? -1) == newOrderId,
            orElse: () => <String, dynamic>{'id': newOrderId},
          );
          newOrderRowsForQueue.add(orderRow);
          // Strip joined data before queueing — Supabase insert does not
          // accept the 'products' key (it's a foreign-table join alias).
          newItemsForQueue.add(
            newItemRows
                .map((r) => Map<String, dynamic>.from(r)..remove('products'))
                .toList(),
          );
        } else {
          for (final row in newItemRows) {
            await supabase.from('order_items').insert({
              ...row,
              'order_id': newOrderId,
            });
          }
        }

        await _recalculateAndPersistOrderTotals(newOrderId);
      }

      if (isOffline) {
        // Save updated source items to local store.
        final updatedSourceRows = <Map<String, dynamic>>[];
        for (final row in sourceRows) {
          final rowId = (row['id'] as num?)?.toInt();
          if (rowId == null) continue;
          final remaining = remainingQty[rowId] ?? 0;
          if (remaining > 0) {
            updatedSourceRows.add({
              ...row,
              'quantity': remaining,
              'order_id': sourceOrderId,
            });
          }
        }
        await LocalOrderItemStoreRepository.instance.replaceForOrder(
          orderId: sourceOrderId,
          rows: updatedSourceRows,
        );

        // Queue all new orders.
        for (var i = 0; i < newOrderRowsForQueue.length; i++) {
          await cart.enqueueNewOrder(
            order: newOrderRowsForQueue[i],
            items: newItemsForQueue[i],
          );
        }

        // Queue source update only if it won't be cancelled (checked below).
        final srcRemaining =
            await LocalOrderItemStoreRepository.instance.fetchByOrderId(
          sourceOrderId,
        );
        if (srcRemaining.isNotEmpty) {
          final srcTotal = _calculateTotalFromLocalRows(srcRemaining);
          await cart.enqueueOrderItemsReplace(
            orderId: sourceOrderId,
            items: updatedSourceRows,
            orderUpdates: {
              'total_price': _normalizeNum(srcTotal),
              'subtotal': _normalizeNum(srcTotal),
            },
          );
        }
      } else {
        // Online: update source rows in Supabase.
        for (final row in sourceRows) {
          final rowId = (row['id'] as num?)?.toInt();
          if (rowId == null) continue;
          final original = (row['quantity'] as num?)?.toInt() ?? 0;
          final remaining = remainingQty[rowId] ?? 0;
          if (remaining <= 0) {
            await supabase.from('order_items').delete().eq('id', rowId);
          } else if (remaining < original) {
            await supabase
                .from('order_items')
                .update({'quantity': remaining})
                .eq('id', rowId);
          }
        }
      }

      await _recalculateAndPersistOrderTotals(sourceOrderId);

      final sourceCancelled = await _cancelSourceIfNoRemainingItems(
        sourceOrderId,
        extraNote: 'Items split to new orders',
      );

      cart.clearGroups();

      if (!mounted) return true;

      if (sourceCancelled) {
        _resetCurrentOrderDraft(showMessage: false);
      } else {
        await _reloadCurrentOrderCart();
      }

      if (!mounted) return true;
      setState(() {
        _selectedCartItems.clear();
        _isCartSelectionMode = false;
      });

      _showDropdownSnackbar('Nota berhasil dipisah.');
      return true;
    } catch (error) {
      if (!mounted) return false;
      _showDropdownSnackbar('Gagal pisah nota: $error', isError: true);
      return false;
    }
  }

  Future<void> _handleCancelOrder() async {
    final cancelReason = await _showCancelReasonDialog();
    if (!mounted || cancelReason == null) {
      return;
    }

    if (_currentActiveOrderId != null) {
      try {
        final reasonText = cancelReason.trim().isEmpty
            ? 'Cancelled from cashier app'
            : 'Cancel reason: ${cancelReason.trim()}';

        await supabase
            .from('orders')
            .update({
              'status': OrderStatus.cancelled,
              'notes': _buildOrderNotes(
                tableName: _tableName,
                extraNote: reasonText,
              ),
            })
            .eq('id', _currentActiveOrderId!);

        // Remove from local store so it no longer shows in active-order lists.
        await LocalOrderStoreRepository.instance.deleteOrder(
          _currentActiveOrderId!,
        );
      } catch (error) {
        if (!mounted) return;
        _showDropdownSnackbar('Gagal batal pesanan: $error', isError: true);
        return;
      }
    }

    if (!mounted) return;
    _resetCurrentOrderDraft(showMessage: false);
    _showDropdownSnackbar('Pesanan dibatalkan');
  }

  void _resetCurrentOrderDraft({bool showMessage = true}) {
    context.read<CartProvider>().clearCart();
    setState(() {
      _customerName = null;
      _tableName = null;
      _orderType = 'dine_in';
      _currentActiveOrderId = null;
      _currentOrderMetadata = null;
      _isOnlinePaidOrderInCart = false;
      _selectedCartItems.clear();
      _isCartSelectionMode = false;
      _pendingParentOrderIdForNextSubmit = null;
    });

    if (showMessage) {
      _showDropdownSnackbar('Cart dan detail order di-reset');
    }
  }

  Future<_PaymentResult?> _showPaymentMethodModal(double totalAmount) async {
    var paymentMethod = 'cash';
    var cashInput = '';

    num parseCashInput() {
      if (cashInput.isEmpty) return 0;
      return num.tryParse(cashInput) ?? 0;
    }

    return showDialog<_PaymentResult>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            final cashPaid = parseCashInput();
            final change = cashPaid - totalAmount;
            final normalizedTotal = totalAmount % 1 == 0
                ? totalAmount.toInt()
                : totalAmount;

            void onCalculatorTap(String value) {
              setState(() {
                if (value == 'clear') {
                  cashInput = '';
                  return;
                }

                if (value == 'exact') {
                  cashInput = normalizedTotal.toString();
                  return;
                }

                if (cashInput.length >= 9) return;
                if (cashInput == '0') {
                  cashInput = value;
                } else {
                  cashInput += value;
                }
              });
            }

            Widget calculatorButton({
              required String label,
              required VoidCallback onTap,
              Color? backgroundColor,
              Color? foregroundColor,
            }) {
              return SizedBox(
                height: 20,
                child: ElevatedButton(
                  onPressed: onTap,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: backgroundColor,
                    foregroundColor: foregroundColor,
                    textStyle: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: Text(label),
                ),
              );
            }

            return AlertDialog(
              title: const Text('Payment Method'),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'cash', label: Text('Cash')),
                        ButtonSegment(value: 'qris', label: Text('QRIS')),
                      ],
                      selected: {paymentMethod},
                      onSelectionChanged: (selection) {
                        setState(() {
                          paymentMethod = selection.first;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    if (paymentMethod == 'cash') ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              _formatRupiah(totalAmount),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _formatRupiah(cashPaid),
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 6),
                              child: Divider(height: 1),
                            ),
                            Text(
                              _formatRupiah(change.clamp(0, double.infinity)),
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: change >= 0
                                    ? Colors.green.shade700
                                    : Colors.red.shade700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      GridView.count(
                        crossAxisCount: 3,
                        shrinkWrap: true,
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 6,
                        childAspectRatio: 2.5,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          calculatorButton(
                            label: '1',
                            onTap: () => onCalculatorTap('1'),
                          ),
                          calculatorButton(
                            label: '2',
                            onTap: () => onCalculatorTap('2'),
                          ),
                          calculatorButton(
                            label: '3',
                            onTap: () => onCalculatorTap('3'),
                          ),
                          calculatorButton(
                            label: '4',
                            onTap: () => onCalculatorTap('4'),
                          ),
                          calculatorButton(
                            label: '5',
                            onTap: () => onCalculatorTap('5'),
                          ),
                          calculatorButton(
                            label: '6',
                            onTap: () => onCalculatorTap('6'),
                          ),
                          calculatorButton(
                            label: '7',
                            onTap: () => onCalculatorTap('7'),
                          ),
                          calculatorButton(
                            label: '8',
                            onTap: () => onCalculatorTap('8'),
                          ),
                          calculatorButton(
                            label: '9',
                            onTap: () => onCalculatorTap('9'),
                          ),
                          calculatorButton(
                            label: 'C',
                            onTap: () => onCalculatorTap('clear'),
                            backgroundColor: Colors.orange.shade100,
                            foregroundColor: Colors.orange.shade800,
                          ),
                          calculatorButton(
                            label: '0',
                            onTap: () => onCalculatorTap('0'),
                          ),
                          calculatorButton(
                            label: 'Uang Pas',
                            onTap: () => onCalculatorTap('exact'),
                            backgroundColor: Colors.green.shade100,
                            foregroundColor: Colors.green.shade800,
                          ),
                        ],
                      ),
                    ] else ...[
                      Text(
                        'Total: ${_formatRupiah(totalAmount)}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        height: 180,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                          color: Colors.grey.shade100,
                        ),
                        child: const Text(
                          'QRIS image placeholder (akan diisi nanti)',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: paymentMethod == 'cash' && cashPaid < totalAmount
                      ? null
                      : () {
                          final totalPaymentReceived = paymentMethod == 'cash'
                              ? cashPaid
                              : normalizedTotal;
                          final changeAmount = paymentMethod == 'cash'
                              ? (cashPaid - totalAmount)
                              : 0;

                          Navigator.of(dialogContext).pop(
                            _PaymentResult(
                              method: paymentMethod,
                              totalPaymentReceived: totalPaymentReceived,
                              changeAmount: changeAmount,
                            ),
                          );
                        },
                  child: const Text('Confirm Payment'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showActiveCashierOrdersDialog() async {
    int? selectedOrderId;
    final ScrollController activeOrdersScrollController = ScrollController();
    bool isSwitching = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Switch Active Order'),
              content: SizedBox(
                width: 900,
                height: 560,
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: _activeOrdersStream,
                  builder: (context, snapshot) {
                    final activeOrders =
                        snapshot.data ?? <Map<String, dynamic>>[];
                    final listedOrders =
                        List<Map<String, dynamic>>.from(activeOrders)
                          ..sort((a, b) {
                            final aTime = DateTime.tryParse(
                              (a['created_at'] ?? '').toString(),
                            );
                            final bTime = DateTime.tryParse(
                              (b['created_at'] ?? '').toString(),
                            );
                            if (aTime == null && bTime == null) {
                              final aId = (a['id'] as num?)?.toInt() ?? 0;
                              final bId = (b['id'] as num?)?.toInt() ?? 0;
                              return bId.compareTo(aId);
                            }
                            if (aTime == null) return 1;
                            if (bTime == null) return -1;
                            return bTime.compareTo(aTime);
                          });

                    if (selectedOrderId != null &&
                        listedOrders.every(
                          (order) =>
                              (order['id'] as num?)?.toInt() != selectedOrderId,
                        )) {
                      selectedOrderId = null;
                    }
                    selectedOrderId ??= listedOrders.isEmpty
                        ? null
                        : (listedOrders.first['id'] as num?)?.toInt();

                    final selectedOrder = selectedOrderId == null
                        ? null
                        : listedOrders.firstWhere(
                            (order) =>
                                (order['id'] as num?)?.toInt() ==
                                selectedOrderId,
                            orElse: () => <String, dynamic>{},
                          );

                    if (snapshot.connectionState == ConnectionState.waiting &&
                        listedOrders.isEmpty) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    if (listedOrders.isEmpty) {
                      return const Center(child: Text('No active orders.'));
                    }

                    return Row(
                      children: [
                        Container(
                          width: 380,
                          decoration: BoxDecoration(
                            border: Border(
                              right: BorderSide(color: Colors.blue.shade100),
                            ),
                          ),
                          child: ListView.separated(
                            controller: activeOrdersScrollController,
                            itemCount: listedOrders.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final order = listedOrders[index];
                              final orderId = (order['id'] as num?)?.toInt();
                              final isSelected =
                                  orderId != null && orderId == selectedOrderId;
                              final isCurrentInCart =
                                  orderId != null &&
                                  orderId == _currentActiveOrderId;
                              final customerName =
                                  order['customer_name']
                                          ?.toString()
                                          .trim()
                                          .isNotEmpty ==
                                      true
                                  ? order['customer_name'].toString()
                                  : 'Guest';
                              final total =
                                  (order['total_price'] as num?) ??
                                  (order['total_amount'] as num?) ??
                                  0;
                              final source =
                                  order['order_source']
                                      ?.toString()
                                      .toUpperCase() ??
                                  '-';
                              final orderTime = _onlineTimeLabel(
                                order['created_at'],
                              );

                              return ListTile(
                                selected: isSelected,
                                title: Row(
                                  children: [
                                    Expanded(
                                      child: Text('Order #${order['id']}'),
                                    ),
                                    if (isCurrentInCart)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.teal.withOpacity(0.12),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: const Text(
                                          'IN CART',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                subtitle: Text(
                                  '$customerName\nTotal: ${_formatRupiah(total)} • $source • $orderTime',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: orderId == null
                                    ? null
                                    : () => setDialogState(() {
                                        selectedOrderId = orderId;
                                      }),
                              );
                            },
                          ),
                        ),
                        Expanded(
                          child: selectedOrder == null || selectedOrder.isEmpty
                              ? const Center(
                                  child: Text(
                                    'Select an order to see details.',
                                  ),
                                )
                              : FutureBuilder<List<_OnlineOrderItem>>(
                                  future: _fetchOrderItems(
                                    (selectedOrder['id'] as num).toInt(),
                                    orderSnapshot: selectedOrder,
                                  ),
                                  builder: (context, detailSnapshot) {
                                    final items =
                                        detailSnapshot.data ??
                                        <_OnlineOrderItem>[];
                                    final total =
                                        (selectedOrder['total_price']
                                            as num?) ??
                                        (selectedOrder['total_amount']
                                            as num?) ??
                                        0;
                                    final orderNotes =
                                        selectedOrder['notes']?.toString() ??
                                        '';
                                    return Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Order #${selectedOrder['id']} • ${selectedOrder['customer_name'] ?? 'Guest'}',
                                            style: const TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            'Source: ${(selectedOrder['order_source'] ?? '-').toString().toUpperCase()}',
                                            style: TextStyle(
                                              color: Colors.blue.shade700,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'Total: ${_formatRupiah(total)}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          if (orderNotes.trim().isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 8,
                                              ),
                                              child: Text(
                                                'Notes: $orderNotes',
                                                style: TextStyle(
                                                  color: Colors.grey.shade700,
                                                ),
                                              ),
                                            ),
                                          const SizedBox(height: 12),
                                          Expanded(
                                            child:
                                                detailSnapshot
                                                            .connectionState ==
                                                        ConnectionState
                                                            .waiting &&
                                                    items.isEmpty
                                                ? const Center(
                                                    child:
                                                        CircularProgressIndicator(),
                                                  )
                                                : items.isEmpty
                                                ? const Center(
                                                    child: Text(
                                                      'No order items found.',
                                                    ),
                                                  )
                                                : ListView.separated(
                                                    itemCount: items.length,
                                                    separatorBuilder: (_, __) =>
                                                        const Divider(),
                                                    itemBuilder: (_, index) {
                                                      final item = items[index];
                                                      final itemTotal =
                                                          ((item.product.price +
                                                                      _modifierExtraFromData(
                                                                        item.modifiersData,
                                                                      )) *
                                                                  item.quantity)
                                                              .toDouble();
                                                      return ListTile(
                                                        title: Text(
                                                          item.product.name,
                                                        ),
                                                        subtitle: Text(
                                                          _onlineOrderItemSubtitle(
                                                            item,
                                                          ),
                                                        ),
                                                        trailing: Text(
                                                          _formatRupiah(
                                                            itemTotal,
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                          ),
                                          const SizedBox(height: 12),
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.end,
                                            children: [
                                              OutlinedButton(
                                                onPressed: () => Navigator.of(
                                                  dialogContext,
                                                ).pop(),
                                                child: const Text('Close'),
                                              ),
                                              const SizedBox(width: 8),
                                              ElevatedButton(
                                                onPressed: isSwitching
                                                    ? null
                                                    : () async {
                                                        setDialogState(
                                                          () => isSwitching =
                                                              true,
                                                        ); // Disable button

                                                        try {
                                                          final canContinue =
                                                              await _handleDraftBeforeSwitch(
                                                                dialogContext,
                                                              );
                                                          if (!canContinue ||
                                                              !context.mounted)
                                                            return;

                                                          await _switchToActiveOrder(
                                                            selectedOrder,
                                                          );
                                                          if (!context.mounted)
                                                            return;
                                                          Navigator.of(
                                                            dialogContext,
                                                          ).pop();
                                                        } finally {
                                                          if (context.mounted) {
                                                            setDialogState(
                                                              () =>
                                                                  isSwitching =
                                                                      false,
                                                            );
                                                          }
                                                        }
                                                      },
                                                child: isSwitching
                                                    ? const SizedBox(
                                                        width: 16,
                                                        height: 16,
                                                        child:
                                                            CircularProgressIndicator(
                                                              strokeWidth: 2,
                                                            ),
                                                      )
                                                    : const Text(
                                                        'Switch to this order',
                                                      ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    );
    activeOrdersScrollController.dispose();
  }

  Future<bool> _handleDraftBeforeSwitch(BuildContext dialogContext) async {
    final cart = context.read<CartProvider>();

    if (_currentActiveOrderId != null) {
      try {
        await cart.updateExistingOrder(
          orderId: _currentActiveOrderId!,
          customerName: _customerName,
          tableName: _tableName,
          orderType: _orderType,
        );
      } catch (error) {
        if (!mounted) return false;
        _showDropdownSnackbar(
          'Failed to update current order: $error',
          isError: true,
        );
        return false;
      }

      if (!mounted) return false;
      setState(() {
        _selectedCartItems.clear();
        _isCartSelectionMode = false;
        _pendingParentOrderIdForNextSubmit = null;
      });
      return true;
    }

    if (cart.items.isEmpty) {
      return true;
    }

    if (_hasOrderDetailDraft) {
      try {
        await cart.submitOrder(
          customerName: _customerName,
          tableName: _tableName,
          orderType: _orderType,
          parentOrderId: _pendingParentOrderIdForNextSubmit,
          cashierId: _activeCashierId,
          shiftId: _activeShiftId,
        );
      } catch (error) {
        if (!mounted) return false;
        _showDropdownSnackbar(
          'Failed to save current order: $error',
          isError: true,
        );
        return false;
      }

      if (!mounted) return false;

      setState(() {
        _selectedCartItems.clear();
        _selectedCartItems.clear();
        _isCartSelectionMode = false;
        _pendingParentOrderIdForNextSubmit = null;
      });

      return true;
    }

    final shouldContinue = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Order detail is empty'),
          content: const Text(
            'If you switch now, current cart items will be erased. '
            'Add order detail first if you want to keep this order.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Add Order Detail'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue Switching'),
            ),
          ],
        );
      },
    );

    if (!mounted) return false;
    if (shouldContinue == true) {
      return true;
    }

    Navigator.of(dialogContext).pop();
    await _showOfflineOrderDetailModal();
    if (!mounted) return false;
    await _showActiveCashierOrdersDialog();
    return false;
  }

  List<Map<String, dynamic>> _currentCartReceiptLines(CartProvider cart) {
    return cart.items.values
        .map((item) {
          final modifiers = item.modifiersData ?? <dynamic>[];
          final modifierExtra = modifiers
              .whereType<Map<String, dynamic>>()
              .fold<double>(0, (sum, modifier) {
                final selected =
                    modifier['selected_options'] as List<dynamic>? ??
                    <dynamic>[];
                return sum +
                    selected.whereType<Map<String, dynamic>>().fold<double>(
                      0,
                      (s, option) =>
                          s + ((option['price'] as num?)?.toDouble() ?? 0),
                    );
              });
          final unitPrice = item.price + modifierExtra;
          return <String, dynamic>{
            'name': item.name,
            'qty': item.quantity,
            'subtotal': unitPrice * item.quantity,
          };
        })
        .toList(growable: false);
  }

  Future<void> _printPreSettlementBill() async {
    final cart = context.read<CartProvider>();
    if (cart.items.isEmpty) {
      _showDropdownSnackbar('Cart is empty. Nothing to print.', isError: true);
      return;
    }

    final estimatedOrderId = _currentActiveOrderId ?? 0;
    try {
      await ThermalPrinterService.instance.printPaymentReceipt(
        orderId: estimatedOrderId,
        lines: _currentCartReceiptLines(cart),
        total: cart.totalAmount,
        paymentMethod: 'prebill',
        paid: 0,
        change: 0,
        customerName: _customerName,
        tableName: _tableName,
      );
      _showDropdownSnackbar('Pre-settlement bill printed.');
    } catch (error) {
      _showDropdownSnackbar('Failed to print pre-bill: $error', isError: true);
    }
  }

  Future<void> _printKitchenTicket() async {
    final cart = context.read<CartProvider>();
    if (cart.items.isEmpty) {
      _showDropdownSnackbar('Cart is empty. Nothing to print.', isError: true);
      return;
    }

    final kitchenLines = cart.items.values
        .where((item) {
          final category = item.category.toLowerCase();
          return category.contains('food') || category.contains('snack');
        })
        .map(
          (item) => <String, dynamic>{
            'name': '[KITCHEN] ${item.name}',
            'qty': item.quantity,
            'subtotal': 0,
          },
        )
        .toList(growable: false);

    if (kitchenLines.isEmpty) {
      _showDropdownSnackbar(
        'No food or snack items to print for kitchen.',
        isError: true,
      );
      return;
    }

    try {
      await ThermalPrinterService.instance.printPaymentReceipt(
        orderId: _currentActiveOrderId ?? 0,
        lines: kitchenLines,
        total: 0,
        paymentMethod: 'kitchen',
        paid: 0,
        change: 0,
        customerName: _customerName,
        tableName: _tableName,
      );
      _showDropdownSnackbar('Kitchen ticket printed.');
    } catch (error) {
      _showDropdownSnackbar(
        'Failed to print kitchen ticket: $error',
        isError: true,
      );
    }
  }

  Future<void> _switchToActiveOrder(Map<String, dynamic> order) async {
    final orderId = order['id'];
    if (orderId == null) {
      return;
    }

    if (_currentActiveOrderId != null && _currentActiveOrderId == orderId) {
      _showDropdownSnackbar('Order #$orderId is already active in cart.');
      return;
    }

    final cart = context.read<CartProvider>();
    List<_OnlineOrderItem> items;
    try {
      items = await _fetchOrderItems(orderId as int);
    } catch (error) {
      if (!mounted) return;
      _showDropdownSnackbar(
        'Cannot load order items while offline. Reconnect and try again. ($error)',
        isError: true,
      );
      return;
    }
    if (!mounted) return;

    cart.clearCart();
    for (final item in items) {
      cart.addItem(
        item.product,
        quantity: item.quantity,
        modifiers: item.modifiers,
        modifiersData: item.modifiersData,
      );
    }

    setState(() {
      _currentActiveOrderId = orderId;
      _currentOrderMetadata = Map<String, dynamic>.from(order);
      _customerName = order['customer_name']?.toString();
      _orderType = order['type']?.toString() ?? _orderType;
      _isOnlinePaidOrderInCart =
          (order['order_source']?.toString().toLowerCase() ?? '') == 'online';
      final notes = order['notes']?.toString();
      _tableName = _tableNameFromNotes(notes);
      _selectedCartItems.clear();
      _isCartSelectionMode = false;
      _pendingParentOrderIdForNextSubmit = null;
    });

    _showDropdownSnackbar('Switched to Order #$orderId');
  }
}
