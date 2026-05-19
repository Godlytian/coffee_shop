import 'package:coffee_shop/core/utils/formatters.dart';
import 'package:coffee_shop/features/cashier/models/models.dart';
import 'package:coffee_shop/features/cashier/providers/cart_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class SplitGroupPaymentResult {
  final String method;
  final num totalPaymentReceived;
  final num changeAmount;

  const SplitGroupPaymentResult({
    required this.method,
    required this.totalPaymentReceived,
    required this.changeAmount,
  });
}

class SplitBillScreen extends StatefulWidget {
  const SplitBillScreen({
    super.key,
    this.onRequestPayment,
    this.onGroupPaid,
    this.onConfirmSplit,
  });

  final Future<SplitGroupPaymentResult?> Function(double total)? onRequestPayment;
  final Future<void> Function()? onGroupPaid;

  /// When provided, a "Pisah Nota" button is shown in the app bar. Calling it
  /// will invoke this callback (which creates separate orders from the current
  /// groups). Return true to auto-pop the screen on success.
  final Future<bool> Function()? onConfirmSplit;

  @override
  State<SplitBillScreen> createState() => _SplitBillScreenState();
}

class _SplitBillScreenState extends State<SplitBillScreen> {
  /// The cart map key of the currently selected item (unique per modifier variant).
  String? _selectedCartKey;
  int _qtyToAssign = 1;
  bool _isConfirming = false;

  double _unitPrice(CartItem item) {
    final modifiersData = item.modifiersData;
    if (modifiersData == null) return item.price;
    final extra = modifiersData
        .whereType<Map<String, dynamic>>()
        .fold<double>(0.0, (sum, modifier) {
      final selected =
          modifier['selected_options'] as List<dynamic>? ?? const <dynamic>[];
      return sum +
          selected.whereType<Map<String, dynamic>>().fold<double>(
            0.0,
            (s, opt) => s + ((opt['price'] as num?)?.toDouble() ?? 0.0),
          );
    });
    return item.price + extra;
  }

  List<String> _modifierNames(CartItem item) {
    final data = item.modifiersData;
    if (data == null) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .expand((modifier) {
          final selected =
              modifier['selected_options'] as List<dynamic>? ?? const [];
          return selected
              .whereType<Map<String, dynamic>>()
              .map((opt) => opt['name']?.toString() ?? '')
              .where((name) => name.isNotEmpty);
        })
        .toList(growable: false);
  }

  int _getUnassignedQty(
    String cartLineKey,
    int totalQty,
    List<GroupItem> allGroupItems,
  ) {
    final assigned = allGroupItems
        .where((g) => g.cartLineKey == cartLineKey)
        .fold(0, (sum, g) => sum + g.assignedQty);
    return totalQty - assigned;
  }

