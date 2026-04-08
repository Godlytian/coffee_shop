import 'package:coffee_shop/features/cashier/models/models.dart';
import 'package:coffee_shop/features/cashier/providers/cart_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class SplitBillScreen extends StatefulWidget {
  const SplitBillScreen({super.key});

  @override
  State<SplitBillScreen> createState() => _SplitBillScreenState();
}

class _SplitBillScreenState extends State<SplitBillScreen> {
  String? _selectedGroupId;

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
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (_, index) {
                            final item = items[index];
                            return ListTile(
                              title: Text(item.name),
                              subtitle: Text('Qty ${item.quantity}'),
                              trailing: FilledButton.tonal(
                                onPressed: _selectedGroupId == null
                                    ? null
                                    : () => cart.assignItemToGroup(
                                        item,
                                        _selectedGroupId!,
                                        item.quantity,
                                      ),
                                child: const Text('Assign'),
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
                              setState(() {
                                _selectedGroupId = cart.cartGroups.last.id;
                              });
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
                            final selected = _selectedGroupId == group.id;
                            final groupLines = cart.groupItems
                                .where((item) => item.groupId == group.id)
                                .toList(growable: false);
                            final subtotal = _sumGroupSubtotal(
                              groupLines,
                              items,
                            );
                            return Card(
                              color: selected ? Colors.blue.shade50 : null,
                              child: ListTile(
                                onTap: () =>
                                    setState(() => _selectedGroupId = group.id),
                                title: Text(group.groupName),
                                subtitle: Text(
                                  '${group.paymentStatus.toUpperCase()} • ${groupLines.length} item(s)',
                                ),
                                trailing: Wrap(
                                  spacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text('Rp ${subtotal.toStringAsFixed(0)}'),
                                    if (group.paymentStatus != 'paid')
                                      FilledButton(
                                        onPressed: () =>
                                            cart.processGroupPayment(
                                              group.id,
                                              subtotal,
                                            ),
                                        child: const Text('Pay'),
                                      ),
                                  ],
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
