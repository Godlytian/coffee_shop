part of 'package:coffee_shop/features/cashier/presentation/screens/cashier_screen.dart';

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

  Widget _buildConnectionBadge(CartProvider cart) {
    final networkOk = cart.hasNetworkConnection;
    final serverOk = cart.isServerReachable;

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

  PreferredSizeWidget _buildCashierAppBar() {
    return AppBar(
      title: Consumer<CartProvider>(
        builder: (context, cart, _) {
          return Row(
            children: [
              const Text('Cashier Dashboard'),
              const SizedBox(width: 8),
              _buildConnectionBadge(cart),
            ],
          );
        },
      ),
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      actions: [
        if (_activeCashierId != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Chip(
                avatar: const Icon(Icons.person, size: 18),
                label: Text('Cashier #$_activeCashierId'),
              ),
            ),
          ),
        if (_activeShiftId == null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Text(
                'No open shift',
                style: TextStyle(
                  color: Colors.red.shade700,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        IconButton(
          tooltip: 'Notification (online order)',
          onPressed: _showOnlinePendingOrdersDialog,
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.notifications_active),
              if (_onlinePaidOrdersCount > 0)
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
                      _onlinePaidOrdersCount.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
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
        PopupMenuButton<String>(
          tooltip: 'App menu',
          icon: const Icon(Icons.menu),
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'cashier', child: Text('Cashier Page')),
            PopupMenuItem(value: 'showorders', child: Text('Show Orders')),
            PopupMenuItem(value: 'shifts', child: Text('Shifts')),
            PopupMenuItem(value: 'sync_status', child: Text('Sync status')),
            PopupMenuItem(
              value: 'courier_settings',
              child: Text('Courier message settings'),
            ),
            PopupMenuItem(value: 'refresh_app', child: Text('Refresh')),
            PopupMenuItem(value: 'printer', child: Text('Printer settings')),
          ],
          onSelected: (value) async {
            if (value == 'cashier') {
              _showDropdownSnackbar('Cashier page active');
            } else if (value == 'showorders') {
              _showAllOrdersDialog();
            } else if (value == 'shifts') {
              await _showShiftsDialog();
            } else if (value == 'sync_status') {
              await _showSyncStatusScreen();
            } else if (value == 'courier_settings') {
              await _showCourierSettingsDialog();
            } else if (value == 'refresh_app') {
              await _refreshAppData();
            } else if (value == 'printer') {
              showPrinterSettingsDialog(
                context,
                onNotify: _showDropdownSnackbar,
              );
            }
          },
        ),
      ],
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
    if (shiftId == null || cashierId == null) {
      await prefs.remove(_cachedShiftIdKey);
      await prefs.remove(_cachedCashierIdKey);
      return;
    }
    await prefs.setInt(_cachedShiftIdKey, shiftId);
    await prefs.setInt(_cachedCashierIdKey, cashierId);
  }

  Future<void> _restoreCachedShiftLocally() async {
    final prefs = await SharedPreferences.getInstance();
    final shiftId = prefs.getInt(_cachedShiftIdKey);
    final cashierId = prefs.getInt(_cachedCashierIdKey);
    if (shiftId == null || cashierId == null) return;

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
    try {
      final openShift = await supabase
          .from('shifts')
          .select('id, current_cashier_id')
          .eq('status', 'open')
          .order('started_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (!mounted) return;

      final shiftId = (openShift?['id'] as num?)?.toInt();
      final cashierId = (openShift?['current_cashier_id'] as num?)?.toInt();
      setState(() {
        _activeShiftId = shiftId;
        _activeCashierId = cashierId;
      });
      await _cacheActiveShiftLocally(shiftId: shiftId, cashierId: cashierId);
      await _offlineShiftRepository.init();

      if (_activeShiftId == null || _activeCashierId == null) {
        await _showOpenShiftDialog();
      }
    } catch (_) {
      await _restoreCachedShiftLocally();
    }
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

    final openShiftId = _asInt(openShift?['id']) ?? _activeShiftId;
    final branchId = (openShift?['branch_id'] ?? '-').toString();
    final currentCashierId =
        _asInt(openShift?['current_cashier_id']) ?? _activeCashierId;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Shifts'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
                  child: Text('Current cashier id: $currentCashierId'),
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    onPressed: openShiftId == null
                        ? () async {
                            Navigator.of(dialogContext).pop();
                            await _showOpenShiftDialog(force: true);
                          }
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Open Shift'),
                  ),
                  ElevatedButton.icon(
                    onPressed: openShiftId == null
                        ? null
                        : () async {
                            Navigator.of(dialogContext).pop();
                            await _closeShift(openShiftId);
                          },
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Close Shift'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.of(dialogContext).pop();
                      await _showAddCashierDialog();
                    },
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Add Cashier'),
                  ),
                ],
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
                      'opened_by': supabase.auth.currentUser?.id,
                    })
                    .select('id, current_cashier_id')
                    .single();

                if (!mounted) return;
                final shiftId = (created['id'] as num?)?.toInt();
                final createdCashierId = (created['current_cashier_id'] as num?)
                    ?.toInt();
                setState(() {
                  _activeShiftId = shiftId;
                  _activeCashierId = createdCashierId;
                });
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
                      'started_at': DateTime.now().toIso8601String(),
                      'opened_by': supabase.auth.currentUser?.id,
                    },
                  },
                );
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
    final cart = context.read<CartProvider>();
    if (cart.pendingOfflineOrderCount > 0) {
      final shouldContinue = await _showUnsyncedWarningDialog(
        pendingCount: cart.pendingOfflineOrderCount,
      );
      if (!shouldContinue) {
        return;
      }
    }
    try {
      await supabase
          .from('shifts')
          .update({
            'status': 'closed',
            'ended_at': DateTime.now().toIso8601String(),
            'closed_by': supabase.auth.currentUser?.id,
          })
          .eq('id', shiftId);

      if (!mounted) return;
      setState(() {
        _activeShiftId = null;
        _activeCashierId = null;
      });
      await _cacheActiveShiftLocally(shiftId: null, cashierId: null);
      _showDropdownSnackbar('Shift closed.');
      await _showOpenShiftDialog();
    } catch (e) {
      await context.read<CartProvider>().enqueueOfflineShiftEvent(
        eventType: 'shift_close',
        label: 'shift_close #$shiftId',
        payload: {
          'shift': {
            'shift_id': shiftId,
            'cashier_id': _activeCashierId,
            'ended_at': DateTime.now().toIso8601String(),
            'closed_by': supabase.auth.currentUser?.id,
          },
        },
      );
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
      await _showOpenShiftDialog();
    }
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
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => const _SyncStatusScreen()),
    );
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

class _SyncStatusScreen extends StatefulWidget {
  const _SyncStatusScreen();

  @override
  State<_SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends State<_SyncStatusScreen> {
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
