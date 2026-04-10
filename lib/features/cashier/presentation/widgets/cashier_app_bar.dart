part of 'package:coffee_shop/features/cashier/presentation/screens/cashier_screen.dart';

enum _CloseShiftActiveOrderAction {
  completeInCurrentShift,
  continueInNewShift,
  cancel,
}

extension CashierAppBarMethods on _ProductListScreenState {
  static const String _supabaseUrl = 'https://iasodtouoikaeuxkuecy.supabase.co';
  static const String _supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlhc29kdG91b2lrYWV1eGt1ZWN5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA0ODYxMzIsImV4cCI6MjA4NjA2MjEzMn0.iqm3zxfy-Xl2a_6GDmTj6io8vJW2B3Sr5SHq_4vjJW4';
  static const String _cachedShiftIdKey = 'cached_active_shift_id';
  static const String _cachedCashierIdKey = 'cached_active_cashier_id';
  static const String _courierNumberKey = 'courier_whatsapp_number';
  static const String _courierTemplateKey = 'courier_message_template';
  static const List<String> _courierTemplateTokens = [
    '{order_id}',
    '{customer_name}',
    '{order_type}',
    '{order_total}',
    '{map_link}',
    '{order_items}',
  ];
  static final OfflineShiftRepository _offlineShiftRepository =
      OfflineShiftRepository();