  Future<void> _handleConfirmSplit() async {
    final cart = context.read<CartProvider>();
    final groups = cart.cartGroups;
    final groupItems = cart.groupItems;

    final hasAssignments =
        groups.isNotEmpty &&
        groupItems.any((gi) => gi.assignedQty > 0);

    if (!hasAssignments) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tetapkan item ke grup terlebih dahulu.'),
        ),
      );
      return;
    }

    setState(() => _isConfirming = true);
    try {
      final success = await widget.onConfirmSplit!();
      if (success && mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _isConfirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();
    final entries = cart.items.entries.toList(growable: false);
    final isPisahMode = widget.onConfirmSplit != null;

    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 255, 255, 255),
      appBar: AppBar(
        title: Text(isPisahMode ? 'Pisah Nota' : 'Split Bill'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        automaticallyImplyLeading: isPisahMode,
        shape: Border(bottom: BorderSide(color: Colors.grey.shade300)),
        actions: [
          if (isPisahMode)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: _isConfirming ? null : _handleConfirmSplit,
                child: _isConfirming
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Pisah Nota'),
              ),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isPisahMode ? 'Item Pesanan' : 'Unassigned Items',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        isPisahMode
                            ? 'Pilih item, atur jumlah, lalu ketuk grup tujuan.'
                            : 'Select an item, adjust quantity, then tap a group to assign.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView.builder(
                          itemCount: entries.length,
                          itemBuilder: (_, index) {
                            final entry = entries[index];
                            final cartKey = entry.key;
                            final item = entry.value;
                            final unassignedQty = _getUnassignedQty(
                              cartKey,
                              item.quantity,
                              cart.groupItems,
                            );
                            final isSelected = _selectedCartKey == cartKey;

                            if (unassignedQty <= 0 && !isSelected) {
                              return const SizedBox.shrink();
                            }

                            final unitPrice = _unitPrice(item);
                            final priceLabel =
                                CurrencyFormatters.formatRupiah(unitPrice);
                            final modNames = _modifierNames(item);

                            return ListTile(
                              title: Text(item.name),
                              subtitle: Text(
                                '$priceLabel  •  Belum ditugaskan: $unassignedQty / ${item.quantity}'
                                '${modNames.isNotEmpty ? '\n${modNames.join(', ')}' : ''}',
                                maxLines: 2,
                              ),
                              selected: isSelected,
                              selectedTileColor: Colors.blue.shade50,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              onTap: () {
                                setState(() {
                                  if (isSelected) {
                                    _selectedCartKey = null;
                                  } else {
                                    if (unassignedQty > 0) {
                                      _selectedCartKey = cartKey;
                                      _qtyToAssign = 1;
                                    }
                                  }
                                });
                              },
                              trailing: isSelected
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(
                                            Icons.remove_circle_outline,
                                          ),
                                          onPressed: _qtyToAssign > 1
                                              ? () => setState(
                                                  () => _qtyToAssign--,
                                                )
                                              : null,
                                        ),
                                        Text(
                                          '$_qtyToAssign',
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.add_circle_outline,
                                          ),
                                          onPressed: _qtyToAssign < unassignedQty
                                              ? () => setState(
                                                  () => _qtyToAssign++,
                                                )
                                              : null,
                                        ),
                                      ],
                                    )
                                  : null,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            isPisahMode ? 'Grup Pisah' : 'Groups',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          OutlinedButton.icon(
                            onPressed: () {
                              cart.createGroup(
                                'Grup ${cart.cartGroups.length + 1}',
                              );
                            },
                            icon: const Icon(Icons.add),
                            label: Text(isPisahMode ? 'Tambah Grup' : 'Add Group'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView.builder(
                          itemCount: cart.cartGroups.length,
                          itemBuilder: (_, index) {
                            final group = cart.cartGroups[index];
                            final groupLines = cart.groupItems
                                .where((item) => item.groupId == group.id)
                                .toList(growable: false);
                            final subtotal = _sumGroupSubtotal(
                              groupLines,
                              entries,
                            );

                            final isItemPending = _selectedCartKey != null;

                            return Card(
                              color: isItemPending
                                  ? Colors.green.shade50
                                  : null,
                              elevation: isItemPending ? 2 : 0,
                              shape: RoundedRectangleBorder(
                                side: BorderSide(
                                  color: isItemPending
                                      ? Colors.green
                                      : Colors.grey.shade300,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Column(
                                children: [
                                  ListTile(
                                    onTap: () {
                                      if (_selectedCartKey != null) {
                                        final entry = entries.firstWhere(
                                          (e) => e.key == _selectedCartKey,
                                        );
                                        cart.assignItemToGroup(
                                          entry.value,
                                          group.id,
                                          _qtyToAssign,
                                          cartLineKey: _selectedCartKey!,
                                        );
                                        setState(() {
                                          _selectedCartKey = null;
                                          _qtyToAssign = 1;
                                        });
                                      }
                                    },
                                    title: Text(group.groupName),
                                    subtitle: Text(
                                      isPisahMode
                                          ? '${groupLines.length} item(s)'
                                          : '${group.paymentStatus.toUpperCase()} • ${groupLines.length} item(s)',
                                    ),
                                    trailing: Wrap(
                                      spacing: 8,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Text(
                                          CurrencyFormatters.formatRupiah(subtotal),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        if (!isPisahMode &&
                                            group.paymentStatus != 'paid')
                                          FilledButton(
                                            onPressed: () async {
                                              final requestPayment =
                                                  widget.onRequestPayment;
                                              if (requestPayment != null) {
                                                final payment =
                                                    await requestPayment(
                                                      subtotal,
                                                    );
                                                if (!mounted ||
                                                    payment == null) {
                                                  return;
                                                }
                                              }

                                              cart.processGroupPayment(
                                                group.id,
                                                subtotal,
                                              );
                                              final onGroupPaid =
                                                  widget.onGroupPaid;
                                              if (onGroupPaid != null) {
                                                await onGroupPaid();
                                              }
                                            },
                                            child: const Text('Bayar'),
                                          ),
                                        if (!isPisahMode)
                                          IconButton(
                                            icon: const Icon(
                                              Icons.delete_outline,
                                              color: Colors.red,
                                            ),
                                            tooltip: 'Hapus grup',
                                            onPressed: () =>
                                                cart.removeGroup(group.id),
                                          ),
                                        if (isPisahMode)
                                          IconButton(
                                            icon: const Icon(
                                              Icons.delete_outline,
                                              color: Colors.red,
                                            ),
                                            tooltip: 'Hapus grup',
                                            onPressed: () =>
                                                cart.removeGroup(group.id),
                                          ),
                                      ],
                                    ),
                                  ),
                                  if (groupLines.isNotEmpty)
                                    const Divider(height: 1),
                                  ...groupLines.map((line) {
                                    CartItem? assignedItem;
                                    try {
                                      assignedItem = entries
                                          .firstWhere(
                                            (e) => line.cartLineKey.isNotEmpty
                                                ? e.key == line.cartLineKey
                                                : e.value.id == line.orderItemId,
                                          )
                                          .value;
                                    } catch (_) {}

                                    if (assignedItem == null) {
                                      return const SizedBox.shrink();
                                    }

                                    return ListTile(
                                      dense: true,
                                      title: Text(
                                        '${assignedItem.name} (Qty: ${line.assignedQty})',
                                      ),
                                      subtitle: Text(
                                        CurrencyFormatters.formatRupiah(
                                          _unitPrice(assignedItem) * line.assignedQty,
                                        ),
                                      ),
                                      trailing: group.paymentStatus == 'paid'
                                          ? null
                                          : IconButton(
                                              icon: const Icon(
                                                Icons.remove_circle,
                                                color: Colors.red,
                                              ),
                                              tooltip: 'Hapus dari grup',
                                              onPressed: () =>
                                                  cart.removeGroupItem(line.id),
                                            ),
                                    );
                                  }),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _sumGroupSubtotal(
    List<GroupItem> lines,
    List<MapEntry<String, CartItem>> entries,
  ) {
    var total = 0.0;
    for (final line in lines) {
      CartItem? item;
      try {
        item = entries
            .firstWhere(
              (e) => line.cartLineKey.isNotEmpty
                  ? e.key == line.cartLineKey
                  : e.value.id == line.orderItemId,
            )
            .value;
      } catch (_) {}
      if (item == null) continue;
      total += _unitPrice(item) * line.assignedQty;
    }
    return total;
  }
}
