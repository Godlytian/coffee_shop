part of 'package:coffee_shop/features/cashier/presentation/screens/cashier_screen.dart';

extension OnlineOrdersDialogMethods on _ProductListScreenState {
  String _onlineOrderModifiersText(_OnlineOrderItem item) {
    final selections = item.modifiers?.selections;
    if (selections != null && selections.isNotEmpty) {
      return selections.entries
          .map((entry) => '${entry.key}: ${entry.value.join(', ')}')
          .join('\n');
    }

    final data = item.modifiersData;
    if (data != null) {
      final parts = <String>[];
      for (final group in data.whereType<Map<String, dynamic>>()) {
        final name =
            group['modifier_name']?.toString() ??
            group['name']?.toString() ??
            'Modifier';
        final selected =
            (group['selected_options'] as List<dynamic>? ?? <dynamic>[])
                .whereType<Map<String, dynamic>>()
                .map((entry) => entry['name']?.toString() ?? '')
                .where((value) => value.isNotEmpty)
                .toList();
        if (selected.isNotEmpty) {
          parts.add('$name: ${selected.join(', ')}');
        }
      }
      if (parts.isNotEmpty) {
        return parts.join('\n');
      }
    }

    return '';
  }

  String _onlineDateLabel(dynamic value) {
    DateTime date;
    if (value is DateTime) {
      date = value.toLocal();
    } else if (value is String) {
      date = DateTime.tryParse(value)?.toLocal() ?? DateTime.now();
    } else {
      date = DateTime.now();
    }

    const months = [
      'january',
      'february',
      'march',
      'april',
      'may',
      'june',
      'july',
      'august',
      'september',
      'october',
      'november',
      'december',
    ];

    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  String _onlineTimeLabel(dynamic value) {
    DateTime date;
    if (value is DateTime) {
      date = value.toLocal();
    } else if (value is String) {
      date = DateTime.tryParse(value)?.toLocal() ?? DateTime.now();
    } else {
      date = DateTime.now();
    }
    final hours = date.hour.toString().padLeft(2, '0');
    final minutes = date.minute.toString().padLeft(2, '0');
    return '$hours:$minutes';
  }

  void _preloadOnlineOrderItemPreview(
    int orderId,
    void Function(VoidCallback fn) setDialogState,
  ) {
    if (_onlineOrderItemPreviewCache.containsKey(orderId) ||
        _onlineOrderItemPreviewLoading.contains(orderId)) {
      return;
    }
    _onlineOrderItemPreviewLoading.add(orderId);
    unawaited(() async {
      try {
        final items = await _fetchOrderItems(orderId);
        final preview = items
            .map((item) => '${item.quantity}x ${item.product.name}')
            .join(', ');
        if (!mounted) return;
        setDialogState(() {
          _onlineOrderItemPreviewCache[orderId] = preview.isEmpty
              ? 'No items'
              : preview;
        });
      } catch (_) {
        if (!mounted) return;
        setDialogState(() {
          _onlineOrderItemPreviewCache[orderId] = 'Failed to load items';
        });
      } finally {
        _onlineOrderItemPreviewLoading.remove(orderId);
      }
    }());
  }

  Future<void> _showAllOrdersDialog() async {
    String searchQuery = '';
    String selectedStatus = 'all';
    int? selectedOrderId;

    final offlinePending = await context
        .read<CartProvider>()
        .getPendingOfflineOrders();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              insetPadding: const EdgeInsets.all(24),
              child: SizedBox(
                width: 1100,
                height: 680,
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: _allOrdersStream,
                  builder: (context, snapshot) {
                    final remoteOrders =
                        snapshot.data ?? <Map<String, dynamic>>[];
                    final hasRemoteError = snapshot.hasError;
                    final offlineOrders = offlinePending
                        .map(
                          (pending) => Map<String, dynamic>.from(
                            pending['order'] as Map,
                          ),
                        )
                        .toList(growable: false);
                    final rawOrders = hasRemoteError
                        ? offlineOrders
                        : remoteOrders;
                    final normalizedSearch = searchQuery.trim().toLowerCase();

                    final filtered = rawOrders
                        .where((order) {
                          final status = (order['status'] ?? '').toString();
                          if (selectedStatus != 'all' &&
                              status != selectedStatus) {
                            return false;
                          }

                          if (normalizedSearch.isEmpty) {
                            return true;
                          }

                          final id = order['id']?.toString() ?? '';
                          final customer = (order['customer_name'] ?? '')
                              .toString()
                              .toLowerCase();
                          final notes = (order['notes'] ?? '')
                              .toString()
                              .toLowerCase();
                          final source = (order['order_source'] ?? '')
                              .toString()
                              .toLowerCase();

                          return id.contains(normalizedSearch) ||
                              customer.contains(normalizedSearch) ||
                              notes.contains(normalizedSearch) ||
                              source.contains(normalizedSearch);
                        })
                        .toList(growable: false);

                    if (selectedOrderId != null &&
                        filtered.every(
                          (order) =>
                              (order['id'] as num?)?.toInt() != selectedOrderId,
                        )) {
                      selectedOrderId = filtered.isEmpty
                          ? null
                          : (filtered.first['id'] as num?)?.toInt();
                    }
                    selectedOrderId ??= filtered.isEmpty
                        ? null
                        : (filtered.first['id'] as num?)?.toInt();

                    final selectedOrder = selectedOrderId == null
                        ? null
                        : filtered.firstWhere(
                            (order) =>
                                (order['id'] as num?)?.toInt() ==
                                selectedOrderId,
                            orElse: () => <String, dynamic>{},
                          );

                    final statusCount = <String, int>{
                      'all': rawOrders.length,
                      OrderStatus.pending: 0,
                      OrderStatus.active: 0,
                      OrderStatus.processing: 0,
                      OrderStatus.assigned: 0,
                      OrderStatus.completed: 0,
                      OrderStatus.cancelled: 0,
                    };
                    for (final order in rawOrders) {
                      final status = (order['status'] ?? '').toString();
                      if (statusCount.containsKey(status)) {
                        statusCount[status] = (statusCount[status] ?? 0) + 1;
                      }
                    }

                    Widget statusCard({
                      required String value,
                      required String label,
                      required Color color,
                    }) {
                      final isActive = selectedStatus == value;
                      return Expanded(
                        child: InkWell(
                          onTap: () =>
                              setDialogState(() => selectedStatus = value),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? color.withOpacity(0.14)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isActive ? color : Colors.blue.shade100,
                              ),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  '${statusCount[value] ?? 0}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: color,
                                    fontSize: 18,
                                  ),
                                ),
                                Text(
                                  label,
                                  style: TextStyle(color: color, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }

                    final grouped = <String, List<Map<String, dynamic>>>{};
                    for (final order in filtered) {
                      final label = _onlineDateLabel(order['created_at']);
                      grouped
                          .putIfAbsent(label, () => <Map<String, dynamic>>[])
                          .add(order);
                    }

                    return Column(
                      children: [
                        if (snapshot.hasError)
                          Container(
                            width: double.infinity,
                            color: Colors.orange.shade100,
                            padding: const EdgeInsets.all(10),
                            child: const Text(
                              'Offline mode: showing locally queued orders only.',
                            ),
                          ),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            border: Border(
                              bottom: BorderSide(color: Colors.blue.shade100),
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.receipt_long,
                                    color: Colors.blue,
                                  ),
                                  const SizedBox(width: 8),
                                  const Text(
                                    'All Orders',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    onPressed: () =>
                                        Navigator.of(dialogContext).pop(),
                                    icon: const Icon(Icons.close),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                onChanged: (value) =>
                                    setDialogState(() => searchQuery = value),
                                decoration: InputDecoration(
                                  hintText:
                                      'Search order id, customer, notes, source...',
                                  prefixIcon: const Icon(Icons.search),
                                  filled: true,
                                  fillColor: Colors.white,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide(
                                      color: Colors.blue.shade100,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  statusCard(
                                    value: 'all',
                                    label: 'All',
                                    color: Colors.blue,
                                  ),
                                  const SizedBox(width: 8),
                                  statusCard(
                                    value: OrderStatus.pending,
                                    label: 'Pending',
                                    color: Colors.orange,
                                  ),
                                  const SizedBox(width: 8),
                                  statusCard(
                                    value: OrderStatus.active,
                                    label: 'Active',
                                    color: Colors.teal,
                                  ),
                                  const SizedBox(width: 8),
                                  statusCard(
                                    value: OrderStatus.processing,
                                    label: 'Processing',
                                    color: Colors.indigo,
                                  ),
                                  const SizedBox(width: 8),
                                  statusCard(
                                    value: OrderStatus.completed,
                                    label: 'Completed',
                                    color: Colors.green,
                                  ),
                                  const SizedBox(width: 8),
                                  statusCard(
                                    value: OrderStatus.cancelled,
                                    label: 'Cancelled',
                                    color: Colors.red,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Row(
                            children: [
                              Container(
                                width: 430,
                                decoration: BoxDecoration(
                                  border: Border(
                                    right: BorderSide(
                                      color: Colors.blue.shade100,
                                    ),
                                  ),
                                  color: Colors.white,
                                ),
                                child: filtered.isEmpty
                                    ? const Center(
                                        child: Text('No orders found.'),
                                      )
                                    : ListView(
                                        padding: const EdgeInsets.all(12),
                                        children: grouped.entries.expand((
                                          entry,
                                        ) {
                                          final header = Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 8,
                                            ),
                                            child: Text(
                                              '${entry.key}:',
                                              style: TextStyle(
                                                color: Colors.blue.shade700,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          );

                                          final tiles = entry.value.map((
                                            order,
                                          ) {
                                            final orderId = order['id'];
                                            final customer =
                                                order['customer_name']
                                                        ?.toString()
                                                        .trim()
                                                        .isNotEmpty ==
                                                    true
                                                ? order['customer_name']
                                                : 'Guest';
                                            final status =
                                                (order['status'] ?? '-')
                                                    .toString();
                                            final source =
                                                (order['order_source'] ?? '-')
                                                    .toString();
                                            final total =
                                                (order['total_price']
                                                    as num?) ??
                                                (order['total_amount']
                                                    as num?) ??
                                                0;
                                            final isSelected =
                                                (order['id'] as num?)
                                                    ?.toInt() ==
                                                selectedOrderId;
                                            return Card(
                                              elevation: 0,
                                              margin:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 4,
                                                  ),
                                              color: isSelected
                                                  ? Colors.blue.withOpacity(
                                                      0.08,
                                                    )
                                                  : null,
                                              child: ListTile(
                                                onTap: () => setDialogState(() {
                                                  selectedOrderId =
                                                      (order['id'] as num?)
                                                          ?.toInt();
                                                }),
                                                title: Text(
                                                  'Order #$orderId • $customer',
                                                ),
                                                subtitle: Text(
                                                  '${status.toUpperCase()} • ${source.toUpperCase()} • ${_formatRupiah(total)}',
                                                ),
                                                trailing: const Icon(
                                                  Icons.chevron_right,
                                                ),
                                              ),
                                            );
                                          }).toList();

                                          return [header, ...tiles];
                                        }).toList(),
                                      ),
                              ),
                              Expanded(
                                child:
                                    selectedOrder == null ||
                                        selectedOrder.isEmpty
                                    ? const Center(
                                        child: Text(
                                          'Select an order to see details.',
                                        ),
                                      )
                                    : FutureBuilder<List<_OnlineOrderItem>>(
                                        future: _fetchOrderItems(
                                          (selectedOrder['id'] as num).toInt(),
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
                                          return Padding(
                                            padding: const EdgeInsets.all(16),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  'Order #${selectedOrder['id']} • ${selectedOrder['customer_name'] ?? 'Guest'}',
                                                  style: const TextStyle(
                                                    fontSize: 20,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  'Status: ${(selectedOrder['status'] ?? '-').toString().toUpperCase()} • Source: ${(selectedOrder['order_source'] ?? '-').toString().toUpperCase()}',
                                                  style: TextStyle(
                                                    color: Colors.blue.shade700,
                                                  ),
                                                ),
                                                if ((selectedOrder['notes'] ??
                                                        '')
                                                    .toString()
                                                    .isNotEmpty)
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          top: 8,
                                                        ),
                                                    child: Text(
                                                      'Notes: ${selectedOrder['notes']}',
                                                    ),
                                                  ),
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 8,
                                                      ),
                                                  child: Text(
                                                    'Total: ${_formatRupiah(total)}',
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600,
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
                                                          itemCount:
                                                              items.length,
                                                          separatorBuilder:
                                                              (_, __) =>
                                                                  const Divider(),
                                                          itemBuilder: (_, index) {
                                                            final item =
                                                                items[index];
                                                            final modifierText =
                                                                _onlineOrderModifiersText(
                                                                  item,
                                                                );
                                                            final itemTotal =
                                                                ((item.product.price +
                                                                            _modifierExtraFromData(
                                                                              item.modifiersData,
                                                                            )) *
                                                                        item.quantity)
                                                                    .toDouble();
                                                            return ListTile(
                                                              title: Text(
                                                                item
                                                                    .product
                                                                    .name,
                                                              ),
                                                              subtitle: Text(
                                                                modifierText
                                                                        .isEmpty
                                                                    ? 'Qty: ${item.quantity}'
                                                                    : 'Qty: ${item.quantity}\n$modifierText',
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
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                              ),
                            ],
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
  }

  Future<void> _showOnlinePendingOrdersDialog() async {
    _isOnlineOrdersDialogOpen = true;
    await OrderNotificationService.instance.clearUnreadNotifications();
    int? selectedOrderId;
    final ScrollController pendingOrdersScrollController = ScrollController();

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                title: const Text('Online Orders'),
                content: SizedBox(
                  width: 900,
                  height: 560,
                  child: StreamBuilder<List<Map<String, dynamic>>>(
                    stream: _onlinePendingOrdersStream,
                    builder: (context, snapshot) {
                      final pendingOrders =
                          snapshot.data ?? <Map<String, dynamic>>[];

                      if (selectedOrderId != null &&
                          pendingOrders.every(
                            (order) =>
                                (order['id'] as num?)?.toInt() !=
                                selectedOrderId,
                          )) {
                        selectedOrderId = null;
                      }
                      selectedOrderId ??= pendingOrders.isEmpty
                          ? null
                          : (pendingOrders.first['id'] as num?)?.toInt();

                      final selectedOrder = selectedOrderId == null
                          ? null
                          : pendingOrders.firstWhere(
                              (order) =>
                                  (order['id'] as num?)?.toInt() ==
                                  selectedOrderId,
                              orElse: () => <String, dynamic>{},
                            );

                      if (snapshot.connectionState == ConnectionState.waiting &&
                          pendingOrders.isEmpty) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      return Row(
                        children: [
                          Container(
                            width: 400,
                            decoration: BoxDecoration(
                              border: Border(
                                right: BorderSide(color: Colors.blue.shade100),
                              ),
                            ),
                            child: pendingOrders.isEmpty
                                ? const Center(child: Text('No online orders.'))
                                : ListView.separated(
                                    key: const PageStorageKey<String>(
                                      'online_pending_orders_list',
                                    ),
                                    controller: pendingOrdersScrollController,
                                    itemCount: pendingOrders.length,
                                    separatorBuilder: (_, __) =>
                                        const Divider(height: 1),
                                    itemBuilder: (context, index) {
                                      final order = pendingOrders[index];
                                      final orderId = (order['id'] as num?)
                                          ?.toInt();
                                      final isSelected =
                                          orderId != null &&
                                          orderId == selectedOrderId;
                                      final isNewOrder =
                                          orderId != null &&
                                          _newlyPaidOnlineOrderIds.contains(
                                            orderId,
                                          );
                                      final customer = order['customer_name']
                                          ?.toString();
                                      final total =
                                          (order['total_price'] as num?) ??
                                          (order['total_amount'] as num?) ??
                                          0;
                                      final orderTime = _onlineTimeLabel(
                                        order['created_at'],
                                      );
                                      return ListTile(
                                        selected: isSelected,
                                        title: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                'Order #${order['id']}',
                                              ),
                                            ),
                                            if (isNewOrder)
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.red.shade100,
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                child: Text(
                                                  'NEW',
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 11,
                                                    color: Colors.red.shade800,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        subtitle: orderId == null
                                            ? Text(
                                                '${customer == null || customer.isEmpty ? 'Guest' : customer}\nTotal: ${_formatRupiah(total)} • $orderTime',
                                                maxLines: 2,
                                              )
                                            : Builder(
                                                builder: (context) {
                                                  _preloadOnlineOrderItemPreview(
                                                    orderId,
                                                    setDialogState,
                                                  );
                                                  final itemText =
                                                      _onlineOrderItemPreviewCache[orderId] ??
                                                      'Loading items...';
                                                  return Text(
                                                    '${customer == null || customer.isEmpty ? 'Guest' : customer}\nTotal: ${_formatRupiah(total)} • $orderTime\n$itemText',
                                                    maxLines: 3,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  );
                                                },
                                              ),
                                        trailing: const Icon(
                                          Icons.chevron_right,
                                        ),
                                        onTap: orderId == null
                                            ? null
                                            : () => setDialogState(() {
                                                selectedOrderId = orderId;
                                                _newlyPaidOnlineOrderIds.remove(
                                                  orderId,
                                                );
                                              }),
                                      );
                                    },
                                  ),
                          ),
                          Expanded(
                            child:
                                selectedOrder == null || selectedOrder.isEmpty
                                ? const Center(
                                    child: Text(
                                      'Select an order to see details.',
                                    ),
                                  )
                                : FutureBuilder<List<_OnlineOrderItem>>(
                                    future: _fetchOrderItems(
                                      (selectedOrder['id'] as num).toInt(),
                                    ),
                                    builder: (context, detailSnapshot) {
                                      final items =
                                          detailSnapshot.data ??
                                          <_OnlineOrderItem>[];
                                      final orderId =
                                          (selectedOrder['id'] as num).toInt();
                                      final customerName =
                                          selectedOrder['customer_name']
                                                  ?.toString()
                                                  .trim()
                                                  .isNotEmpty ==
                                              true
                                          ? selectedOrder['customer_name']
                                                .toString()
                                          : 'Guest';
                                      return Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Order #$orderId • $customerName',
                                              style: const TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'Order items',
                                              style: TextStyle(
                                                fontSize: 14,
                                                color: Colors.blue.shade700,
                                                fontWeight: FontWeight.w600,
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
                                                      separatorBuilder:
                                                          (_, __) =>
                                                              const Divider(),
                                                      itemBuilder: (_, index) {
                                                        final item =
                                                            items[index];
                                                        final modifierText =
                                                            _onlineOrderModifiersText(
                                                              item,
                                                            );
                                                        return ListTile(
                                                          title: Text(
                                                            item.product.name,
                                                          ),
                                                          subtitle: Text(
                                                            modifierText.isEmpty
                                                                ? 'Qty: ${item.quantity}'
                                                                : 'Qty: ${item.quantity}$modifierText',
                                                          ),
                                                          trailing: Text(
                                                            _formatRupiah(
                                                              ((item.product.price +
                                                                          _modifierExtraFromData(
                                                                            item.modifiersData,
                                                                          )) *
                                                                      item.quantity)
                                                                  .toDouble(),
                                                            ),
                                                          ),
                                                        );
                                                      },
                                                    ),
                                            ),
                                            const SizedBox(height: 12),
                                            Align(
                                              alignment: Alignment.centerRight,
                                              child: ElevatedButton(
                                                onPressed: items.isEmpty
                                                    ? null
                                                    : () async {
                                                        final updated =
                                                            await _updateOrderStatusIfPaid(
                                                              orderId,
                                                              OrderStatus
                                                                  .active,
                                                            );
                                                        if (!context.mounted)
                                                          return;
                                                        if (!updated) {
                                                          _showDropdownSnackbar(
                                                            'Order already handled from another app/session.',
                                                            isError: true,
                                                          );
                                                          return;
                                                        }

                                                        final cart = context
                                                            .read<
                                                              CartProvider
                                                            >();
                                                        cart.clearCart();
                                                        for (final item
                                                            in items) {
                                                          cart.addItem(
                                                            item.product,
                                                            quantity:
                                                                item.quantity,
                                                            modifiers:
                                                                item.modifiers,
                                                            modifiersData: item
                                                                .modifiersData,
                                                          );
                                                        }

                                                        setState(() {
                                                          _currentActiveOrderId =
                                                              orderId;
                                                          _currentOrderMetadata =
                                                              Map<
                                                                String,
                                                                dynamic
                                                              >.from(
                                                                selectedOrder,
                                                              );
                                                          _isOnlinePaidOrderInCart =
                                                              true;
                                                          _customerName =
                                                              selectedOrder['customer_name']
                                                                  ?.toString();
                                                          _orderType =
                                                              selectedOrder['type']
                                                                  ?.toString() ??
                                                              _orderType;
                                                          final notes =
                                                              selectedOrder['notes']
                                                                  ?.toString();
                                                          _tableName =
                                                              _tableNameFromNotes(
                                                                notes,
                                                              );
                                                          _selectedCartItems
                                                              .clear();
                                                          _isCartSelectionMode =
                                                              false;
                                                          _pendingParentOrderIdForNextSubmit =
                                                              null;
                                                        });

                                                        if (!dialogContext
                                                            .mounted) {
                                                          return;
                                                        }
                                                        Navigator.of(
                                                          dialogContext,
                                                        ).pop();
                                                        _showDropdownSnackbar(
                                                          'Order #$orderId accepted to active cart.',
                                                        );
                                                      },
                                                child: const Text('Accept'),
                                              ),
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
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Close'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      pendingOrdersScrollController.dispose();
      _isOnlineOrdersDialogOpen = false;
    }
  }
}
