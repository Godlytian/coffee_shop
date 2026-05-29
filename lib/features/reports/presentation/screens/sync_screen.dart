import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:coffee_shop/features/cashier/providers/cart_provider.dart';
import 'package:coffee_shop/core/utils/formatters.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  bool _loading = true;
  Map<String, dynamic> _summary = <String, dynamic>{};
  List<Map<String, dynamic>> _queue = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _logs = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _failed = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final cart = context.read<CartProvider>();
    await cart.refreshConnectionStatus();

    final result = await Future.wait([
      cart.getSyncSummary(),
      cart.getPendingSyncQueue(),
      cart.getSyncLogs(),
      cart.getFailedOfflineOrders(),
    ]);

    if (!mounted) return;
    setState(() {
      _summary = Map<String, dynamic>.from(result[0] as Map);
      _queue = (result[1] as List).whereType<Map<String, dynamic>>().toList(
        growable: false,
      );
      _logs = (result[2] as List).whereType<Map<String, dynamic>>().toList(
        growable: false,
      );
      _failed = (result[3] as List).whereType<Map<String, dynamic>>().toList(
        growable: false,
      );
      _loading = false;
    });
  }

  String _formatTimelineTime(String? iso) {
    if (iso == null || iso.isEmpty) return '-';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $hh:$mm:$ss';
  }

  Future<void> _showLogPayload(Map<String, dynamic> log) async {
    final payload = Map<String, dynamic>.from(
      log['payload'] as Map? ?? <String, dynamic>{},
    );

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Sync Log Payload'),
          content: SizedBox(
            width: 760,
            child: payload.isEmpty
                ? const Text('No payload captured for this log entry.')
                : SingleChildScrollView(
                    child: SelectableText(
                      const JsonEncoder.withIndent('  ').convert(payload),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
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

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();
    final pendingOrders = (_summary['pending_orders'] as num?)?.toInt() ?? 0;
    final pendingShiftEvents =
        (_summary['pending_shift_events'] as num?)?.toInt() ?? 0;
    final pendingTotal = (_summary['pending_total'] as num?)?.toInt() ?? 0;
    final pendingValue = (_summary['pending_value'] as num?)?.toDouble() ?? 0;
    final failedTotal = (_summary['failed_total'] as num?)?.toInt() ?? 0;
    final lastSync = _summary['last_successful_sync_at'] as DateTime?;

    return Scaffold(
      appBar: AppBar(title: const Text('Sync Status')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            cart.hasNetworkConnection
                                ? (cart.isServerReachable
                                      ? '🟢 Online'
                                      : '🟡 Server unreachable')
                                : '🔴 Offline',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            cart.hasNetworkConnection
                                ? (cart.isServerReachable
                                      ? 'Network connected and backend reachable.'
                                      : 'Device has internet, but backend is unreachable.')
                                : 'No network connectivity detected.',
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Last successful sync: ${lastSync == null ? 'Never' : lastSync.toLocal().toString()}',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Summary',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text('Pending items: $pendingTotal'),
                          Text('Pending orders: $pendingOrders'),
                          Text('Pending shift events: $pendingShiftEvents'),
                          Text(
                            'Pending sync value: ${CurrencyFormatters.formatRupiah(pendingValue)}',
                          ),
                          Text('Failed items: $failedTotal'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            await context
                                .read<CartProvider>()
                                .syncOfflineOrders();
                            await _reload();
                          },
                          icon: const Icon(Icons.sync),
                          label: const Text('Force Sync / Sync Now'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () async {
                          await context.read<CartProvider>().clearSyncLogs();
                          await _reload();
                        },
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Clear logs'),
                      ),
                    ],
                  ),
                  if (cart.isSyncingOfflineOrders) ...[
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Syncing ${cart.syncProcessedItems} of ${cart.syncTotalItems} items...',
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: cart.syncTotalItems == 0
                                  ? null
                                  : cart.syncProcessedItems /
                                        cart.syncTotalItems,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    'Failed Items',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  if (_failed.isEmpty)
                    const Text('No failed items.')
                  else
                    ..._failed.map((item) {
                      final localTxnId =
                          item['local_txn_id']?.toString() ?? '-';
                      final rawReason =
                          item['failure_reason']?.toString() ?? '-';
                      final friendlyReason = context
                          .read<CartProvider>()
                          .toFriendlySyncError(rawReason);
                      return Card(
                        child: ListTile(
                          title: Text('Failed item $localTxnId'),
                          subtitle: Text(friendlyReason),
                          trailing: Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: () async {
                                  await context
                                      .read<CartProvider>()
                                      .retryFailedOfflineOrder(localTxnId);
                                  await _reload();
                                },
                                child: const Text('Retry'),
                              ),
                              TextButton(
                                onPressed: () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (dialogContext) => AlertDialog(
                                      title: const Text('Discard failed item'),
                                      content: const Text(
                                        'Admin action: discard this blocked local record so other data can sync.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.of(
                                            dialogContext,
                                          ).pop(false),
                                          child: const Text('Cancel'),
                                        ),
                                        ElevatedButton(
                                          onPressed: () => Navigator.of(
                                            dialogContext,
                                          ).pop(true),
                                          child: const Text('Discard (Admin)'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok != true) return;
                                  await context
                                      .read<CartProvider>()
                                      .deleteFailedOfflineOrder(localTxnId);
                                  await _reload();
                                },
                                child: const Text('Discard (Admin)'),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  const SizedBox(height: 12),
                  Text(
                    'Pending Queue (${_queue.length})',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_queue.isEmpty)
                    const Text('No pending sync items.')
                  else
                    ..._queue.map(
                      (item) => Card(
                        child: ListTile(
                          title: Text(
                            '${item['event_type'] ?? '-'} • ${item['local_txn_id'] ?? '-'}',
                          ),
                          subtitle: Text(
                            'Occurred: ${item['occurred_at_epoch'] ?? '-'}',
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'Sync Logs (${_logs.length})',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_logs.isEmpty)
                    const Text('No sync logs yet.')
                  else
                    ..._logs.map((log) {
                      final level = (log['level'] ?? '-').toString();
                      final createdAt = _formatTimelineTime(
                        log['created_at']?.toString(),
                      );
                      final color = level == 'error'
                          ? Colors.red
                          : level == 'warning'
                          ? Colors.orange
                          : level == 'success'
                          ? Colors.green
                          : Colors.blue;
                      return Card(
                        child: InkWell(
                          onTap: () => _showLogPayload(log),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(width: 4, height: 72, color: color),
                              Expanded(
                                child: ListTile(
                                  dense: true,
                                  title: Text(
                                    '[${log['level'] ?? '-'}] ${log['message'] ?? '-'}',
                                  ),
                                  subtitle: Text(
                                    '$createdAt • ${log['local_txn_id'] ?? '-'}\nTap to view payload',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
    );
  }
}
