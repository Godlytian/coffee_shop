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
    final rows = await supabase
        .from('order_items')
        .select('id, product_id, quantity, price_at_time, modifiers')
        .eq('order_id', orderId);

    return (rows as List<dynamic>).whereType<Map<String, dynamic>>().toList();
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

  double _localRowSubtotal(Map<String, dynamic> row) {
    final qty = (row['quantity'] as num?)?.toDouble() ?? 0;
    final product = row['products'] as Map<String, dynamic>?;
    final base = (product?['price'] as num?)?.toDouble() ?? 0;
    final extra = _localModifierExtra(row['modifiers']);
    return (base + extra) * qty;
  }

  Future<void> _upsertLocalOrderTotal(
    int orderId, {
    required String status,
    String? notes,
  }) async {
    final orders = await LocalOrderStoreRepository.instance.fetchAllOrders();
    final existing = orders.firstWhere(
      (order) => ((order['id'] as num?)?.toInt() ?? -1) == orderId,
      orElse: () => <String, dynamic>{'id': orderId},
    );
    final rows = await LocalOrderItemStoreRepository.instance.fetchByOrderId(
      orderId,
    );
    final total = rows.fold<double>(
      0,
      (sum, row) => sum + _localRowSubtotal(row),
    );
    await LocalOrderStoreRepository.instance.upsertOrder({
      ...Map<String, dynamic>.from(existing),
      'id': orderId,
      'status': status,
      'total_price': total,
      'subtotal': total,
      'discount_total': 0,
      'notes': notes ?? existing['notes'],
      'created_at': existing['created_at'] ?? DateTime.now().toIso8601String(),
      'order_source': existing['order_source'] ?? 'cashier',
    });
  }

  void _restoreCartItemsFromMap(Map<String, CartItem> entries) {
    final cart = context.read<CartProvider>();
    cart.clearCart();
    for (final item in entries.values) {
      cart.addItem(
        item,
        quantity: item.quantity,
        modifiers: item.modifiers,
        modifiersData: item.modifiersData,
      );
    }
  }

  String _modifierSignature(dynamic rawModifiers) {
    final normalized = _normalizeRawModifiers(rawModifiers);
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
    return [
      item.id,
      item.quantity,
      item.price.toStringAsFixed(6),
      _modifierSignature(rawModifiers),
    ].join('|');
  }

  Future<void> _recalculateAndPersistOrderTotals(int orderId) async {
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

  Future<int> _generateOfflineDailyUniqueOrderId() async {
    final localOrders = await LocalOrderStoreRepository.instance
        .fetchAllOrders();
    final localNegativeIds = localOrders
        .map((row) => (row['id'] as num?)?.toInt())
        .whereType<int>()
        .where((id) => id < 0)
        .toList(growable: false);
    if (localNegativeIds.isEmpty) {
      return -1;
    }
    final smallest = localNegativeIds.reduce(
      (value, element) => value < element ? value : element,
    );
    return smallest - 1;
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
    final selectedEntries = _selectedCartEntries();
    if (selectedEntries.isEmpty) {
      _showDropdownSnackbar('Pilih item yang ingin digabung dulu.');
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

    try {
      if (_currentActiveOrderId != null) {
        final cart = context.read<CartProvider>();
        await cart.updateExistingOrder(
          orderId: _currentActiveOrderId!,
          customerName: _customerName,
          tableName: _tableName,
          orderType: _orderType,
        );

        final rows = await _fetchOrderItemRows(_currentActiveOrderId!);
        final selectedIds = await _matchSelectedOrderItemIds(
          rows: rows,
          selectedItems: selectedEntries.values,
        );

        if (selectedIds.isEmpty) {
          throw Exception(
            'Tidak menemukan item order yang dipilih untuk digabung.',
          );
        }

        await supabase
            .from('order_items')
            .update({'order_id': targetOrderId})
            .inFilter('id', selectedIds);

        await _recalculateAndPersistOrderTotals(_currentActiveOrderId!);
        await _recalculateAndPersistOrderTotals(targetOrderId);

        final sourceCancelled = await _cancelSourceIfNoRemainingItems(
          _currentActiveOrderId!,
          extraNote: 'Merged into Order #$targetOrderId',
        );
        if (sourceCancelled) {
          _resetCurrentOrderDraft(showMessage: false);
        } else {
          final refreshed = await supabase
              .from('orders')
              .select('id, customer_name, type, notes')
              .eq('id', _currentActiveOrderId!)
              .single();
          if (!mounted) return;
          await _switchToActiveOrder(refreshed);
        }
      } else {
        await _insertCartEntriesToOrder(
          orderId: targetOrderId,
          items: selectedEntries.values,
        );
        await _recalculateAndPersistOrderTotals(targetOrderId);
        final cart = context.read<CartProvider>();
        for (final key in selectedEntries.keys) {
          cart.removeItem(key);
        }
        setState(() {
          _selectedCartItems.removeAll(selectedEntries.keys);
          _isCartSelectionMode = _selectedCartItems.isNotEmpty;
        });
      }
    } catch (error) {
      if (!mounted) return;
      _showDropdownSnackbar('Gagal gabung nota: $error', isError: true);
      return;
    }

    if (!mounted) return;
    _showDropdownSnackbar('Item berhasil digabung ke Order #$targetOrderId');
  }

  Future<void> _handleSplitBill() async {
    if (_currentActiveOrderId == null) {
      _showDropdownSnackbar(
        'Pisah nota membutuhkan order aktif. Simpan order dulu lalu coba lagi.',
      );
      return;
    }

    final selectedEntries = _selectedCartEntries();
    if (selectedEntries.isEmpty) {
      _showDropdownSnackbar('Pilih item yang ingin dipisah dulu.');
      return;
    }

    final sourceOrderId = _currentActiveOrderId!;

    try {
      final cart = context.read<CartProvider>();
      await cart.updateExistingOrder(
        orderId: sourceOrderId,
        customerName: _customerName,
        tableName: _tableName,
        orderType: _orderType,
      );

      if (_isOfflineMode) {
        final sourceRows = await LocalOrderItemStoreRepository.instance
            .fetchByOrderId(sourceOrderId);
        if (sourceRows.isEmpty) {
          throw Exception('Offline source order items not found.');
        }

        final selectionBuckets = <String, int>{};
        for (final item in selectedEntries.values) {
          final key = _selectedCartItemSignature(item);
          selectionBuckets.update(key, (count) => count + 1, ifAbsent: () => 1);
        }

        final selectedRows = <Map<String, dynamic>>[];
        final remainingRows = <Map<String, dynamic>>[];

        for (final row in sourceRows) {
          final key = _orderItemRowSignature(row);
          final remainingCount = selectionBuckets[key] ?? 0;
          if (remainingCount > 0) {
            selectedRows.add(Map<String, dynamic>.from(row));
            selectionBuckets[key] = remainingCount - 1;
          } else {
            remainingRows.add(Map<String, dynamic>.from(row));
          }
        }

        final unmatched = selectionBuckets.values.any((count) => count > 0);
        if (selectedRows.isEmpty || unmatched) {
          throw Exception(
            'Tidak menemukan item order yang dipilih untuk dipisah (offline).',
          );
        }

        final localOrders = await LocalOrderStoreRepository.instance
            .fetchAllOrders();
        final sourceOrder = localOrders.firstWhere(
          (row) => ((row['id'] as num?)?.toInt() ?? -1) == sourceOrderId,
          orElse: () => <String, dynamic>{},
        );

        final targetOrderId = await _generateOfflineDailyUniqueOrderId();
        final createdAt = DateTime.now().toIso8601String();
        final sourceNotes = sourceOrder['notes']?.toString();
        final targetOrder = <String, dynamic>{
          'id': targetOrderId,
          'status': OrderStatus.active,
          'type': sourceOrder['type'] ?? _orderType,
          'order_source': sourceOrder['order_source'] ?? 'cashier',
          'payment_method': null,
          'total_price': 0,
          'subtotal': 0,
          'discount_total': 0,
          'points_earned': 0,
          'points_used': 0,
          'total_payment_received': null,
          'change_amount': null,
          'customer_name': sourceOrder['customer_name'],
          'parent_order_id': sourceOrderId,
          'cashier_id': _activeCashierId,
          'shift_id': _activeShiftId,
          'notes': sourceNotes,
          'created_at': createdAt,
        };

        await LocalOrderStoreRepository.instance.upsertOrder(targetOrder);
        await LocalOrderItemStoreRepository.instance.replaceForOrder(
          orderId: targetOrderId,
          rows: selectedRows
              .map(
                (row) =>
                    Map<String, dynamic>.from(row)
                      ..['order_id'] = targetOrderId,
              )
              .toList(growable: false),
        );
        await LocalOrderItemStoreRepository.instance.replaceForOrder(
          orderId: sourceOrderId,
          rows: remainingRows
              .map(
                (row) =>
                    Map<String, dynamic>.from(row)
                      ..['order_id'] = sourceOrderId,
              )
              .toList(growable: false),
        );

        await _upsertLocalOrderTotal(
          targetOrderId,
          status: OrderStatus.active,
          notes: sourceNotes,
        );
        await _upsertLocalOrderTotal(
          sourceOrderId,
          status: remainingRows.isEmpty
              ? OrderStatus.cancelled
              : OrderStatus.active,
          notes: remainingRows.isEmpty
              ? _buildOrderNotes(
                  tableName: _tableName,
                  extraNote: 'Items split to new offline draft #$targetOrderId',
                )
              : sourceNotes,
        );

        cart.clearCart();
        for (final item in selectedEntries.values) {
          cart.addItem(
            item,
            quantity: item.quantity,
            modifiers: item.modifiers,
            modifiersData: item.modifiersData,
          );
        }

        if (!mounted) return;
        setState(() {
          _currentActiveOrderId = null;
          _pendingParentOrderIdForNextSubmit = sourceOrderId;
          _customerName = null;
          _tableName = null;
          _selectedCartItems.clear();
          _isCartSelectionMode = false;
        });

        _showDropdownSnackbar(
          'Item dipisah ke draft baru (offline). Parent order: #$sourceOrderId',
        );
        return;
      }

      final rows = await _fetchOrderItemRows(sourceOrderId);
      final selectedIds = await _matchSelectedOrderItemIds(
        rows: rows,
        selectedItems: selectedEntries.values,
      );

      if (selectedIds.isEmpty) {
        throw Exception(
          'Tidak menemukan item order yang dipilih untuk dipisah.',
        );
      }

      await supabase.from('order_items').delete().inFilter('id', selectedIds);

      await _recalculateAndPersistOrderTotals(sourceOrderId);
      await _cancelSourceIfNoRemainingItems(
        sourceOrderId,
        extraNote: 'Items split to new cashier draft',
      );

      cart.clearCart();
      for (final item in selectedEntries.values) {
        cart.addItem(
          item,
          quantity: item.quantity,
          modifiers: item.modifiers,
          modifiersData: item.modifiersData,
        );
      }

      if (!mounted) return;
      setState(() {
        _currentActiveOrderId = null;
        _pendingParentOrderIdForNextSubmit = sourceOrderId;
        _customerName = null;
        _tableName = null;
        _selectedCartItems.clear();
        _isCartSelectionMode = false;
      });

      _showDropdownSnackbar(
        'Item dipisah ke draft baru. Parent order: #$sourceOrderId',
      );
    } catch (error) {
      if (!mounted) return;
      _showDropdownSnackbar('Gagal pisah nota: $error', isError: true);
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
        .map(
          (item) => <String, dynamic>{
            'name': '[KITCHEN] ${item.name}',
            'qty': item.quantity,
            'subtotal': 0,
          },
        )
        .toList(growable: false);

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
