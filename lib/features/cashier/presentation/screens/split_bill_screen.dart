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
  const SplitBillScreen({super.key, this.onRequestPayment, this.onGroupPaid});

  final Future<SplitGroupPaymentResult?> Function(double total)?
  onRequestPayment;
  final Future<void> Function()? onGroupPaid;

  @override
  State<SplitBillScreen> createState() => _SplitBillScreenState();
}

class _SplitBillScreenState extends State<SplitBillScreen> {
  int? _selectedItemId;
  int _qtyToAssign = 1;

  int _getUnassignedQty(CartItem item, List<GroupItem> allGroupItems) {
    final assigned = allGroupItems
        .where((g) => g.orderItemId == item.id)
        .fold(0, (sum, g) => sum + g.assignedQty);
    return item.quantity - assigned;
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();
    final items = cart.items.values.toList(growable: false);

    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 255, 255, 255),
      appBar: AppBar(
        title: const Text('Split Bill'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        automaticallyImplyLeading: false,
        shape: Border(bottom: BorderSide(color: Colors.grey.shade300)),
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
                      const Text(
                        'Unassigned Items',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const Text(
                        'Select an item, adjust quantity, then tap a group to assign.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (_, index) {
                            final item = items[index];
                            final unassignedQty = _getUnassignedQty(
                              item,
                              cart.groupItems,
                            );
                            final isSelected = _selectedItemId == item.id;

                            // Hide item if all quantities have been assigned to groups
                            if (unassignedQty <= 0 && !isSelected) {
                              return const SizedBox.shrink();
                            }

                            return ListTile(
                              title: Text(item.name),
                              subtitle: Text(
                                'Unassigned: $unassignedQty / ${item.quantity}',
                              ),
                              selected: isSelected,
                              selectedTileColor: Colors.blue.shade50,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              onTap: () {
                                setState(() {
                                  if (isSelected) {
                                    _selectedItemId = null; // Unselect
                                  } else {
                                    if (unassignedQty > 0) {
                                      _selectedItemId = item.id;
                                      _qtyToAssign =
                                          1; // Default to assigning 1
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
                                          onPressed:
                                              _qtyToAssign < unassignedQty
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
                          const Text(
                            'Groups',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          OutlinedButton.icon(
                            onPressed: () {
                              cart.createGroup(
                                'Group ${cart.cartGroups.length + 1}',
                              );
                            },
                            icon: const Icon(Icons.add),
                            label: const Text('Add Group'),
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
                              items,
                            );

                            // Visual feedback that a group can receive the currently selected item
                            final isItemPending = _selectedItemId != null;

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
                                      // Assign the selected item to this group on tap
                                      if (_selectedItemId != null) {
                                        final item = items.firstWhere(
                                          (i) => i.id == _selectedItemId,
                                        );
                                        cart.assignItemToGroup(
                                          item,
                                          group.id,
                                          _qtyToAssign,
                                        );
                                        setState(() {
                                          _selectedItemId = null;
                                          _qtyToAssign = 1;
                                        });
                                      }
                                    },
                                    title: Text(group.groupName),
                                    subtitle: Text(
                                      '${group.paymentStatus.toUpperCase()} • ${groupLines.length} item(s)',
                                    ),
                                    trailing: Wrap(
                                      spacing: 8,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Text(
                                          'Rp ${subtotal.toStringAsFixed(0)}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        if (group.paymentStatus != 'paid')
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
                                            child: const Text('Pay'),
                                          ),
                                      ],
                                    ),
                                  ),
                                  // Expand the contents of the group below the header
                                  if (groupLines.isNotEmpty)
                                    const Divider(height: 1),
                                  ...groupLines.map((line) {
                                    CartItem? assignedItem;
                                    try {
                                      assignedItem = items.firstWhere(
                                        (i) => i.id == line.orderItemId,
                                      );
                                    } catch (_) {}

                                    if (assignedItem == null)
                                      return const SizedBox.shrink();

                                    return ListTile(
                                      dense: true,
                                      title: Text(
                                        '${assignedItem.name} (Qty: ${line.assignedQty})',
                                      ),
                                      trailing: group.paymentStatus == 'paid'
                                          ? null // Hide remove button if group is already paid
                                          : IconButton(
                                              icon: const Icon(
                                                Icons.remove_circle,
                                                color: Colors.red,
                                              ),
                                              tooltip: 'Remove from group',
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

  double _sumGroupSubtotal(List<GroupItem> lines, List<CartItem> cartItems) {
    var total = 0.0;
    for (final line in lines) {
      CartItem? item;
      for (final cartItem in cartItems) {
        if (cartItem.id == line.orderItemId) {
          item = cartItem;
          break;
        }
      }
      if (item == null) continue;
      total += item.price * line.assignedQty;
    }
    return total;
  }
}
