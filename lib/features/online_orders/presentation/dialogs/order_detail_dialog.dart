part of '../../../cashier/presentation/screens/cashier_screen.dart';

extension OrderDetailDialogMethods on _ProductListScreenState {
  String _orderItemDedupSignature(Map<String, dynamic> row) {
    final productId = (row['product_id'] as num?)?.toInt() ?? 0;
    final notes = row['notes']?.toString() ?? '';
    final modifiers = row['modifiers'];
    return '$productId|$notes|${jsonEncode(_canonicalizeJsonValue(modifiers))}';
  }

  List<Map<String, dynamic>> _dedupeOrderItemRows(
    List<Map<String, dynamic>> rows,
  ) {
    final dedupedBySignature = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final signature = _orderItemDedupSignature(row);
      final incomingQty = (row['quantity'] as num?)?.toInt() ?? 0;
      final existing = dedupedBySignature[signature];
      final existingQty = (existing?['quantity'] as num?)?.toInt() ?? -1;
      if (existing == null || incomingQty >= existingQty) {
        dedupedBySignature[signature] = Map<String, dynamic>.from(row);
      }
    }
    return dedupedBySignature.values.toList(growable: false);
  }

  Future<void> _showOrderDetailModal(Map<String, dynamic> order) async {
    final orderId = order['id'];
    if (orderId == null) return;

    List<_OnlineOrderItem> items;
    try {
      items = await _fetchOrderItems(orderId as int, orderSnapshot: order);
    } catch (error) {
      if (!mounted) return;
      _showDropdownSnackbar(
        'Cannot load order details while offline. Reconnect and try again. ($error)',
        isError: true,
      );
      return;
    }
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('Order #$orderId'),
          content: SizedBox(
            width: 520,
            child: items.isEmpty
                ? const Text('No order items found.')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return ListTile(
                        title: Text(item.product.name),
                        subtitle: Text(
                          (() {
                            final modifiersText = _onlineOrderModifiersText(
                              item,
                            );
                            if (modifiersText.isEmpty) {
                              return 'Qty: ${item.quantity}';
                            }
                            return 'Qty: ${item.quantity}\n$modifiersText';
                          })(),
                        ),
                        trailing: Text(
                          _formatRupiah(
                            ((item.product.price +
                                    _modifierExtraFromData(
                                      item.modifiersData,
                                    )) *
                                item.quantity),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final updated = await _updateOrderStatusIfPaid(
                  orderId,
                  OrderStatus.cancelled,
                );

                if (!context.mounted) return;
                Navigator.of(dialogContext).pop();
                if (!updated) {
                  _showDropdownSnackbar(
                    'Order status changed by another user. Refresh applied.',
                    isError: true,
                  );
                }
              },
              child: const Text('Decline'),
            ),
            ElevatedButton(
              onPressed: () async {
                final currentStatus = (order['status'] ?? '').toString();
                late final bool updated;
                if (currentStatus == OrderStatus.paid) {
                  updated = await _updateOrderStatusIfPaid(
                    orderId,
                    OrderStatus.active,
                  );
                } else if (currentStatus == OrderStatus.active) {
                  updated = true;
                } else {
                  updated = false;
                }

                if (!context.mounted) return;
                if (!updated) {
                  Navigator.of(dialogContext).pop();
                  _showDropdownSnackbar(
                    'Order already handled from another app/session.',
                    isError: true,
                  );
                  return;
                }

                final cart = context.read<CartProvider>();
                for (final item in items) {
                  cart.addItem(
                    item.product,
                    quantity: item.quantity,
                    modifiers: item.modifiers,
                    modifiersData: item.modifiersData,
                  );
                }

                Navigator.of(dialogContext).pop();
              },
              child: const Text('Accept'),
            ),
          ],
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> _extractRowsFromOrderSnapshot(
    Map<String, dynamic>? orderSnapshot,
    int orderId,
  ) async {
    final payloadItems =
        (orderSnapshot?['items'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList(growable: false);
    if (payloadItems.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    final cachedProducts = await _productCatalogRepository.loadCachedProducts();
    final productById = {
      for (final product in cachedProducts) product.id: product,
    };

    return payloadItems
        .map((row) {
          final productId = (row['product_id'] as num?)?.toInt();
          final product = productId == null ? null : productById[productId];
          return <String, dynamic>{
            'order_id': (row['order_id'] as num?)?.toInt() ?? orderId,
            'quantity': (row['quantity'] as num?)?.toInt() ?? 1,
            'product_id': productId,
            'modifiers': row['modifiers'],
            'products': product?.toJson(),
          };
        })
        .where((row) => row['products'] != null)
        .toList(growable: false);
  }

  Future<List<_OnlineOrderItem>> _fetchOrderItems(
    int orderId, {
    Map<String, dynamic>? orderSnapshot,
  }) async {
    dynamic rows;
    try {
      rows = await supabase
          .from('order_items')
          .select('quantity, product_id, modifiers, notes, products(*)')
          .eq('order_id', orderId);
      final cacheRows = _dedupeOrderItemRows(
        (rows as List<dynamic>)
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList(growable: false),
      );
      await LocalOrderItemStoreRepository.instance.replaceForOrder(
        orderId: orderId,
        rows: cacheRows,
      );
      rows = cacheRows;
    } catch (_) {
      rows = await LocalOrderItemStoreRepository.instance.fetchByOrderId(
        orderId,
      );
      if ((rows as List).isEmpty) {
        final snapshotRows = await _extractRowsFromOrderSnapshot(
          orderSnapshot,
          orderId,
        );
        if (snapshotRows.isEmpty) {
          throw Exception('Order item lookup failed while offline.');
        }
        rows = snapshotRows;
      }
    }

    final normalizedRows = _dedupeOrderItemRows(
      (rows as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false),
    );

    final List<_OnlineOrderItem> items = [];
    for (final data in normalizedRows) {
      final quantity = (data['quantity'] as num?)?.toInt() ?? 1;
      final productData = data['products'] as Map<String, dynamic>?;
      final rawModifiers = data['modifiers'];

      if (productData != null) {
        final product = Product.fromJson(productData);
        items.add(
          _OnlineOrderItem(
            product: product,
            quantity: quantity,
            modifiers: _toCartModifiers(rawModifiers, product),
            modifiersData: _toModifiersData(rawModifiers, product),
            note: data['notes']?.toString(),
          ),
        );
      }
    }

    return items;
  }

  Future<bool> _updateOrderStatusIfPaid(int orderId, String status) async {
    final payload = <String, dynamic>{'status': status};
    if (status == OrderStatus.active) {
      payload['cashier_id'] = _activeCashierId;
      payload['shift_id'] = _activeShiftId;
    }

    final response = await supabase
        .from('orders')
        .update(payload)
        .eq('id', orderId)
        .eq('status', OrderStatus.paid)
        .select('id');

    final updatedRows = response as List<dynamic>;
    return updatedRows.isNotEmpty;
  }
}

class _OnlineOrderItem {
  final Product product;
  final int quantity;
  final CartModifiers? modifiers;
  final List<dynamic>? modifiersData;
  final String? note;

  _OnlineOrderItem({
    required this.product,
    required this.quantity,
    this.modifiers,
    this.modifiersData,
    this.note,
  });
}