  Widget _buildConnectionBadge({
    required bool networkOk,
    required bool serverOk,
  }) {
    late final Color color;
    late final IconData icon;
    late final String text;

    if (!networkOk) {
      color = Colors.red.shade700;
      icon = Icons.cloud_off;
      text = 'Offline';
    } else if (!serverOk) {
      color = Colors.orange.shade700;
      icon = Icons.warning;
      text = 'Server unreachable';
    } else {
      color = Colors.green.shade700;
      icon = Icons.cloud_done;
      text = 'Online';
    }

    return Chip(
      visualDensity: VisualDensity.compact,
      backgroundColor: color.withOpacity(0.12),
      avatar: Icon(icon, size: 16, color: color),
      label: Text(
        text,
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }

  Future<String> _cashierDisplayName(int cashierId) async {
    try {
      await _offlineShiftRepository.init();
      final cachedCashiers = await _offlineShiftRepository.getCachedCashiers();
      final cached = cachedCashiers.firstWhere(
        (row) => (row['id'] as num?)?.toInt() == cashierId,
        orElse: () => <String, dynamic>{},
      );
      final cachedName = cached['name']?.toString().trim() ?? '';
      if (cachedName.isNotEmpty) {
        return cachedName;
      }
    } catch (_) {}

    try {
      final row = await supabase
          .from('cashier')
          .select('name')
          .eq('id', cashierId)
          .maybeSingle();
      final name = row?['name']?.toString().trim() ?? '';
      if (name.isNotEmpty) {
        return name;
      }
    } catch (_) {}

    return '#$cashierId';
  }

  PreferredSizeWidget _buildCashierAppBar() {
    return AppBar(
      title: Row(
        children: [
          const Text('Ulun'),
          const SizedBox(width: 8),
          Selector<CartProvider, ({bool networkOk, bool serverOk})>(
            selector: (_, cart) => (
              networkOk: cart.hasNetworkConnection,
              serverOk: cart.isServerReachable,
            ),
            builder: (context, status, _) {
              return GestureDetector(
                onTap: _showSyncStatusScreen,
                child: _buildConnectionBadge(
                  networkOk: status.networkOk,
                  serverOk: status.serverOk,
                ),
              );
            },
          ),
        ],
      ),
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      actions: [
        if (_activeCashierId != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: ActionChip(
                avatar: const Icon(Icons.person, size: 18),
                onPressed: _showShiftsDialog,
                label: FutureBuilder<String>(
                  future: _cashierDisplayName(_activeCashierId!),
                  builder: (context, snapshot) {
                    final cashierName = snapshot.data?.trim();
                    final label = cashierName != null && cashierName.isNotEmpty
                        ? 'Cashier: $cashierName'
                        : 'Cashier #$_activeCashierId';
                    return Text(label);
                  },
                ),
              ),
            ),
          ),
        if (_activeShiftId == null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: InkWell(
                onTap: _showShiftsDialog,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Text(
                    'No open shift',
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            ),
          ),
        IconButton(
          tooltip: 'Notification (online order)',
          onPressed: _showOnlinePendingOrdersDialog,
          icon: ValueListenableBuilder<int>(
            valueListenable: _onlinePaidOrdersCountNotifier,
            builder: (context, count, _) {
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.notifications_active),
                  if (count > 0)
                    Positioned(
                      right: -8,
                      top: -8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          count.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        Consumer<CartProvider>(
          builder: (context, cart, _) {
            if (cart.pendingOfflineOrderCount <= 0) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Chip(
                  backgroundColor: Colors.orange.shade100,
                  label: Text(
                    '${cart.pendingOfflineOrderCount} unsynced',
                    style: TextStyle(
                      color: Colors.orange.shade900,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        IconButton(
          tooltip: 'App menu',
          icon: const Icon(Icons.menu),
          onPressed: _showAppMenuDialog,
        ),
      ],
    );
  }

  Future<void> _showAppMenuDialog() async {
    await _refreshStoreSettingsStatus();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final lastSeenLabel = _cashierLastSeenAt == null
                ? 'Never'
                : _cashierLastSeenAt!.toLocal().toString();

            // Helper method for grid cards
            Widget buildGridItem({
              required IconData icon,
              required String title,
              required VoidCallback onTap,
              Color? iconColor,
              Color? backgroundColor,
            }) {
              return Card(
                elevation: 1,
                color: backgroundColor,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: backgroundColor != null
                        ? backgroundColor.withOpacity(0.5)
                        : Colors.grey.shade200,
                  ),
                ),
                child: InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          icon,
                          size: 32,
                          color: iconColor ?? Colors.blueGrey.shade700,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: iconColor ?? Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            return AlertDialog(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('App Menu'),
                  const SizedBox(height: 4),
                  Text(
                    'Cashier heartbeat last seen: $lastSeenLabel',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 480,
                child: GridView.count(
                  shrinkWrap: true,
                  crossAxisCount: 3,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.1,
                  children: [
                    // 1. ONLINE ORDERS TOGGLE CARD
                    buildGridItem(
                      icon: _isOnlineOrdersEnabled
                          ? Icons.wifi
                          : Icons.wifi_off,
                      title:
                          'Online Orders:\n${_isOnlineOrdersEnabled ? "OPEN" : "PAUSED"}',
                      iconColor: _isOnlineOrdersEnabled
                          ? Colors.green.shade700
                          : Colors.red.shade700,
                      backgroundColor: _isOnlineOrdersEnabled
                          ? Colors.green.shade50
                          : Colors.red.shade50,
                      onTap: () async {
                        final newValue = !_isOnlineOrdersEnabled;
                        await _setOnlineOrdersEnabled(newValue);
                        // Update the dialog UI immediately after toggling
                        if (mounted) {
                          setDialogState(() {});
                        }
                      },
                    ),

                    // 2. CASHIER PAGE
                    buildGridItem(
                      icon: Icons.point_of_sale_outlined,
                      title: 'Cashier Page',
                      onTap: () {
                        Navigator.of(dialogContext).pop();
                        _showDropdownSnackbar('Cashier page active');
                      },
                    ),

                    // 3. SHOW ORDERS
                    buildGridItem(
                      icon: Icons.receipt_long,
                      title: 'Show Orders',
                      onTap: () {
                        Navigator.of(dialogContext).pop();
                        _showAllOrdersDialog();
                      },
                    ),

                    // 4. SHIFTS
                    buildGridItem(
                      icon: Icons.history_toggle_off,
                      title: 'Shifts',
                      onTap: () async {
                        Navigator.of(dialogContext).pop();
                        await _showShiftsDialog();
                      },
                    ),

                    // 5. SYNC STATUS
                    buildGridItem(
                      icon: Icons.sync,
                      title: 'Sync Status',
                      onTap: () {
                        Navigator.of(dialogContext).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const SyncScreen(),
                          ),
                        );
                      },
                    ),

                    // 6. REPORTS
                    buildGridItem(
                      icon: Icons.bar_chart,
                      title: 'Reports',
                      onTap: () {
                        Navigator.of(dialogContext).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ReportsScreen(),
                          ),
                        );
                      },
                    ),

                    // 7. COURIER SETTINGS
                    buildGridItem(
                      icon: Icons.local_shipping_outlined,
                      title: 'Courier Settings',
                      onTap: () async {
                        Navigator.of(dialogContext).pop();
                        await _showCourierSettingsDialog();
                      },
                    ),

                    // 8. REFRESH
                    buildGridItem(
                      icon: Icons.refresh,
                      title: 'Refresh',
                      onTap: () async {
                        Navigator.of(dialogContext).pop();
                        await _refreshAppData();
                      },
                    ),

                    // 9. PRINTER SETTINGS
                    buildGridItem(
                      icon: Icons.print_outlined,
                      title: 'Printer Settings',
                      onTap: () {
                        Navigator.of(dialogContext).pop();
                        showPrinterSettingsDialog(
                          context,
                          onNotify: _showDropdownSnackbar,
                        );
                      },
                    ),
                  ],
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
  }

  Future<void> _loadCourierSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedNumber = prefs.getString(_courierNumberKey);
    final savedTemplate = prefs.getString(_courierTemplateKey);
    if (!mounted) return;
    setState(() {
      if (savedNumber != null) {
        _courierWhatsappNumber = savedNumber;
      }
      if (savedTemplate != null && savedTemplate.trim().isNotEmpty) {
        _courierMessageTemplate = savedTemplate;
      }
    });
  }

  Future<void> _showCourierSettingsDialog() async {
    final numberController = TextEditingController(
      text: _courierWhatsappNumber,
    );
    final templateController = TextEditingController(
      text: _courierMessageTemplate,
    );

    var previewTemplate = templateController.text;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Courier WhatsApp settings'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: numberController,
                        decoration: const InputDecoration(
                          labelText: 'Courier WhatsApp number',
                          hintText: 'e.g. 628123456789',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: templateController,
                        maxLines: 8,
                        onChanged: (value) {
                          setDialogState(() {
                            previewTemplate = value;
                          });
                        },
                        decoration: const InputDecoration(
                          labelText: 'Message template',
                          hintText:
                              'Write message template and insert placeholders from chips below.',
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Insert order/customer placeholders',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _courierTemplateTokens
                            .map((token) {
                              return ActionChip(
                                avatar: const Icon(
                                  Icons.add_circle_outline,
                                  size: 16,
                                ),
                                label: Text(token),
                                onPressed: () {
                                  _insertTemplateToken(
                                    templateController,
                                    token,
                                  );
                                  setDialogState(() {
                                    previewTemplate = templateController.text;
                                  });
                                },
                              );
                            })
                            .toList(growable: false),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Preview (placeholders rendered as chips)',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                          color: Colors.grey.shade50,
                        ),
                        child: RichText(
                          text: TextSpan(
                            style: Theme.of(context).textTheme.bodyMedium,
                            children: _buildTemplatePreviewSpans(
                              previewTemplate,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved != true || !mounted) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final number = numberController.text.trim();
    final template = templateController.text.trim();
    await prefs.setString(_courierNumberKey, number);
    await prefs.setString(_courierTemplateKey, template);

    if (!mounted) return;
    setState(() {
      _courierWhatsappNumber = number;
      _courierMessageTemplate = template.isEmpty
          ? _courierMessageTemplate
          : template;
    });
    _showDropdownSnackbar('Courier settings updated.');
  }

  List<InlineSpan> _buildTemplatePreviewSpans(String template) {
    if (template.isEmpty) {
      return const [TextSpan(text: '(empty template)')];
    }

    final tokenPattern = _courierTemplateTokens.map(RegExp.escape).join('|');
    final regex = RegExp(tokenPattern);
    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in regex.allMatches(template)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: template.substring(cursor, match.start)));
      }
      final token = match.group(0) ?? '';
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Chip(
              visualDensity: VisualDensity.compact,
              label: Text(token),
            ),
          ),
        ),
      );
      cursor = match.end;
    }

    if (cursor < template.length) {
      spans.add(TextSpan(text: template.substring(cursor)));
    }

    return spans;
  }

  void _insertTemplateToken(TextEditingController controller, String token) {
    final value = controller.value;
    final start = value.selection.start;
    final end = value.selection.end;
    if (start < 0 || end < 0) {
      controller.text = '${controller.text}$token';
      controller.selection = TextSelection.collapsed(
        offset: controller.text.length,
      );
      return;
    }

    final newText = value.text.replaceRange(start, end, token);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + token.length),
    );
  }

  Future<void> _cacheActiveShiftLocally({
    required int? shiftId,
    required int? cashierId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (shiftId == null) {
      await prefs.remove(_cachedShiftIdKey);
      await prefs.remove(_cachedCashierIdKey);
      return;
    }
    await prefs.setInt(_cachedShiftIdKey, shiftId);
    if (cashierId == null) {
      await prefs.remove(_cachedCashierIdKey);
    } else {
      await prefs.setInt(_cachedCashierIdKey, cashierId);
    }
  }

  Future<void> _restoreCachedShiftLocally() async {
    final prefs = await SharedPreferences.getInstance();
    final shiftId = prefs.getInt(_cachedShiftIdKey);
    final cashierId = prefs.getInt(_cachedCashierIdKey);
    if (shiftId == null) return;

    if (!mounted) return;
    setState(() {
      _activeShiftId = shiftId;
      _activeCashierId = cashierId;
    });
    _showDropdownSnackbar(
      'Using cached shift context while offline.',
      isError: true,
    );
  }

  Future<void> _syncShiftContext() async {
    await _offlineShiftRepository.init();

    try {
      final openShift = await _fetchOpenShiftWithRetry();
      final fetchedShiftId = _asInt(openShift?['id']);
      final fetchedCashierId =
          _asInt(openShift?['current_cashier_id']) ??
          _asInt(openShift?['opened_by']);
      final shiftId = fetchedShiftId ?? _activeShiftId;
      final cashierId = fetchedCashierId ?? _activeCashierId;

      if (openShift != null) {
        await _offlineShiftRepository.upsertCachedShift(openShift);
      }

      if (mounted) {
        setState(() {
          _activeShiftId = shiftId;
          _activeCashierId = cashierId;
        });
      } else {
        _activeShiftId = shiftId;
        _activeCashierId = cashierId;
      }

      await _cacheActiveShiftLocally(shiftId: shiftId, cashierId: cashierId);

      if (_activeShiftId != null) {
        return;
      }

      final cachedShifts = await _offlineShiftRepository.getCachedShifts();
      for (final row in cachedShifts) {
        final status = row['status']?.toString().toLowerCase();
        final cachedShiftId = (row['id'] as num?)?.toInt();
        if (status != 'open' || cachedShiftId == null) continue;

        final cachedCashierId =
            (row['current_cashier_id'] as num?)?.toInt() ??
            (row['opened_by'] as num?)?.toInt();
        if (mounted) {
          setState(() {
            _activeShiftId = cachedShiftId;
            _activeCashierId = cachedCashierId;
          });
        } else {
          _activeShiftId = cachedShiftId;
          _activeCashierId = cachedCashierId;
        }
        await _cacheActiveShiftLocally(
          shiftId: cachedShiftId,
          cashierId: cachedCashierId,
        );
        return;
      }

      await _restoreCachedShiftLocally();
      if (_activeShiftId == null && mounted) {
        await _showOpenShiftDialog();
      }
    } catch (_) {
      await _restoreCachedShiftLocally();
      if (_activeShiftId == null && mounted) {
        await _showOpenShiftDialog();
      }
    }
  }

  Future<Map<String, dynamic>?> _fetchOpenShiftWithRetry() async {
    const maxAttempts = 3;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final openShift = await supabase
            .from('shifts')
            .select(
              'id, status, branch_id, started_at, ended_at, current_cashier_id, opened_by',
            )
            .eq('status', 'open')
            .order('started_at', ascending: false)
            .limit(1)
            .maybeSingle();

        if (openShift != null) {
          return Map<String, dynamic>.from(openShift);
        }
      } catch (e) {
        if (attempt == maxAttempts - 1) {
          rethrow;
        }
      }

      if (attempt < maxAttempts - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
    }
    return null;
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  List<Map<String, dynamic>> _normalizeCashierRows(dynamic rows) {
    if (rows is! List) return const <Map<String, dynamic>>[];
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _fetchShiftReportRows() async {
    await _offlineShiftRepository.init();
    try {
      final rows = await supabase
          .from('shifts')
          .select(
            'id, status, branch_id, started_at, ended_at, current_cashier_id, opened_by, closed_by',
          )
          .order('started_at', ascending: false)
          .limit(50);
      var normalized = _normalizeCashierRows(rows);
      if (normalized.isEmpty) {
        final openShift = await supabase
            .from('shifts')
            .select(
              'id, status, branch_id, started_at, ended_at, current_cashier_id, opened_by, closed_by',
            )
            .eq('status', 'open')
            .order('started_at', ascending: false)
            .limit(1)
            .maybeSingle();
        if (openShift != null) {
          normalized = [Map<String, dynamic>.from(openShift)];
        }
      }
      await _offlineShiftRepository.replaceCachedShifts(normalized);
      return normalized;
    } catch (_) {
      return _offlineShiftRepository.getCachedShifts();
    }
  }

  String _formatShiftDateTime(dynamic value) {
    final raw = value?.toString() ?? '';
    if (raw.isEmpty) return '-';
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return raw;
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  Future<void> _showShiftsDialog() async {
    Map<String, dynamic>? openShift;
    try {
      openShift = await supabase
          .from('shifts')
          .select('id, branch_id, started_at, current_cashier_id')
          .eq('status', 'open')
          .order('started_at', ascending: false)
          .limit(1)
          .maybeSingle();
    } catch (_) {
      await _restoreCachedShiftLocally();
      if (mounted) {
        _showDropdownSnackbar(
          'Offline mode: showing cached shift context.',
          isError: true,
        );
      }
    }

    if (!mounted) return;

    if (openShift != null) {
      final fetchedShiftId = _asInt(openShift['id']);
      final fetchedCashierId = _asInt(openShift['current_cashier_id']);

      if (fetchedShiftId != null && _activeShiftId != fetchedShiftId) {
        setState(() {
          _activeShiftId = fetchedShiftId;
          if (fetchedCashierId != null) {
            _activeCashierId = fetchedCashierId;
          }
        });

        await _cacheActiveShiftLocally(
          shiftId: _activeShiftId,
          cashierId: _activeCashierId,
        );
      }
    }

    final openShiftId = _asInt(openShift?['id']) ?? _activeShiftId;
    final branchId = (openShift?['branch_id'] ?? '-').toString();
    final currentCashierId =
        _asInt(openShift?['current_cashier_id']) ?? _activeCashierId;

    var shiftReportRefreshKey = 0;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> handleDeleteShift(int shiftId) async {
              final confirmed = await showDialog<bool>(
                context: dialogContext,
                builder: (confirmContext) => AlertDialog(
                  title: const Text('Delete Shift'),
                  content: Text(
                    'Delete shift #$shiftId? This cannot be undone.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(confirmContext).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(confirmContext).pop(true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );

              if (confirmed != true) return;

              final nowIso = DateTime.now().toUtc().toIso8601String();
              try {
                await supabase.from('shifts').delete().eq('id', shiftId);
                await _offlineShiftRepository.removeCachedShift(shiftId);
                if (!mounted) return;
                _showDropdownSnackbar('Shift #$shiftId deleted.');
                setDialogState(() {
                  shiftReportRefreshKey++;
                });
              } on PostgrestException catch (error) {
                final lower = error.message.toLowerCase();
                final hasOrderReference =
                    error.code == '23503' && lower.contains('order');
                _showDropdownSnackbar(
                  hasOrderReference
                      ? 'Cannot delete shift #$shiftId because it is referenced by existing orders.'
                      : 'Failed to delete shift: ${error.message}',
                  isError: true,
                );
              } catch (_) {
                await _offlineShiftRepository.removeCachedShift(shiftId);
                await context.read<CartProvider>().enqueueOfflineShiftEvent(
                  eventType: 'shift_delete',
                  label: 'shift_delete #$shiftId',
                  payload: {
                    'shift': {
                      'shift_id': shiftId,
                      'deleted_at': nowIso,
                      'cashier_id': _activeCashierId,
                    },
                  },
                );
                if (!mounted) return;
                _showDropdownSnackbar(
                  'Shift delete queued for sync (offline mode).',
                  isError: true,
                );
                setDialogState(() {
                  shiftReportRefreshKey++;
                });
              }
            }

            return DefaultTabController(
              length: 2,
              child: AlertDialog(
                title: const Text('Shifts'),
                content: SizedBox(
                  width: 760,
                  height: 520,
                  child: Column(
                    children: [
                      const TabBar(
                        tabs: [
                          Tab(text: 'Shift Actions'),
                          Tab(text: 'Shift Log'),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: TabBarView(
                          children: [
                            SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    openShiftId == null
                                        ? 'No active shift. Open a shift before making orders.'
                                        : 'Active shift #$openShiftId (branch: $branchId).',
                                  ),
                                  if (currentCashierId != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        'Current cashier id: $currentCashierId',
                                      ),
                                    ),
                                  const SizedBox(height: 16),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      ElevatedButton.icon(
                                        onPressed: openShiftId == null
                                            ? null
                                            : () async {
                                                Navigator.of(
                                                  dialogContext,
                                                ).pop();
                                                await _showChangeCurrentCashierDialog(
                                                  shiftId: openShiftId,
                                                  currentCashierId:
                                                      currentCashierId,
                                                );
                                              },
                                        icon: const Icon(Icons.swap_horiz),
                                        label: const Text('Change Cashier'),
                                      ),
                                      ElevatedButton.icon(
                                        onPressed: openShiftId == null
                                            ? () async {
                                                Navigator.of(
                                                  dialogContext,
                                                ).pop();
                                                await _showOpenShiftDialog(
                                                  force: true,
                                                );
                                              }
                                            : null,
                                        icon: const Icon(Icons.play_arrow),
                                        label: const Text('Open Shift'),
                                      ),
                                      ElevatedButton.icon(
                                        onPressed: openShiftId == null
                                            ? null
                                            : () async {
                                                Navigator.of(
                                                  dialogContext,
                                                ).pop();
                                                await _closeShift(openShiftId);
                                              },
                                        icon: const Icon(
                                          Icons.stop_circle_outlined,
                                        ),
                                        label: const Text('Close Shift'),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: () async {
                                          Navigator.of(dialogContext).pop();
                                          await _showAddCashierDialog();
                                        },
                                        icon: const Icon(
                                          Icons.person_add_alt_1,
                                        ),
                                        label: const Text('Add Cashier'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            FutureBuilder<List<Map<String, dynamic>>>(
                              key: ValueKey(shiftReportRefreshKey),
                              future: _fetchShiftReportRows(),
                              builder: (context, snapshot) {
                                final rows =
                                    snapshot.data ??
                                    const <Map<String, dynamic>>[];
                                if (snapshot.connectionState ==
                                    ConnectionState.waiting) {
                                  return const Center(
                                    child: CircularProgressIndicator(),
                                  );
                                }
                                if (snapshot.hasError) {
                                  return Center(
                                    child: Text(
                                      'Failed to load shift log: ${snapshot.error}',
                                      textAlign: TextAlign.center,
                                    ),
                                  );
                                }
                                if (rows.isEmpty) {
                                  return const Center(
                                    child: Text('No shifts found.'),
                                  );
                                }

                                return RefreshIndicator(
                                  onRefresh: () async {
                                    await OrderSyncService.instance
                                        .forceReconcile();
                                    setDialogState(() {
                                      shiftReportRefreshKey++;
                                    });
                                  },
                                  child: ListView.separated(
                                    itemCount: rows.length,
                                    separatorBuilder: (_, __) =>
                                        const Divider(height: 1),
                                    itemBuilder: (_, index) {
                                      final row = rows[index];
                                      final shiftId = _asInt(row['id']);
                                      final status = (row['status'] ?? '-')
                                          .toString();
                                      final startedAt = _formatShiftDateTime(
                                        row['started_at'],
                                      );
                                      final endedAt = _formatShiftDateTime(
                                        row['ended_at'],
                                      );
                                      final isOpen =
                                          status.toLowerCase() == 'open';
                                      return ListTile(
                                        onTap: shiftId == null
                                            ? null
                                            : () async {
                                                Navigator.of(
                                                  dialogContext,
                                                ).pop();
                                                await _showAllOrdersDialog(
                                                  initialTab: 'shift_report',
                                                  initialShiftId: shiftId,
                                                );
                                              },
                                        title: Text(
                                          'Shift #${row['id']} • ${status.toUpperCase()}',
                                        ),
                                        subtitle: Text(
                                          'Branch: ${row['branch_id'] ?? '-'}\nStart: $startedAt\nEnd: $endedAt',
                                        ),
                                        isThreeLine: true,
                                        trailing: shiftId == null || isOpen
                                            ? null
                                            : IconButton(
                                                tooltip: 'Delete shift',
                                                icon: const Icon(
                                                  Icons.delete_outline,
                                                  color: Colors.red,
                                                ),
                                                onPressed: () =>
                                                    handleDeleteShift(shiftId),
                                              ),
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showChangeCurrentCashierDialog({
    required int shiftId,
    int? currentCashierId,
  }) async {
    var cashiers = <Map<String, dynamic>>[];
    try {
      final rows = await supabase.from('cashier').select('id, name, code');
      cashiers = _normalizeCashierRows(rows)
        ..sort(
          (a, b) => (a['name'] ?? '').toString().toLowerCase().compareTo(
            (b['name'] ?? '').toString().toLowerCase(),
          ),
        );
      await _offlineShiftRepository.init();
      await _offlineShiftRepository.cacheCashiers(cashiers);
    } catch (_) {
      await _offlineShiftRepository.init();
      cashiers = await _offlineShiftRepository.getCachedCashiers();
    }

    if (!mounted) return;
    if (cashiers.isEmpty) {
      _showDropdownSnackbar('No cashier found.', isError: true);
      return;
    }

    int? selectedCashierId = currentCashierId;
    var pin = '';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submitChange() async {
              final cashierId = selectedCashierId;
              if (cashierId == null) {
                _showDropdownSnackbar('Select cashier first.', isError: true);
                return;
              }
              if (pin.length != 4) {
                _showDropdownSnackbar('PIN must be 4 digits.', isError: true);
                return;
              }

              final selectedCashier = cashiers.firstWhere(
                (row) => _asInt(row['id']) == cashierId,
                orElse: () => <String, dynamic>{},
              );
              final onlineValidPin =
                  (selectedCashier['code'] ?? '').toString() == pin;
              final offlineValidPin = await _offlineShiftRepository
                  .validateCashierPin(cashierId: cashierId, pin: pin);
              if (!onlineValidPin && !offlineValidPin) {
                _showDropdownSnackbar('Invalid PIN.', isError: true);
                return;
              }

              try {
                await supabase
                    .from('shifts')
                    .update({'current_cashier_id': cashierId})
                    .eq('id', shiftId);
                if (!mounted) return;
                setState(() {
                  _activeCashierId = cashierId;
                });
                await _cacheActiveShiftLocally(
                  shiftId: _activeShiftId,
                  cashierId: cashierId,
                );
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                _showDropdownSnackbar('Current cashier updated.');
              } catch (error) {
                _showDropdownSnackbar(
                  'Failed to change cashier: $error',
                  isError: true,
                );
              }
            }

            return AlertDialog(
              title: const Text('Change Current Cashier'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<int>(
                      value: selectedCashierId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Cashier'),
                      items: cashiers
                          .map(
                            (cashier) => DropdownMenuItem<int>(
                              value: _asInt(cashier['id']),
                              child: Text(
                                (cashier['name'] ?? 'Unknown').toString(),
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) =>
                          setDialogState(() => selectedCashierId = value),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      decoration: const InputDecoration(
                        labelText: 'Cashier PIN',
                        helperText: 'Enter selected cashier PIN',
                      ),
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      maxLength: 4,
                      onChanged: (value) => pin = value.trim(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: submitChange,
                  child: const Text('Update'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showOpenShiftDialog({bool force = false}) async {
    if (!mounted) return;
    if (!force && _activeShiftId != null && _activeCashierId != null) return;

    try {
      supabase.auth.currentUser;
    } catch (_) {
      _showDropdownSnackbar(
        'Supabase unavailable, switching to offline cashier auth.',
        isError: true,
      );
    }

    final pinController = TextEditingController();
    final branchController = TextEditingController(text: 'main');
    int? selectedCashierId;
    List<Map<String, dynamic>> cashiers = <Map<String, dynamic>>[];

    await _offlineShiftRepository.init();

    try {
      final rows = await supabase
          .from('cashier')
          .select('id, name, code')
          .order('name', ascending: true);
      cashiers = _normalizeCashierRows(rows);
      await _offlineShiftRepository.cacheCashiers(cashiers);
    } catch (_) {
      cashiers = await _offlineShiftRepository.getCachedCashiers();
      if (cashiers.isEmpty) {
        _showDropdownSnackbar(
          'Offline and no cached cashiers available.',
          isError: true,
        );
        return;
      }
      _showDropdownSnackbar(
        'Using cached cashier data (offline mode).',
        isError: true,
      );
    }

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: force,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> openShift() async {
              final cashierId = selectedCashierId;
              final pin = pinController.text.trim();
              final branchId = branchController.text.trim();
              if (cashierId == null) {
                _showDropdownSnackbar(
                  'Please select cashier first.',
                  isError: true,
                );
                return;
              }
              if (pin.length != 4) {
                _showDropdownSnackbar('PIN must be 4 digits.', isError: true);
                return;
              }
              if (branchId.isEmpty) {
                _showDropdownSnackbar('Branch id is required.', isError: true);
                return;
              }

              final selectedCashier = cashiers.firstWhere(
                (row) => _asInt(row['id']) == cashierId,
              );

              final onlineValidPin =
                  (selectedCashier['code'] ?? '').toString() == pin;
              final offlineValidPin = await _offlineShiftRepository
                  .validateCashierPin(cashierId: cashierId, pin: pin);
              if (!onlineValidPin && !offlineValidPin) {
                _showDropdownSnackbar('Invalid PIN.', isError: true);
                return;
              }

              try {
                final existingOpenShift = await supabase
                    .from('shifts')
                    .select('id, current_cashier_id')
                    .eq('status', 'open')
                    .eq('branch_id', branchId)
                    .eq('current_cashier_id', cashierId)
                    .order('started_at', ascending: false)
                    .limit(1)
                    .maybeSingle();

                if (existingOpenShift != null) {
                  if (!mounted) return;
                  final existingShiftId = (existingOpenShift['id'] as num?)
                      ?.toInt();
                  final existingCashierId =
                      (existingOpenShift['current_cashier_id'] as num?)
                          ?.toInt();
                  setState(() {
                    _activeShiftId = existingShiftId;
                    _activeCashierId = existingCashierId;
                  });
                  await _cacheActiveShiftLocally(
                    shiftId: existingShiftId,
                    cashierId: existingCashierId,
                  );
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                  _requireShiftOpenForContinuedOrders = false;
                  _pendingShiftTransferFromId = null;
                  _showDropdownSnackbar(
                    'Shift already open. Continuing existing shift.',
                  );
                  return;
                }
                final created = await supabase
                    .from('shifts')
                    .insert({
                      'branch_id': branchId,
                      'status': 'open',
                      'current_cashier_id': cashierId,
                      'started_at': DateTime.now().toUtc().toIso8601String(),
                      'opened_by': cashierId,
                    })
                    .select('id, current_cashier_id')
                    .single();

                if (!mounted) return;
                final shiftId = (created['id'] as num?)?.toInt();
                final createdCashierId = (created['current_cashier_id'] as num?)
                    ?.toInt();

                if (shiftId != null) {
                  await _offlineShiftRepository.upsertCachedShift({
                    'id': shiftId,
                    'status': 'open',
                    'branch_id': branchId,
                    'started_at': DateTime.now().toUtc().toIso8601String(),
                    'ended_at': null,
                    'current_cashier_id': createdCashierId ?? cashierId,
                    'opened_by': cashierId,
                    'closed_by': null,
                  });
                }

                setState(() {
                  _activeShiftId = shiftId;
                  _activeCashierId = createdCashierId;
                });
                if (_pendingShiftTransferFromId != null && shiftId != null) {
                  await _reassignContinuingOrdersToShift(
                    fromShiftId: _pendingShiftTransferFromId!,
                    toShiftId: shiftId,
                  );
                }
                _requireShiftOpenForContinuedOrders = false;
                _pendingShiftTransferFromId = null;
                await _cacheActiveShiftLocally(
                  shiftId: shiftId,
                  cashierId: createdCashierId,
                );
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                _showDropdownSnackbar('Shift opened successfully.');
              } on PostgrestException catch (error) {
                final isDuplicateOpenShift =
                    error.code == '23505' &&
                    error.message.toLowerCase().contains('uq_shifts_one_open');
                if (isDuplicateOpenShift) {
                  final existingOpenShift = await supabase
                      .from('shifts')
                      .select('id, current_cashier_id')
                      .eq('status', 'open')
                      .eq('branch_id', branchId)
                      .eq('current_cashier_id', cashierId)
                      .order('started_at', ascending: false)
                      .limit(1)
                      .maybeSingle();
                  if (existingOpenShift != null && mounted) {
                    final existingShiftId = (existingOpenShift['id'] as num?)
                        ?.toInt();
                    final existingCashierId =
                        (existingOpenShift['current_cashier_id'] as num?)
                            ?.toInt();
                    setState(() {
                      _activeShiftId = existingShiftId;
                      _activeCashierId = existingCashierId;
                    });
                    await _cacheActiveShiftLocally(
                      shiftId: existingShiftId,
                      cashierId: existingCashierId,
                    );
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                    _requireShiftOpenForContinuedOrders = false;
                    _pendingShiftTransferFromId = null;
                    _showDropdownSnackbar(
                      'Shift already open. Continuing existing shift.',
                    );
                    return;
                  }
                }
                rethrow;
              } catch (_) {
                final localShiftId = await _offlineShiftRepository
                    .enqueueOfflineShift(
                      cashierId: cashierId,
                      branchId: branchId,
                    );
                if (!mounted) return;
                setState(() {
                  _activeShiftId = int.tryParse(localShiftId);
                  _activeCashierId = cashierId;
                });
                if (_pendingShiftTransferFromId != null &&
                    _activeShiftId != null) {
                  await _reassignContinuingOrdersToShift(
                    fromShiftId: _pendingShiftTransferFromId!,
                    toShiftId: _activeShiftId!,
                  );
                }
                _requireShiftOpenForContinuedOrders = false;
                _pendingShiftTransferFromId = null;
                await _cacheActiveShiftLocally(
                  shiftId: _activeShiftId,
                  cashierId: _activeCashierId,
                );
                await context.read<CartProvider>().enqueueOfflineShiftEvent(
                  eventType: 'shift_open',
                  label: 'shift_open #${_activeShiftId ?? '-'}',
                  payload: {
                    'shift': {
                      'local_shift_id': _activeShiftId,
                      'cashier_id': cashierId,
                      'branch_id': branchId,
                      'started_at': DateTime.now().toUtc().toIso8601String(),
                      'opened_by': cashierId,
                    },
                  },
                );

                await _offlineShiftRepository.upsertCachedShift({
                  'id': _activeShiftId,
                  'status': 'open',
                  'branch_id': branchId,
                  'started_at': DateTime.now().toUtc().toIso8601String(),
                  'ended_at': null,
                  'current_cashier_id': cashierId,
                  'opened_by': cashierId,
                  'closed_by': null,
                });

                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                _showDropdownSnackbar(
                  'Shift opened offline and queued for sync.',
                  isError: true,
                );
              }
            }

            return AlertDialog(
              title: const Text('Open Shift'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_requireShiftOpenForContinuedOrders) ...[
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          border: Border.all(color: Colors.orange.shade200),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'Please open a new shift to continue unfinished orders from the previous shift.',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                    DropdownButtonFormField<int>(
                      value: selectedCashierId,
                      isExpanded: true,
                      hint: Text(
                        cashiers.isEmpty
                            ? 'No cashier found (check terminal RLS access)'
                            : 'Select cashier',
                      ),
                      items: cashiers
                          .map(
                            (cashier) => DropdownMenuItem<int>(
                              value: _asInt(cashier['id']),
                              child: Text(
                                (cashier['name'] ?? 'Unknown').toString(),
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: cashiers.isEmpty
                          ? null
                          : (value) =>
                                setDialogState(() => selectedCashierId = value),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: pinController,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Cashier PIN',
                      ),
                    ),
                    TextField(
                      controller: branchController,
                      decoration: const InputDecoration(labelText: 'Branch id'),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () async {
                          await _showAddCashierDialog();
                          if (!context.mounted) return;
                          final rows = await supabase
                              .from('cashier')
                              .select('id, name, code')
                              .order('name', ascending: true);
                          setDialogState(() {
                            cashiers = _normalizeCashierRows(rows);
                          });
                        },
                        icon: const Icon(Icons.person_add_alt_1),
                        label: const Text('Add New Staff'),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                if (force)
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Close'),
                  ),
                ElevatedButton(
                  onPressed: cashiers.isEmpty ? null : openShift,
                  child: const Text('Open Shift'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showAddCashierDialog() async {
    final emailController = TextEditingController();
    final passwordController = TextEditingController();

    final adminSupabase = SupabaseClient(_supabaseUrl, _supabaseAnonKey);

    var verified = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Admin verification'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: emailController,
                  decoration: const InputDecoration(labelText: 'Admin email'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Admin password',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final email = emailController.text.trim();
                final password = passwordController.text;

                if (email.isEmpty || password.isEmpty) {
                  _showDropdownSnackbar(
                    'Admin credentials are required.',
                    isError: true,
                  );
                  return;
                }

                try {
                  await adminSupabase.auth.signInWithPassword(
                    email: email,
                    password: password,
                  );
                  verified = true;
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                } catch (e) {
                  _showDropdownSnackbar(
                    'Admin verification failed: $e',
                    isError: true,
                  );
                }
              },
              child: const Text('Verify'),
            ),
          ],
        );
      },
    );

    if (!verified) {
      return;
    }

    final nameController = TextEditingController();
    final pinController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Add cashier'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Cashier name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: pinController,
                  maxLength: 4,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Cashier PIN (4-digit)',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final cashierName = nameController.text.trim();
                final pin = pinController.text.trim();

                if (cashierName.isEmpty) {
                  _showDropdownSnackbar(
                    'Cashier name is required.',
                    isError: true,
                  );
                  return;
                }
                if (pin.length != 4) {
                  _showDropdownSnackbar(
                    'Cashier PIN must be 4 digits.',
                    isError: true,
                  );
                  return;
                }

                try {
                  await adminSupabase.from('cashier').insert({
                    'name': cashierName,
                    'code': pin,
                  });

                  if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                  _showDropdownSnackbar('Cashier added successfully.');
                } catch (e) {
                  _showDropdownSnackbar(
                    'Failed to add cashier: $e',
                    isError: true,
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    await adminSupabase.auth.signOut();
  }

  Future<void> _closeShift(int shiftId) async {
    await OrderSyncService.instance.forceReconcile();
    final cart = context.read<CartProvider>();
    if (cart.pendingOfflineOrderCount > 0) {
      final shouldContinue = await _showUnsyncedWarningDialog(
        pendingCount: cart.pendingOfflineOrderCount,
      );
      if (!shouldContinue) {
        return;
      }
    }

    final allOrders = await LocalOrderStoreRepository.instance.fetchAllOrders();
    final activeStatuses = <String>{
      OrderStatus.pending,
      OrderStatus.active,
      OrderStatus.processing,
      OrderStatus.assigned,
      OrderStatus.paid,
    };
    final remainingActiveOrders = allOrders.where((order) {
      final status = (order['status'] ?? '').toString();
      final isDeleted = order['deleted_at'] != null;
      final orderShiftId = _asInt(order['shift_id']);
      return !isDeleted &&
          activeStatuses.contains(status) &&
          orderShiftId == shiftId;
    }).length;

    if (remainingActiveOrders > 0) {
      final action = await _showActiveOrdersOnCloseShiftDialog(
        activeOrderCount: remainingActiveOrders,
      );
      if (action == _CloseShiftActiveOrderAction.completeInCurrentShift ||
          action == _CloseShiftActiveOrderAction.cancel) {
        if (action == _CloseShiftActiveOrderAction.completeInCurrentShift) {
          _showDropdownSnackbar(
            'Please complete the active order(s) first, then close shift again.',
          );
        }
        return;
      }
      _requireShiftOpenForContinuedOrders = true;
      _pendingShiftTransferFromId = shiftId;
    }

    try {
      final endedAt = DateTime.now().toUtc().toIso8601String();
      await supabase
          .from('shifts')
          .update({
            'status': 'closed',
            'ended_at': endedAt,
            'closed_by': _activeCashierId,
          })
          .eq('id', shiftId);
      await _offlineShiftRepository.upsertCachedShift({
        'id': shiftId,
        'status': 'closed',
        'ended_at': endedAt,
        'closed_by': _activeCashierId,
      });

      if (!mounted) return;
      setState(() {
        _activeShiftId = null;
        _activeCashierId = null;
      });
      await _cacheActiveShiftLocally(shiftId: null, cashierId: null);
      _showDropdownSnackbar('Shift closed.');
      await _showOpenShiftDialog(force: _requireShiftOpenForContinuedOrders);
    } catch (e) {
      final endedAt = DateTime.now().toUtc().toIso8601String();
      await context.read<CartProvider>().enqueueOfflineShiftEvent(
        eventType: 'shift_close',
        label: 'shift_close #$shiftId',
        payload: {
          'shift': {
            'shift_id': shiftId,
            'cashier_id': _activeCashierId,
            'ended_at': endedAt,
            'closed_by': _activeCashierId,
          },
        },
      );
      await _offlineShiftRepository.upsertCachedShift({
        'id': shiftId,
        'status': 'closed',
        'ended_at': endedAt,
        'closed_by': _activeCashierId,
      });
      if (!mounted) return;
      setState(() {
        _activeShiftId = null;
        _activeCashierId = null;
      });
      await _cacheActiveShiftLocally(shiftId: null, cashierId: null);
      _showDropdownSnackbar(
        'Shift close queued for sync (offline mode).',
        isError: true,
      );
      await _showOpenShiftDialog(force: _requireShiftOpenForContinuedOrders);
    }
  }

  Future<_CloseShiftActiveOrderAction> _showActiveOrdersOnCloseShiftDialog({
    required int activeOrderCount,
  }) async {
    final result = await showDialog<_CloseShiftActiveOrderAction>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Active orders still running'),
          content: Text(
            'There are $activeOrderCount active order(s) in this shift. Complete them in this shift, or continue them in a new shift.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_CloseShiftActiveOrderAction.cancel),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_CloseShiftActiveOrderAction.completeInCurrentShift),
              child: const Text('Complete in This Shift'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_CloseShiftActiveOrderAction.continueInNewShift),
              child: const Text('Continue & Open New Shift'),
            ),
          ],
        );
      },
    );
    return result ?? _CloseShiftActiveOrderAction.cancel;
  }

  Future<void> _reassignContinuingOrdersToShift({
    required int fromShiftId,
    required int toShiftId,
  }) async {
    if (fromShiftId == toShiftId) return;
    final continuingStatuses = <String>{
      OrderStatus.pending,
      OrderStatus.active,
      OrderStatus.processing,
      OrderStatus.assigned,
      OrderStatus.paid,
    };

    final localOrders = await LocalOrderStoreRepository.instance
        .fetchAllOrders();
    final targetOrders = localOrders
        .where((order) {
          final status = (order['status'] ?? '').toString();
          final shiftId = _asInt(order['shift_id']);
          final isDeleted = order['deleted_at'] != null;
          return !isDeleted &&
              shiftId == fromShiftId &&
              continuingStatuses.contains(status);
        })
        .toList(growable: false);

    for (final order in targetOrders) {
      final patched = Map<String, dynamic>.from(order)
        ..['shift_id'] = toShiftId;
      await LocalOrderStoreRepository.instance.upsertOrder(patched);
    }

    try {
      final ids = targetOrders
          .map((order) => (order['id'] as num?)?.toInt())
          .whereType<int>()
          .toList(growable: false);
      if (ids.isNotEmpty) {
        await supabase
            .from('orders')
            .update({'shift_id': toShiftId})
            .inFilter('id', ids);
      }
    } catch (_) {}
  }

  Future<bool> _showUnsyncedWarningDialog({required int pendingCount}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Unsynced data warning'),
          content: Text(
            'You still have $pendingCount unsynced item(s). Please wait for internet to restore and sync first. Closing shift now may risk data loss.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Close anyway'),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  Future<void> _showSyncStatusScreen() async {
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (context) => const SyncScreen()));
  }

  void _showDropdownSnackbar(String message, {bool isError = false}) {
    _snackbarAnimationController?.dispose();
    _snackbarOverlayEntry?.remove();

    final overlayState = Overlay.of(context);
    final controller = AnimationController(
      vsync: overlayState,
      duration: const Duration(milliseconds: 2400),
    );

    final slideAnimation = TweenSequence<Offset>([
      TweenSequenceItem(
        tween: Tween(
          begin: Offset.zero,
          end: const Offset(0, 0.35),
        ).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 25,
      ),
    ]).animate(controller);

    final opacityAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: 1), weight: 20),
      TweenSequenceItem(tween: ConstantTween(1), weight: 55),
      TweenSequenceItem(tween: Tween(begin: 1, end: 0), weight: 25),
    ]).animate(controller);

    final backgroundColor = isError
        ? Colors.red.shade700
        : Colors.blue.shade700;

    _snackbarAnimationController = controller;
    _snackbarOverlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: 16,
        left: 0,
        right: 0,
        child: SafeArea(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, child) {
                return Opacity(
                  opacity: opacityAnimation.value,
                  child: FractionalTranslation(
                    translation: slideAnimation.value,
                    child: child,
                  ),
                );
              },
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 440),
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: backgroundColor,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 10,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    overlayState.insert(_snackbarOverlayEntry!);
    controller.forward().whenComplete(() {
      _snackbarOverlayEntry?.remove();
      _snackbarOverlayEntry = null;
      if (_snackbarAnimationController == controller) {
        _snackbarAnimationController = null;
      }
      controller.dispose();
    });
  }
}
