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

  List<String> _onlineOrderItemNotes(_OnlineOrderItem item) {
    final notes = <String>[];
    final rowNote = item.note?.trim() ?? '';
    if (rowNote.isNotEmpty) {
      notes.add(rowNote);
    }
    final directNote = item.modifiers?.notes.trim() ?? '';
    if (directNote.isNotEmpty) {
      notes.add(directNote);
    }

    final data = item.modifiersData;
    if (data != null) {
      for (final group in data.whereType<Map<String, dynamic>>()) {
        final note =
            group['notes']?.toString().trim() ??
            group['note']?.toString().trim() ??
            '';
        if (note.isNotEmpty) {
          notes.add(note);
        }
      }
    }

    return notes.toSet().toList(growable: false);
  }

  String _onlineOrderItemSubtitle(_OnlineOrderItem item) {
    final lines = <String>['Qty: ${item.quantity}'];
    final modifiersText = _onlineOrderModifiersText(item);
    final itemNotes = _onlineOrderItemNotes(item);

    if (modifiersText.isNotEmpty) {
      lines.add(modifiersText);
    }
    for (final note in itemNotes) {
      lines.add('Item note: $note');
    }

    return lines.join('\n');
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

  String _shiftDateTimeRangeLabel(dynamic startedAt, dynamic endedAt) {
    final started = startedAt is String
        ? DateTime.tryParse(startedAt)?.toLocal()
        : startedAt is DateTime
        ? startedAt.toLocal()
        : null;
    final ended = endedAt is String
        ? DateTime.tryParse(endedAt)?.toLocal()
        : endedAt is DateTime
        ? endedAt.toLocal()
        : null;

    if (started == null) return '-';
    final startDate = _onlineDateLabel(started);
    final startTime = _onlineTimeLabel(started);
    final endTime = ended == null ? 'OPEN' : _onlineTimeLabel(ended);
    return '$startDate • $startTime - $endTime';
  }

  Future<List<Map<String, dynamic>>> _fetchShiftRowsForReport() async {
    try {
      final shifts = await supabase
          .from('shifts')
          .select(
            'id, branch_id, started_at, ended_at, opened_by, closed_by, current_cashier_id',
          )
          .order('started_at', ascending: false);
      return (shifts as List<dynamic>).whereType<Map<String, dynamic>>().toList(
        growable: false,
      );
    } catch (_) {
      final localOrders = await LocalOrderStoreRepository.instance
          .fetchAllOrders();
      final grouped = <int, List<Map<String, dynamic>>>{};
      for (final order in localOrders) {
        final shiftId = _toInt(order['shift_id']);
        if (shiftId == null) continue;
        grouped.putIfAbsent(shiftId, () => <Map<String, dynamic>>[]).add(order);
      }

      final rows =
          grouped.entries
              .map((entry) {
                final orders = List<Map<String, dynamic>>.from(entry.value)
                  ..sort((a, b) {
                    final aTime = DateTime.tryParse(
                      (a['created_at'] ?? '').toString(),
                    );
                    final bTime = DateTime.tryParse(
                      (b['created_at'] ?? '').toString(),
                    );
                    if (aTime == null && bTime == null) return 0;
                    if (aTime == null) return 1;
                    if (bTime == null) return -1;
                    return bTime.compareTo(aTime);
                  });
                final latest = orders.isEmpty
                    ? <String, dynamic>{}
                    : orders.first;
                final oldest = orders.isEmpty
                    ? <String, dynamic>{}
                    : orders.last;
                final cashierId =
                    _toInt(latest['cashier_id']) ?? _activeCashierId;

                return <String, dynamic>{
                  'id': entry.key,
                  'branch_id': latest['branch_id'],
                  'started_at': oldest['created_at'],
                  'ended_at': latest['created_at'],
                  'opened_by': cashierId,
                  'closed_by': cashierId,
                  'current_cashier_id': cashierId,
                };
              })
              .toList(growable: false)
            ..sort((a, b) {
              final aTime = DateTime.tryParse(
                (a['started_at'] ?? '').toString(),
              );
              final bTime = DateTime.tryParse(
                (b['started_at'] ?? '').toString(),
              );
              if (aTime == null && bTime == null) return 0;
              if (aTime == null) return 1;
              if (bTime == null) return -1;
              return bTime.compareTo(aTime);
            });

      if (_activeShiftId != null &&
          rows.every((row) => _toInt(row['id']) != _activeShiftId)) {
        rows.insert(0, <String, dynamic>{
          'id': _activeShiftId,
          'branch_id': '-',
          'started_at': DateTime.now().toIso8601String(),
          'ended_at': null,
          'opened_by': _activeCashierId,
          'closed_by': null,
          'current_cashier_id': _activeCashierId,
        });
      }
      return rows;
    }
  }

  int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  Future<Map<int, String>> _fetchCashierNamesByIds(Set<int> ids) async {
    if (ids.isEmpty) return <int, String>{};
    try {
      final rows = await supabase
          .from('cashier')
          .select('id, name')
          .inFilter('id', ids.toList());
      final map = <int, String>{};
      for (final row
          in (rows as List<dynamic>).whereType<Map<String, dynamic>>()) {
        final id = _toInt(row['id']);
        final name = row['name']?.toString().trim();
        if (id != null && name != null && name.isNotEmpty) {
          map[id] = name;
        }
      }
      return map;
    } catch (_) {
      try {
        final offlineRepo = OfflineShiftRepository();
        await offlineRepo.init();
        final cached = await offlineRepo.getCachedCashiers();
        final map = <int, String>{};
        for (final row in cached) {
          final id = _toInt(row['id']);
          final name = row['name']?.toString().trim();
          if (id != null &&
              ids.contains(id) &&
              name != null &&
              name.isNotEmpty) {
            map[id] = name;
          }
        }
        return map;
      } catch (_) {
        return <int, String>{};
      }
    }
  }

  Future<void> _printShiftReport({
    required Map<String, dynamic> shift,
    required List<Map<String, dynamic>> orders,
    required String cashierName,
  }) async {
    final shiftId = (shift['id'] as num?)?.toInt() ?? 0;

    final shiftTotal = orders.fold<num>(
      0,
      (sum, order) =>
          sum +
          ((order['total_price'] as num?) ??
              (order['total_amount'] as num?) ??
              0),
    );

    final aggregatedItems = <String, Map<String, dynamic>>{};
    for (final order in orders) {
      final orderId = _toInt(order['id']);
      if (orderId == null) continue;
      final orderItems = await _fetchOrderItems(orderId, orderSnapshot: order);
      for (final item in orderItems) {
        final baseKey = 'item:${item.product.name}|${item.product.price}';
        final entry = aggregatedItems.putIfAbsent(baseKey, () {
          return <String, dynamic>{
            'name': item.product.name,
            'qty': 0,
            'subtotal': 0.0,
            'addons': <Map<String, dynamic>>[],
          };
        });
        final baseSubtotal = item.product.price * item.quantity;
        entry['qty'] = ((entry['qty'] as num?)?.toInt() ?? 0) + item.quantity;
        entry['subtotal'] =
            ((entry['subtotal'] as num?)?.toDouble() ?? 0) + baseSubtotal;

        final addons = (entry['addons'] as List<Map<String, dynamic>>);
        for (final group
            in (item.modifiersData ?? <dynamic>[])
                .whereType<Map<String, dynamic>>()) {
          final selected =
              (group['selected_options'] as List<dynamic>? ?? <dynamic>[])
                  .whereType<Map<String, dynamic>>();
          for (final option in selected) {
            final price = (option['price'] as num?)?.toDouble() ?? 0;
            if (price <= 0) continue;
            final name = option['name']?.toString().trim();
            if (name == null || name.isEmpty) continue;
            final addonKey = 'addon:$name|$price';
            final existingIndex = addons.indexWhere(
              (addon) => addon['key'] == addonKey,
            );
            if (existingIndex == -1) {
              addons.add({
                'key': addonKey,
                'name': name,
                'price': price,
                'qty': item.quantity,
              });
            } else {
              final existing = addons[existingIndex];
              existing['qty'] =
                  ((existing['qty'] as num?)?.toInt() ?? 0) + item.quantity;
            }
          }
        }
      }
    }

    final lines =
        aggregatedItems.values
            .map((entry) {
              final addons = (entry['addons'] as List<Map<String, dynamic>>)
                  .map((addon) {
                    final qty = (addon['qty'] as num?)?.toInt() ?? 1;
                    final price = (addon['price'] as num?)?.toDouble() ?? 0;
                    return <String, dynamic>{
                      'name': qty > 1
                          ? '${addon['name']} x$qty'
                          : '${addon['name']}',
                      'price': qty * price,
                    };
                  })
                  .toList(growable: false);
              return <String, dynamic>{
                'name': entry['name'],
                'qty': entry['qty'],
                'subtotal': entry['subtotal'],
                'addons': addons,
              };
            })
            .toList(growable: false)
          ..sort(
            (a, b) => (a['name'] ?? '').toString().compareTo(
              (b['name'] ?? '').toString(),
            ),
          );

    final startedAt = shift['started_at'];
    final endedAt = shift['ended_at'];
    final cashierName = shift['current_cashier_id']?.toString() ?? '-';
    final cashTotal = orders.fold<num>(0, (sum, order) {
      final method = (order['payment_method'] ?? '').toString().toLowerCase();
      if (method != 'cash') return sum;
      return sum +
          ((order['total_price'] as num?) ??
              (order['total_amount'] as num?) ??
              0);
    });
    final qrisTotal = orders.fold<num>(0, (sum, order) {
      final method = (order['payment_method'] ?? '').toString().toLowerCase();
      if (method != 'qris') return sum;
      return sum +
          ((order['total_price'] as num?) ??
              (order['total_amount'] as num?) ??
              0);
    });

    await ThermalPrinterService.instance.printShiftReceipt(
      shiftId: shiftId,
      cashierName: cashierName,
      openedAt: startedAt == null
          ? '-'
          : '${_onlineDateLabel(startedAt)} ${_onlineTimeLabel(startedAt)}',
      closedAt: endedAt == null
          ? 'OPEN'
          : '${_onlineDateLabel(endedAt)} ${_onlineTimeLabel(endedAt)}',
      items: lines,
      totalOrders: orders.length,
      cashTotal: cashTotal,
      qrisTotal: qrisTotal,
      total: shiftTotal,
    );
  }

  Future<void> _showShiftOrderDetailsModal(Map<String, dynamic> order) async {
    final orderId = (order['id'] as num?)?.toInt();
    if (orderId == null) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('Order #$orderId details'),
          content: SizedBox(
            width: 520,
            child: FutureBuilder<List<_OnlineOrderItem>>(
              future: _fetchOrderItems(orderId, orderSnapshot: order),
              builder: (context, snapshot) {
                final items = snapshot.data ?? <_OnlineOrderItem>[];
                if (snapshot.connectionState == ConnectionState.waiting &&
                    items.isEmpty) {
                  return const SizedBox(
                    height: 180,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Customer: ${order['customer_name'] ?? 'Guest'}'),
                    Text(
                      'Total: ${_formatRupiah((order['total_price'] as num?) ?? (order['total_amount'] as num?) ?? 0)}',
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Items',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: items.isEmpty
                          ? const Text('No order items found.')
                          : ListView.separated(
                              shrinkWrap: true,
                              itemCount: items.length,
                              separatorBuilder: (_, __) => const Divider(),
                              itemBuilder: (_, index) {
                                final item = items[index];
                                return ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(item.product.name),
                                  subtitle: Text(
                                    _onlineOrderItemSubtitle(item),
                                  ),
                                  trailing: Text('x${item.quantity}'),
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
    String selectedTab = 'orders';
    int? selectedOrderId;
    int? selectedShiftId;

    final offlinePending = await context
        .read<CartProvider>()
        .getPendingOfflineOrders();
    final shiftRowsFuture = _fetchShiftRowsForReport();

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

                    Widget ordersTab() {
                      return Row(
                        children: [
                          Container(
                            width: 430,
                            decoration: BoxDecoration(
                              border: Border(
                                right: BorderSide(color: Colors.blue.shade100),
                              ),
                              color: Colors.white,
                            ),
                            child: filtered.isEmpty
                                ? const Center(child: Text('No orders found.'))
                                : ListView(
                                    padding: const EdgeInsets.all(12),
                                    children: grouped.entries.expand((entry) {
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

                                      final tiles = entry.value.map((order) {
                                        final orderId = order['id'];
                                        final customer =
                                            order['customer_name']
                                                    ?.toString()
                                                    .trim()
                                                    .isNotEmpty ==
                                                true
                                            ? order['customer_name']
                                            : 'Guest';
                                        final status = (order['status'] ?? '-')
                                            .toString();
                                        final source =
                                            (order['order_source'] ?? '-')
                                                .toString();
                                        final total =
                                            (order['total_price'] as num?) ??
                                            (order['total_amount'] as num?) ??
                                            0;
                                        final isSelected =
                                            (order['id'] as num?)?.toInt() ==
                                            selectedOrderId;
                                        return Card(
                                          elevation: 0,
                                          margin: const EdgeInsets.symmetric(
                                            vertical: 4,
                                          ),
                                          color: isSelected
                                              ? Colors.blue.withOpacity(0.08)
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
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    'Order #${selectedOrder['id']} • ${selectedOrder['customer_name'] ?? 'Guest'}',
                                                    style: const TextStyle(
                                                      fontSize: 20,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                OutlinedButton.icon(
                                                  onPressed: () async {
                                                    final confirmed =
                                                        await showDialog<bool>(
                                                          context: context,
                                                          builder: (confirmContext) {
                                                            return AlertDialog(
                                                              title: const Text(
                                                                'Delete order?',
                                                              ),
                                                              content: Text(
                                                                'Are you sure you want to delete order #${selectedOrder['id']}?',
                                                              ),
                                                              actions: [
                                                                TextButton(
                                                                  onPressed: () =>
                                                                      Navigator.of(
                                                                        confirmContext,
                                                                      ).pop(
                                                                        false,
                                                                      ),
                                                                  child:
                                                                      const Text(
                                                                        'Cancel',
                                                                      ),
                                                                ),
                                                                ElevatedButton(
                                                                  onPressed: () =>
                                                                      Navigator.of(
                                                                        confirmContext,
                                                                      ).pop(
                                                                        true,
                                                                      ),
                                                                  child:
                                                                      const Text(
                                                                        'Delete',
                                                                      ),
                                                                ),
                                                              ],
                                                            );
                                                          },
                                                        ) ??
                                                        false;
                                                    if (!confirmed) return;

                                                    try {
                                                      await supabase
                                                          .from('orders')
                                                          .update({
                                                            'deleted_at':
                                                                DateTime.now()
                                                                    .toIso8601String(),
                                                            'status':
                                                                OrderStatus
                                                                    .cancelled,
                                                          })
                                                          .eq(
                                                            'id',
                                                            (selectedOrder['id']
                                                                    as num)
                                                                .toInt(),
                                                          );
                                                      if (!mounted) return;
                                                      setDialogState(() {
                                                        selectedOrderId = null;
                                                      });
                                                      _showDropdownSnackbar(
                                                        'Order deleted.',
                                                      );
                                                    } catch (error) {
                                                      if (!mounted) return;
                                                      _showDropdownSnackbar(
                                                        'Failed to delete order: $error',
                                                        isError: true,
                                                      );
                                                    }
                                                  },
                                                  icon: const Icon(
                                                    Icons.delete_outline,
                                                  ),
                                                  label: const Text('Delete'),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              'Status: ${(selectedOrder['status'] ?? '-').toString().toUpperCase()} • Source: ${(selectedOrder['order_source'] ?? '-').toString().toUpperCase()}',
                                              style: TextStyle(
                                                color: Colors.blue.shade700,
                                              ),
                                            ),
                                            if ((selectedOrder['notes'] ?? '')
                                                .toString()
                                                .isNotEmpty)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 8,
                                                ),
                                                child: Text(
                                                  'Notes: ${selectedOrder['notes']}',
                                                ),
                                              ),
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 8,
                                              ),
                                              child: Text(
                                                'Total: ${_formatRupiah(total)}',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
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
                                                      separatorBuilder:
                                                          (_, __) =>
                                                              const Divider(),
                                                      itemBuilder: (_, index) {
                                                        final item =
                                                            items[index];
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
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      );
                    }

                    Widget shiftTab() {
                      return FutureBuilder<List<Map<String, dynamic>>>(
                        future: shiftRowsFuture,
                        builder: (context, shiftSnapshot) {
                          final shifts =
                              shiftSnapshot.data ?? <Map<String, dynamic>>[];

                          if (selectedShiftId != null &&
                              shifts.every(
                                (shift) =>
                                    (shift['id'] as num?)?.toInt() !=
                                    selectedShiftId,
                              )) {
                            selectedShiftId = null;
                          }
                          selectedShiftId ??= shifts.isEmpty
                              ? null
                              : (shifts.first['id'] as num?)?.toInt();

                          final selectedShift = selectedShiftId == null
                              ? null
                              : shifts.firstWhere(
                                  (shift) =>
                                      (shift['id'] as num?)?.toInt() ==
                                      selectedShiftId,
                                  orElse: () => <String, dynamic>{},
                                );

                          final selectedShiftOrders = selectedShiftId == null
                              ? <Map<String, dynamic>>[]
                              : rawOrders
                                    .where((order) {
                                      final status = (order['status'] ?? '')
                                          .toString();
                                      final isDeleted =
                                          order['deleted_at'] != null;
                                      return (order['shift_id'] as num?)
                                                  ?.toInt() ==
                                              selectedShiftId &&
                                          status == OrderStatus.completed &&
                                          !isDeleted;
                                    })
                                    .toList(growable: false);

                          final shiftTotal = selectedShiftOrders.fold<num>(
                            0,
                            (sum, order) =>
                                sum +
                                ((order['total_price'] as num?) ??
                                    (order['total_amount'] as num?) ??
                                    0),
                          );

                          final cashierIds = <int>{
                            for (final shift in shifts) ...[
                              if (_toInt(shift['opened_by']) != null)
                                _toInt(shift['opened_by'])!,
                              if (_toInt(shift['closed_by']) != null)
                                _toInt(shift['closed_by'])!,
                              if (_toInt(shift['current_cashier_id']) != null)
                                _toInt(shift['current_cashier_id'])!,
                            ],
                          };

                          return FutureBuilder<Map<int, String>>(
                            future: _fetchCashierNamesByIds(cashierIds),
                            builder: (context, cashierSnapshot) {
                              final cashierNames =
                                  cashierSnapshot.data ?? <int, String>{};
                              String cashierNameFor(dynamic rawId) {
                                final id = _toInt(rawId);
                                if (id == null) return '-';
                                return cashierNames[id] ?? '#$id';
                              }

                              return Row(
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
                                    child: shifts.isEmpty
                                        ? const Center(
                                            child: Text('No shifts found.'),
                                          )
                                        : ListView.builder(
                                            padding: const EdgeInsets.all(12),
                                            itemCount: shifts.length,
                                            itemBuilder: (_, index) {
                                              final shift = shifts[index];
                                              final shiftId =
                                                  (shift['id'] as num?)
                                                      ?.toInt();
                                              final isSelected =
                                                  shiftId == selectedShiftId;
                                              final orderCount = rawOrders
                                                  .where((order) {
                                                    final status =
                                                        (order['status'] ?? '')
                                                            .toString();
                                                    final isDeleted =
                                                        order['deleted_at'] !=
                                                        null;
                                                    return (order['shift_id']
                                                                    as num?)
                                                                ?.toInt() ==
                                                            shiftId &&
                                                        status ==
                                                            OrderStatus
                                                                .completed &&
                                                        !isDeleted;
                                                  })
                                                  .length;
                                              final shiftOrderTotal = rawOrders
                                                  .where((order) {
                                                    final status =
                                                        (order['status'] ?? '')
                                                            .toString();
                                                    final isDeleted =
                                                        order['deleted_at'] !=
                                                        null;
                                                    return (order['shift_id']
                                                                    as num?)
                                                                ?.toInt() ==
                                                            shiftId &&
                                                        status ==
                                                            OrderStatus
                                                                .completed &&
                                                        !isDeleted;
                                                  })
                                                  .fold<num>(
                                                    0,
                                                    (sum, order) =>
                                                        sum +
                                                        ((order['total_price']
                                                                as num?) ??
                                                            (order['total_amount']
                                                                as num?) ??
                                                            0),
                                                  );
                                              return Card(
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
                                                  onTap: shiftId == null
                                                      ? null
                                                      : () => setDialogState(
                                                          () =>
                                                              selectedShiftId =
                                                                  shiftId,
                                                        ),
                                                  title: Text(
                                                    'Shift #${shift['id']}',
                                                  ),
                                                  subtitle: Text(
                                                    '${_shiftDateTimeRangeLabel(shift['started_at'], shift['ended_at'])}\nOrders: $orderCount • Total: ${_formatRupiah(shiftOrderTotal)}',
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                  ),
                                  Expanded(
                                    child:
                                        selectedShift == null ||
                                            selectedShift.isEmpty
                                        ? const Center(
                                            child: Text(
                                              'Select a shift to see details.',
                                            ),
                                          )
                                        : Padding(
                                            padding: const EdgeInsets.all(16),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        'Shift #${selectedShift['id']}',
                                                        style: const TextStyle(
                                                          fontSize: 20,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                    ),
                                                    ElevatedButton.icon(
                                                      onPressed: () async {
                                                        try {
                                                          await _printShiftReport(
                                                            shift:
                                                                selectedShift,
                                                            orders:
                                                                selectedShiftOrders,
                                                            cashierName:
                                                                cashierNameFor(
                                                                  selectedShift['current_cashier_id'],
                                                                ),
                                                          );
                                                          if (!mounted) return;
                                                          _showDropdownSnackbar(
                                                            'Shift report printed.',
                                                          );
                                                        } catch (error) {
                                                          if (!mounted) return;
                                                          _showDropdownSnackbar(
                                                            'Failed to print shift report: $error',
                                                            isError: true,
                                                          );
                                                        }
                                                      },
                                                      icon: const Icon(
                                                        Icons.print,
                                                      ),
                                                      label: const Text(
                                                        'Print',
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  'Cashier: ${cashierNameFor(selectedShift['current_cashier_id'])}',
                                                ),
                                                Text(
                                                  'Opened: ${selectedShift['started_at'] == null ? '-' : _onlineDateLabel(selectedShift['started_at'])} ${_onlineTimeLabel(selectedShift['started_at'])}',
                                                ),
                                                Text(
                                                  'Closed: ${selectedShift['ended_at'] == null ? 'OPEN' : '${_onlineDateLabel(selectedShift['ended_at'])} ${_onlineTimeLabel(selectedShift['ended_at'])}'}',
                                                ),
                                                Text(
                                                  'Opened by: ${cashierNameFor(selectedShift['opened_by'])}',
                                                ),
                                                Text(
                                                  'Closed by: ${cashierNameFor(selectedShift['closed_by'])}',
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  'Completed orders: ${selectedShiftOrders.length} • Total: ${_formatRupiah(shiftTotal)}',
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                const SizedBox(height: 12),
                                                Expanded(
                                                  child:
                                                      selectedShiftOrders
                                                          .isEmpty
                                                      ? const Center(
                                                          child: Text(
                                                            'No orders in this shift.',
                                                          ),
                                                        )
                                                      : ListView.separated(
                                                          itemCount:
                                                              selectedShiftOrders
                                                                  .length,
                                                          separatorBuilder:
                                                              (_, __) =>
                                                                  const Divider(),
                                                          itemBuilder: (_, index) {
                                                            final order =
                                                                selectedShiftOrders[index];
                                                            final total =
                                                                (order['total_price']
                                                                    as num?) ??
                                                                (order['total_amount']
                                                                    as num?) ??
                                                                0;
                                                            return ListTile(
                                                              onTap: () =>
                                                                  _showShiftOrderDetailsModal(
                                                                    order,
                                                                  ),
                                                              title: Text(
                                                                'Order #${order['id']} • ${order['customer_name'] ?? 'Guest'}',
                                                              ),
                                                              subtitle: Text(
                                                                '${(order['status'] ?? '-').toString().toUpperCase()} • ${_onlineTimeLabel(order['created_at'])}',
                                                              ),
                                                              trailing: Text(
                                                                _formatRupiah(
                                                                  total,
                                                                ),
                                                              ),
                                                            );
                                                          },
                                                        ),
                                                ),
                                              ],
                                            ),
                                          ),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      );
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
                                  Text(
                                    selectedTab == 'orders'
                                        ? 'All Orders'
                                        : 'Shift Report',
                                    style: const TextStyle(
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
                              Row(
                                children: [
                                  ChoiceChip(
                                    label: const Text('Orders'),
                                    selected: selectedTab == 'orders',
                                    onSelected: (_) => setDialogState(
                                      () => selectedTab = 'orders',
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  ChoiceChip(
                                    label: const Text('Shift Report'),
                                    selected: selectedTab == 'shift_report',
                                    onSelected: (_) => setDialogState(
                                      () => selectedTab = 'shift_report',
                                    ),
                                  ),
                                ],
                              ),
                              if (selectedTab == 'orders') ...[
                                const SizedBox(height: 12),
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
                            ],
                          ),
                        ),
                        Expanded(
                          child: selectedTab == 'orders'
                              ? ordersTab()
                              : shiftTab(),
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
                                            if (orderNotes.trim().isNotEmpty)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 8,
                                                ),
                                                child: Text(
                                                  'Order note: $orderNotes',
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
                                                  onPressed: items.isEmpty
                                                      ? null
                                                      : () async {
                                                          final updated =
                                                              await _updateOrderStatusIfPaid(
                                                                orderId,
                                                                OrderStatus
                                                                    .active,
                                                              );
                                                          if (!context
                                                              .mounted) {
                                                            return;
                                                          }
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
                                                              modifiers: item
                                                                  .modifiers,
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
    } finally {
      pendingOrdersScrollController.dispose();
      _isOnlineOrdersDialogOpen = false;
    }
  }
}
