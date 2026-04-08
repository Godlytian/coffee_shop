import 'dart:convert';

import 'package:coffee_shop/core/services/sync_manager.dart';
import 'package:coffee_shop/features/cashier/providers/cart_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();
    final statusColor = cart.isSyncingOfflineOrders
        ? Colors.amber
        : (cart.hasNetworkConnection && cart.isServerReachable
              ? Colors.green
              : Colors.red);

    return Scaffold(
      appBar: AppBar(title: const Text('Sync Status')),
      body: Column(
        children: [
          ListTile(
            leading: CircleAvatar(backgroundColor: statusColor),
            title: Text(
              cart.isSyncingOfflineOrders
                  ? 'Syncing'
                  : (cart.hasNetworkConnection && cart.isServerReachable
                        ? 'Synced'
                        : 'Offline'),
            ),
            subtitle: Text('Pending queue: ${cart.pendingOfflineOrderCount}'),
            trailing: FilledButton(
              onPressed: () async {
                await SyncManager().syncPendingOrders();
                await cart.syncOfflineOrders();
              },
              child: const Text('Manual Sync'),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: cart.getSyncLogs(),
              builder: (context, snapshot) {
                final rows = snapshot.data ?? <Map<String, dynamic>>[];
                if (rows.isEmpty) {
                  return const Center(child: Text('No sync logs yet'));
                }
                return ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, index) {
                    final row = rows[index];
                    final level =
                        row['level']?.toString().toLowerCase() ?? 'info';
                    return ListTile(
                      leading: Icon(
                        level == 'error' ? Icons.error : Icons.check_circle,
                        color: level == 'error' ? Colors.red : Colors.green,
                      ),
                      title: Text(row['message']?.toString() ?? '-'),
                      subtitle: Text(row['created_at']?.toString() ?? '-'),
                      onTap: level != 'error'
                          ? null
                          : () {
                              showDialog<void>(
                                context: context,
                                builder: (dialogContext) => AlertDialog(
                                  title: const Text('Sync Log Details'),
                                  content: SingleChildScrollView(
                                    child: Text(
                                      'Error: ${row['message']}\n\nPayload:\n${const JsonEncoder.withIndent('  ').convert(row['payload'] ?? row['payload_json'])}',
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext),
                                      child: const Text('Close'),
                                    ),
                                  ],
                                ),
                              );
                            },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
