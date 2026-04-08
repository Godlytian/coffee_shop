import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:coffee_shop/core/constants/order_status.dart';
import 'package:coffee_shop/core/services/supabase_client.dart';
import 'package:coffee_shop/core/services/order_sync_service.dart';
import 'package:coffee_shop/core/services/local_order_store_repository.dart';
import 'package:coffee_shop/core/services/local_order_item_store_repository.dart';
import 'package:coffee_shop/core/utils/formatters.dart';
import 'package:coffee_shop/features/cashier/models/models.dart';
import 'package:coffee_shop/features/cashier/providers/cart_provider.dart';
import 'package:coffee_shop/features/cashier/data/offline_shift_repository.dart';
import 'package:coffee_shop/features/printing/presentation/dialogs/printer_settings_dialog.dart';
import 'package:coffee_shop/features/printing/services/thermal_printer_service.dart';
import 'package:coffee_shop/features/reports/presentation/screens/reports_screen.dart';
import 'package:coffee_shop/features/reports/presentation/sync_screen.dart';
import 'package:coffee_shop/features/cashier/presentation/screens/split_bill_screen.dart';
import 'package:coffee_shop/core/services/order_notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';

part '../../controllers/cashier_controller.dart';
part '../widgets/cashier_app_bar.dart';
part '../widgets/menu_grid.dart';
part '../widgets/cart_item_tile.dart';
part '../widgets/cart_panel.dart';
part '../../../online_orders/presentation/dialogs/online_orders_dialog.dart';
part '../../../online_orders/presentation/dialogs/order_detail_dialog.dart';
part '../../models/payment_result.dart';
part '../../models/modifier_selection_result.dart';
part '../../data/cashier_repository.dart';
part '../../data/product_catalog_repository.dart';
part '../../../online_orders/data/online_orders_repository.dart';

Map<String, dynamic> _buildMenuProjectionPayload(Map<String, dynamic> payload) {
  final products = (payload['products'] as List<dynamic>? ?? <dynamic>[])
      .whereType<Map<String, dynamic>>()
      .toList(growable: false);
  final hiddenCategories =
      (payload['hiddenCategories'] as List<dynamic>? ?? <dynamic>[])
          .map((item) => item.toString())
          .toSet();
  final selectedCategory = payload['selectedCategory'] as String?;
  final searchQuery = (payload['searchQuery'] as String? ?? '')
      .trim()
      .toLowerCase();

  final visibleProducts = products
      .where((product) => !hiddenCategories.contains(product['category']))
      .toList(growable: false);
  final categories =
      visibleProducts
          .map((product) => product['category']?.toString() ?? '')
          .where((category) => category.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
  final effectiveSelectedCategory = categories.contains(selectedCategory)
      ? selectedCategory
      : null;
  var filteredProducts = effectiveSelectedCategory == null
      ? visibleProducts
      : visibleProducts
            .where(
              (product) =>
                  product['category']?.toString() == effectiveSelectedCategory,
            )
            .toList(growable: false);
  if (searchQuery.isNotEmpty) {
    filteredProducts = filteredProducts
        .where((product) {
          final productName = product['name']?.toString().toLowerCase() ?? '';
          return productName.contains(searchQuery);
        })
        .toList(growable: false);
  }
  filteredProducts.sort((a, b) {
    final nameA = a['name']?.toString().toLowerCase() ?? '';
    final nameB = b['name']?.toString().toLowerCase() ?? '';
    return nameA.compareTo(nameB);
  });

  return {
    'visibleProducts': visibleProducts,
    'categories': categories,
    'effectiveSelectedCategory': effectiveSelectedCategory,
    'filteredProducts': filteredProducts,
  };
}

List<int> _matchSelectedOrderItemIdsWorker(Map<String, dynamic> payload) {
  final rows = (payload['rows'] as List<dynamic>? ?? <dynamic>[])
      .whereType<Map<String, dynamic>>();
  final selectedSignatures =
      (payload['selectedSignatures'] as List<dynamic>? ?? <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false);
  final rowBuckets = <String, List<int>>{};

  for (final row in rows) {
    final rowId = (row['id'] as num?)?.toInt();
    if (rowId == null) continue;
    final signature = row['signature']?.toString();
    if (signature == null) continue;
    rowBuckets.putIfAbsent(signature, () => <int>[]).add(rowId);
  }

  final matchedIds = <int>[];
  for (final signature in selectedSignatures) {
    final bucket = rowBuckets[signature];
    if (bucket == null || bucket.isEmpty) continue;
    matchedIds.add(bucket.removeAt(0));
  }
  return matchedIds;
}

class ProductListScreen extends StatefulWidget {
  const ProductListScreen({super.key});

  @override
  State<ProductListScreen> createState() => _ProductListScreenState();
}

final ValueNotifier<List<Product>> _filteredProductsNotifier =
    ValueNotifier<List<Product>>(const <Product>[]);

class _ProductListScreenState extends State<ProductListScreen>
    with WidgetsBindingObserver {
  late Future<List<Product>> _future;

  final ValueNotifier<String?> _selectedCategoryNotifier =
      ValueNotifier<String?>(null);
  final Set<String> _hiddenMenuCategories = <String>{};
  final Map<String, Color> _menuCategoryColors = <String, Color>{};
  final TextEditingController _menuSearchController = TextEditingController();
  String _menuLayout = 'grid_4';
  bool _showMenuSearchBar = true;
  String _menuSearchQuery = '';
  String _orderType = 'dine_in';
  String? _customerName;
  String? _tableName;
  int? _currentActiveOrderId;
  int? _activeShiftId;
  int? _activeCashierId;
  final Set<String> _selectedCartItems = <String>{};
  bool _isCartSelectionMode = false;
  int? _pendingParentOrderIdForNextSubmit;
  bool _isOnlinePaidOrderInCart = false;
  Map<String, dynamic>? _currentOrderMetadata;
  String _courierWhatsappNumber = '';
  String _courierMessageTemplate =
      'New delivery order\nOrder ID: {order_id}\nCustomer: {customer_name}\nType: {order_type}\nTotal: {order_total}\nMap: {map_link}\nItems:\n{order_items}';
  OverlayEntry? _snackbarOverlayEntry;
  AnimationController? _snackbarAnimationController;
  final CashierRepository _cashierRepository = CashierRepository();
  final ProductCatalogRepository _productCatalogRepository =
      ProductCatalogRepository();
  final OnlineOrdersRepository _onlineOrdersRepository =
      OnlineOrdersRepository();
  static final OfflineShiftRepository _offlineShiftRepositoryCacheLoader =
      OfflineShiftRepository();
  CartProvider? _cartProviderSubscription;
  bool _lastKnownOnlineReachable = false;
  bool _isRefreshingAppData = false;
  final ValueNotifier<bool> _isCartExpandedNotifier = ValueNotifier<bool>(
    false,
  );
  bool _isMenuProjectionUpdating = false;
  List<Product> _allProductsCache = const <Product>[];
  List<Product> _filteredProductsCache = const <Product>[];
  List<String> _menuCategoriesCache = const <String>[];
  final List<_SplitBoardItem> _unassignedSplitItems = <_SplitBoardItem>[];
  final List<_SplitGroup> _splitGroups = <_SplitGroup>[];
  String? _selectedSplitItemId;
  String? _popoverSplitItemId;
  int _splitQuantityDraft = 1;
  int _splitGroupCounter = 0;
  int _splitItemCounter = 0;
  StreamSubscription<List<Map<String, dynamic>>>? _onlineOrderBadgeSubscription;
  final ValueNotifier<int> _onlinePaidOrdersCountNotifier = ValueNotifier<int>(
    0,
  );
  bool _isOnlineOrdersDialogOpen = false;
  Set<int> _knownPaidOnlineOrderIds = <int>{};
  final Set<int> _newlyPaidOnlineOrderIds = <int>{};
  final Map<int, String> _onlineOrderItemPreviewCache = <int, String>{};
  final Set<int> _onlineOrderItemPreviewLoading = <int>{};

  Timer? _cashierHeartbeatTimer;
  Timer? _menuSearchDebounceTimer;
  bool _isOnlineOrdersEnabled = true;
  DateTime? _cashierLastSeenAt;

  Stream<List<Map<String, dynamic>>> get _onlinePendingOrdersStream =>
      _activeShiftId == null || !_isOnlineOrdersEnabled
      ? Stream<List<Map<String, dynamic>>>.value(const <Map<String, dynamic>>[])
      : _onlineOrdersRepository.pendingOnlineOrdersStream();

  Stream<List<Map<String, dynamic>>> get _activeOrdersStream =>
      _activeShiftId == null
      ? Stream<List<Map<String, dynamic>>>.value(const <Map<String, dynamic>>[])
      : _cashierRepository.activeOrdersStream(
          cashierId: _activeCashierId,
          shiftId: _activeShiftId,
        );

  Stream<List<Map<String, dynamic>>> get _allOrdersStream => _cashierRepository
      .allOrdersStream(cashierId: _activeCashierId, shiftId: _activeShiftId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _future = _loadProducts();
    LocalOrderStoreRepository.instance.init();
    OrderSyncService.instance.start();
    unawaited(_loadCourierSettings());
    unawaited(
      Future<void>.delayed(
        const Duration(seconds: 3),
        _primeOfflineCachesOnFirstOpen,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncShiftContext();
    });
    unawaited(_initializeStoreSettingsHeartbeat());
    _startOnlineOrderBadgeListener();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(OrderSyncService.instance.forceReconcile());
    unawaited(_refreshAppData(silent: true));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<CartProvider>();
    if (!identical(_cartProviderSubscription, provider)) {
      _cartProviderSubscription?.removeListener(_handleConnectionStateChange);
      _cartProviderSubscription = provider;
      _lastKnownOnlineReachable =
          provider.hasNetworkConnection && provider.isServerReachable;
      provider.addListener(_handleConnectionStateChange);
    }
  }

  void _handleConnectionStateChange() {
    final provider = _cartProviderSubscription;
    if (provider == null) return;
    final isOnlineReachable =
        provider.hasNetworkConnection && provider.isServerReachable;
    if (isOnlineReachable && !_lastKnownOnlineReachable) {
      unawaited(_refreshAppData(silent: true));
    }
    _lastKnownOnlineReachable = isOnlineReachable;
  }

  Future<void> _initializeStoreSettingsHeartbeat() async {
    await _ensureStoreSettingsRow();
    await _refreshStoreSettingsStatus();
    await _sendCashierHeartbeat();

    _cashierHeartbeatTimer?.cancel();
    _menuSearchDebounceTimer?.cancel();
    _cashierHeartbeatTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_sendCashierHeartbeat());
    });
  }

  Future<void> _ensureStoreSettingsRow() async {
    try {
      await supabase.from('store_settings').upsert({
        'id': 1,
        'is_online_active': true,
      }, onConflict: 'id');
    } catch (_) {
      // ignore when table is not yet provisioned or blocked by policy.
    }
  }

  Future<void> _refreshStoreSettingsStatus() async {
    try {
      final row = await supabase
          .from('store_settings')
          .select('is_online_active, cashier_last_seen')
          .eq('id', 1)
          .maybeSingle();
      if (!mounted || row == null) return;
      setState(() {
        _isOnlineOrdersEnabled =
            (row['is_online_active'] as bool?) ?? _isOnlineOrdersEnabled;
        final rawSeen = row['cashier_last_seen']?.toString();
        _cashierLastSeenAt = rawSeen == null
            ? null
            : DateTime.tryParse(rawSeen);
      });
    } catch (_) {}
  }

  Future<void> _sendCashierHeartbeat() async {
    final now = DateTime.now().toUtc();
    try {
      await supabase.from('store_settings').upsert({
        'id': 1,
        'cashier_last_seen': now.toIso8601String(),
        'is_online_active': _isOnlineOrdersEnabled,
      }, onConflict: 'id');
      if (!mounted) return;
      setState(() {
        _cashierLastSeenAt = now;
      });
    } catch (_) {}
  }

  Future<void> _setOnlineOrdersEnabled(bool enabled) async {
    final previous = _isOnlineOrdersEnabled;
    setState(() {
      _isOnlineOrdersEnabled = enabled;
    });
    try {
      await supabase.from('store_settings').upsert({
        'id': 1,
        'is_online_active': enabled,
        'cashier_last_seen': (_cashierLastSeenAt ?? DateTime.now().toUtc())
            .toIso8601String(),
      }, onConflict: 'id');
      await _sendCashierHeartbeat();
      if (!mounted) return;
      _showDropdownSnackbar(
        enabled ? 'Online orders enabled.' : 'Online orders paused.',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isOnlineOrdersEnabled = previous;
      });
      _showDropdownSnackbar(
        'Failed to update online order status: $error',
        isError: true,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cashierHeartbeatTimer?.cancel();
    _menuSearchDebounceTimer?.cancel();
    _cartProviderSubscription?.removeListener(_handleConnectionStateChange);
    _onlineOrderBadgeSubscription?.cancel();
    _onlinePaidOrdersCountNotifier.dispose();
    _selectedCategoryNotifier.dispose();
    _isCartExpandedNotifier.dispose();
    _selectedCategoryNotifier.dispose();
    _isCartExpandedNotifier.dispose();
    _snackbarAnimationController?.dispose();
    _snackbarAnimationController?.dispose();
    _snackbarOverlayEntry?.remove();
    _filteredProductsNotifier.dispose();
    super.dispose();
  }

  bool get _isCartExpanded => _isCartExpandedNotifier.value;

  Future<void> _refreshMenuProjection({
    String? selectedCategory,
    bool clearCategory = false,
  }) async {
    if (_isMenuProjectionUpdating || _allProductsCache.isEmpty) return;
    _isMenuProjectionUpdating = true;
    try {
      final targetCategory = clearCategory
          ? null
          : (selectedCategory ?? _selectedCategoryNotifier.value);

      final payload = {
        'products': _allProductsCache
            .map((product) => product.toJson())
            .toList(),
        'hiddenCategories': _hiddenMenuCategories.toList(growable: false),
        'selectedCategory': targetCategory,
        'searchQuery': _menuSearchQuery,
      };
      final result = await compute(_buildMenuProjectionPayload, payload);
      if (!mounted) return;
      _menuCategoriesCache = (result['categories'] as List<dynamic>)
          .cast<String>();
      _filteredProductsNotifier.value =
          (result['filteredProducts'] as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .map(Product.fromJson)
              .toList(growable: false);
      _selectedCategoryNotifier.value =
          result['effectiveSelectedCategory'] as String?;
    } finally {
      _isMenuProjectionUpdating = false;
    }
  }

  void _startOnlineOrderBadgeListener() {
    _onlineOrderBadgeSubscription?.cancel();
    _onlineOrderBadgeSubscription = supabase
        .from('orders')
        .stream(primaryKey: ['id'])
        .order('created_at', ascending: false)
        .listen(
          (rows) {
            final paidOnlineRows = rows.where(
              (row) =>
                  row['status'] == OrderStatus.paid &&
                  row['order_source'] == 'online',
            );
            final paidOnlineOrderIds = paidOnlineRows
                .map((row) => (row['id'] as num?)?.toInt())
                .whereType<int>()
                .toSet();
            final paidOnlineCount = paidOnlineOrderIds.length;
            if (!mounted ||
                paidOnlineCount == _onlinePaidOrdersCountNotifier.value) {
              _knownPaidOnlineOrderIds = paidOnlineOrderIds;
              return;
            }
            final hadIncrease =
                paidOnlineCount > _onlinePaidOrdersCountNotifier.value;
            final newOrderIds = paidOnlineOrderIds.difference(
              _knownPaidOnlineOrderIds,
            );
            _onlinePaidOrdersCountNotifier.value = paidOnlineCount;
            _newlyPaidOnlineOrderIds.addAll(newOrderIds);
            _knownPaidOnlineOrderIds = paidOnlineOrderIds;
            if (hadIncrease && !_isOnlineOrdersDialogOpen) {
              _isOnlineOrdersDialogOpen = true;
              unawaited(() async {
                await OrderNotificationService.instance.playAlertOnce();
                await _showOnlinePendingOrdersDialog();
                _isOnlineOrdersDialogOpen = false;
              }());
            }
          },
          onError: (_, __) {
            // Keep UI functional when realtime channel is unavailable.
          },
        );
  }

  Future<List<Product>> _loadProducts() async {
    try {
      final data = await supabase.from('products').select();
      final products = (data as List<dynamic>)
          .whereType<Map>()
          .map((item) => Product.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false);
      await _productCatalogRepository.saveProducts(products);
      return products;
    } catch (_) {
      final cached = await _productCatalogRepository.loadCachedProducts();
      return cached;
    }
  }

  Future<void> _primeOfflineCachesOnFirstOpen() async {
    try {
      final productsData = await supabase.from('products').select();
      final products = (productsData as List<dynamic>)
          .whereType<Map>()
          .map((item) => Product.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false);
      await _productCatalogRepository.saveProducts(products);
    } catch (_) {}

    try {
      final sevenDaysAgo = DateTime.now()
          .subtract(const Duration(days: 7))
          .toIso8601String();
      final ordersData = await supabase
          .from('orders')
          .select()
          .isFilter('deleted_at', null)
          .gte('created_at', sevenDaysAgo)
          .order('created_at', ascending: false);

      final orders = (ordersData as List<dynamic>)
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);

      await LocalOrderStoreRepository.instance.reconcileOrders(orders);
    } catch (e) {
      print('Error priming orders: $e');
    }

    final sevenDaysAgo = DateTime.now()
        .subtract(const Duration(days: 7))
        .toIso8601String();

    try {
      final orderItemsData = await supabase
          .from('order_items')
          .select(
            'order_id, quantity, product_id, modifiers, products(*), orders!inner(deleted_at)',
          )
          .isFilter('orders.deleted_at', null)
          .gte('orders.created_at', sevenDaysAgo);

      final rows = (orderItemsData as List<dynamic>)
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);
      await LocalOrderItemStoreRepository.instance.replaceAll(rows);
    } catch (e) {
      print('Error priming order items: $e');
    }

    try {
      final cashiersData = await supabase
          .from('cashier')
          .select('id, name, code')
          .order('name', ascending: true);
      final cashiers = (cashiersData as List<dynamic>)
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);
      await _offlineShiftRepositoryCacheLoader.init();
      await _offlineShiftRepositoryCacheLoader.cacheCashiers(cashiers);
    } catch (_) {
      // Keep running in offline-first mode.
    }
  }

  Future<void> _refreshAppData({bool silent = false}) async {
    if (_isRefreshingAppData) return;
    _isRefreshingAppData = true;
    try {
      await _loadProducts();
      await _primeOfflineCachesOnFirstOpen();
      await _syncShiftContext();
      if (!mounted) return;
      setState(() {
        _future = _loadProducts();
      });
      if (!silent) {
        _showDropdownSnackbar('App data refreshed.');
      }
    } catch (error) {
      if (!mounted || silent) return;
      _showDropdownSnackbar(
        'Failed to refresh app data: $error',
        isError: true,
      );
    } finally {
      _isRefreshingAppData = false;
    }
  }

  Future<void> _refreshMenuProducts() async {
    final nextFuture = _loadProducts();
    if (mounted) {
      setState(() {
        _future = nextFuture;
      });
    }
    final products = await nextFuture;
    if (!mounted) return;
    _allProductsCache = products;
    await _refreshMenuProjection();
  }

  @override
  Widget build(BuildContext context) {
    const panelFadeDuration = Duration(milliseconds: 80);
    const panelAnimationDuration = Duration(milliseconds: 260);

    return Scaffold(
      appBar: _buildCashierAppBar(),
      body: ValueListenableBuilder<bool>(
        valueListenable: _isCartExpandedNotifier,
        builder: (context, isCartExpanded, child) {
          final dividerWidth = 36.0;
          final totalFlexWidth = max(
            MediaQuery.sizeOf(context).width - dividerWidth,
            0.0,
          );
          final menuColumnWidth = isCartExpanded
              ? 0.0
              : totalFlexWidth * (4 / 6);
          final cartColumnWidth = isCartExpanded
              ? totalFlexWidth
              : totalFlexWidth * (2 / 6);

          return Row(
            children: [
              // 1. First column changed back to AnimatedContainer
              AnimatedContainer(
                duration: panelAnimationDuration,
                curve: Curves.easeOutCubic,
                width: menuColumnWidth,
                child: menuColumnWidth <= 0
                    ? const SizedBox.shrink()
                    : RepaintBoundary(
                        child: AnimatedOpacity(
                          duration: panelFadeDuration,
                          curve: Curves.easeOutCubic,
                          opacity: isCartExpanded ? 0 : 1,
                          child: Column(
                            children: [
                              _buildColumnHeader(
                                title: 'Menu',
                                trailing: PopupMenuButton<String>(
                                  tooltip: 'Menu settings',
                                  icon: const Icon(Icons.more_vert),
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(
                                      value: 'view_settings',
                                      child: Text('View settings'),
                                    ),
                                  ],
                                  onSelected: (value) async {
                                    if (value == 'view_settings') {
                                      await _showMenuViewSettingsDialog();
                                    }
                                  },
                                ),
                              ),
                              if (_showMenuSearchBar)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    10,
                                    12,
                                    8,
                                  ),
                                  child: TextField(
                                    controller: _menuSearchController,
                                    decoration: const InputDecoration(
                                      prefixIcon: Icon(Icons.search),
                                      hintText: 'Search products...',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                    onChanged: (value) {
                                      _menuSearchDebounceTimer?.cancel();
                                      _menuSearchDebounceTimer = Timer(
                                        const Duration(milliseconds: 300),
                                        () {
                                          _menuSearchQuery = value.trim();
                                          unawaited(_refreshMenuProjection());
                                        },
                                      );
                                    },
                                  ),
                                ),
                              Expanded(
                                child: Container(
                                  color: Colors.grey[100],
                                  child: FutureBuilder<List<Product>>(
                                    future: _future,
                                    builder: (context, snapshot) {
                                      if (snapshot.connectionState ==
                                          ConnectionState.waiting) {
                                        return const Center(
                                          child: CircularProgressIndicator(),
                                        );
                                      }
                                      if (snapshot.hasError) {
                                        final errorText = snapshot.error
                                            .toString();
                                        final isPolicyError =
                                            errorText.contains(
                                              'row-level security',
                                            ) ||
                                            errorText.contains(
                                              'permission denied',
                                            ) ||
                                            errorText.contains(
                                              'not authorized',
                                            ) ||
                                            errorText.contains('42501');

                                        return Center(
                                          child: Padding(
                                            padding: const EdgeInsets.all(24),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.lock_outline,
                                                  size: 40,
                                                  color: Colors.orange,
                                                ),
                                                const SizedBox(height: 12),
                                                Text(
                                                  isPolicyError
                                                      ? 'Data cannot be read because Supabase Row Level Security policy blocks this client.'
                                                      : 'Error loading menu data.',
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  isPolicyError
                                                      ? 'Fix by updating Supabase RLS SELECT policies so this app client is allowed to read products/orders.'
                                                      : errorText,
                                                  textAlign: TextAlign.center,
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      }
                                      if (!snapshot.hasData ||
                                          snapshot.data!.isEmpty) {
                                        return const Center(
                                          child: Text('No products found!'),
                                        );
                                      }

                                      final products = snapshot.data!;
                                      if (!listEquals(
                                        _allProductsCache,
                                        products,
                                      )) {
                                        _allProductsCache = products;
                                        unawaited(_refreshMenuProjection());
                                      }

                                      return ValueListenableBuilder<String?>(
                                        valueListenable:
                                            _selectedCategoryNotifier,
                                        builder: (context, selectedCategory, _) {
                                          return ValueListenableBuilder<
                                            List<Product>
                                          >(
                                            valueListenable:
                                                _filteredProductsNotifier,
                                            builder: (context, filteredProducts, _) {
                                              return Column(
                                                children: [
                                                  Expanded(
                                                    child: RefreshIndicator(
                                                      onRefresh:
                                                          _refreshMenuProducts,
                                                      child:
                                                          _buildMenuLayoutContent(
                                                            filteredProducts,
                                                          ),
                                                    ),
                                                  ),
                                                  SizedBox(
                                                    height: 56,
                                                    child: ListView(
                                                      scrollDirection:
                                                          Axis.horizontal,
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 12,
                                                          ),
                                                      children: [
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 4,
                                                                vertical: 8,
                                                              ),
                                                          child: ChoiceChip(
                                                            label: const Text(
                                                              'All',
                                                            ),
                                                            selected:
                                                                selectedCategory ==
                                                                null,
                                                            onSelected: (_) {
                                                              unawaited(
                                                                _refreshMenuProjection(
                                                                  clearCategory:
                                                                      true,
                                                                ),
                                                              );
                                                            },
                                                          ),
                                                        ),
                                                        ..._menuCategoriesCache.map(
                                                          (category) => Padding(
                                                            padding:
                                                                const EdgeInsets.symmetric(
                                                                  horizontal: 4,
                                                                  vertical: 8,
                                                                ),
                                                            child: ChoiceChip(
                                                              label: Text(
                                                                category,
                                                              ),
                                                              selected:
                                                                  selectedCategory ==
                                                                  category,
                                                              onSelected: (_) {
                                                                unawaited(
                                                                  _refreshMenuProjection(
                                                                    selectedCategory:
                                                                        category,
                                                                  ),
                                                                );
                                                              },
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              );
                                            },
                                          );
                                        },
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
              AnimatedContainer(
                duration: panelAnimationDuration,
                curve: Curves.easeOutCubic,
                width: dividerWidth,
                child: _buildMenuCartDivider(),
              ),

              AnimatedContainer(
                duration: panelAnimationDuration,
                curve: Curves.easeOutCubic,
                width: cartColumnWidth,
                child: RepaintBoundary(
                  child: AnimatedOpacity(
                    duration: panelFadeDuration,
                    curve: Curves.easeOutCubic,
                    opacity: isCartExpanded ? 1 : 0.96,
                    // 3. Inject your new widget here!
                    child: isCartExpanded
                        ? const SplitBillScreen()
                        : _buildRegularCartBody(),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRegularCartBody() {
    final hasOrderDetails = _customerName != null || _tableName != null;
    return Column(
      children: [
        Selector<CartProvider, bool>(
          selector: (_, cart) => cart.items.isNotEmpty,
          builder: (context, hasCartItems, _) {
            final hasCurrentOrderDraft = hasCartItems || hasOrderDetails;
            return _buildColumnHeader(
              title: 'Cart',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isCartSelectionMode)
                    TextButton(
                      onPressed: hasCartItems ? _selectAllCartItems : null,
                      child: const Text('Select all'),
                    )
                  else ...[
                    PopupMenuButton<String>(
                      tooltip: 'Print options',
                      icon: const Icon(Icons.print),
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'prebill',
                          child: Text('Print pre-settlement bill'),
                        ),
                        PopupMenuItem(
                          value: 'kitchen',
                          child: Text('Print to kitchen'),
                        ),
                      ],
                      onSelected: (value) async {
                        if (value == 'prebill') {
                          await _printPreSettlementBill();
                        } else if (value == 'kitchen') {
                          await _printKitchenTicket();
                        }
                      },
                    ),
                    StreamBuilder<List<Map<String, dynamic>>>(
                      stream: _activeOrdersStream,
                      builder: (context, snapshot) {
                        final activeOrders =
                            snapshot.data ?? <Map<String, dynamic>>[];
                        return IconButton(
                          tooltip: 'List (active order list)',
                          onPressed: _showActiveCashierOrdersDialog,
                          icon: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              const Icon(Icons.list_alt),
                              if (activeOrders.isNotEmpty)
                                Positioned(
                                  right: -8,
                                  top: -8,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.blue,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      activeOrders.length.toString(),
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
                        );
                      },
                    ),
                    IconButton(
                      tooltip: 'Clear cart',
                      onPressed: hasCurrentOrderDraft
                          ? _resetCurrentOrderDraft
                          : null,
                      icon: const Icon(Icons.delete_sweep),
                    ),
                  ],
                  PopupMenuButton<String>(
                    tooltip: 'Cart settings',
                    icon: const Icon(Icons.more_vert),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'gabung_nota',
                        child: Text('Gabung nota'),
                      ),
                      PopupMenuItem(
                        value: 'pisah_nota',
                        child: Text('Pisah nota'),
                      ),
                      PopupMenuItem(
                        value: 'batal_pesanan',
                        child: Text('Batal pesanan'),
                      ),
                    ],
                    onSelected: _onCartSettingSelected,
                  ),
                ],
              ),
            );
          },
        ),
        _buildCartOrderDetailsTab(),
        Expanded(
          child: Consumer<CartProvider>(
            builder: (context, cart, _) {
              return ClipRect(
                child: ListView.builder(
                  itemCount: cart.items.length,
                  itemBuilder: (context, index) {
                    final entry = cart.items.entries.elementAt(index);
                    final key = entry.key;
                    final item = entry.value;
                    final isSelected = _selectedCartItems.contains(key);

                    final tile = ListTile(
                      onLongPress: () => _enterSelectionModeWithItem(key),
                      onTap: () {
                        if (_isCartSelectionMode) {
                          _toggleSelectedCartItem(key);
                          return;
                        }
                        _openCartItemEditor(key, item);
                      },
                      title: Text(item.name),
                      subtitle: Text(_cartSubtitle(item)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isCartSelectionMode)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Icon(
                                isSelected
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                color: isSelected ? Colors.green : Colors.grey,
                                size: 18,
                              ),
                            )
                          else if (isSelected)
                            const Padding(
                              padding: EdgeInsets.only(right: 6),
                              child: Icon(
                                Icons.check_circle,
                                color: Colors.green,
                                size: 18,
                              ),
                            ),
                          Text(
                            '${CurrencyFormatters.formatRupiah((item.price + _modifierExtraFromData(item.modifiersData)) * item.quantity)}',
                          ),
                        ],
                      ),
                    );

                    if (_isCartSelectionMode) return tile;

                    return Slidable(
                      key: ValueKey(key),
                      endActionPane: ActionPane(
                        motion: const ScrollMotion(),
                        extentRatio: 0.24,
                        children: [
                          SlidableAction(
                            onPressed: (_) {
                              context.read<CartProvider>().removeItem(key);
                              setState(() {
                                _selectedCartItems.remove(key);
                              });
                            },
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            icon: Icons.delete,
                            label: 'Delete',
                          ),
                        ],
                      ),
                      child: tile,
                    );
                  },
                ),
              );
            },
          ),
        ),
        Consumer<CartProvider>(
          builder: (context, cart, _) {
            return Container(
              padding: const EdgeInsets.all(20),
              color: Colors.grey[200],
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Total:',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${CurrencyFormatters.formatRupiah(cart.totalAmount)}',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (_isOnlinePaidOrderInCart) ...[
                        Expanded(
                          child: ElevatedButton(
                            onPressed:
                                cart.items.isEmpty || _orderType != 'delivery'
                                ? null
                                : () => _handleSendOrderToCourier(cart),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal,
                              foregroundColor: Colors.white,
                            ),
                            child: const Text('SEND TO COURIER'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: cart.items.isEmpty
                                ? null
                                : () => _handleCompleteOnlineOrder(),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                            ),
                            child: const Text('COMPLETE'),
                          ),
                        ),
                      ] else ...[
                        Expanded(
                          child: ElevatedButton(
                            onPressed: cart.items.isEmpty
                                ? null
                                : () => _handleSaveCartOrder(cart),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              foregroundColor: Colors.white,
                            ),
                            child: const Text('SAVE'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: cart.items.isEmpty
                                ? null
                                : () => _handlePayCartOrder(cart),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                            ),
                            child: const Text('PAY'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  void _resetSplitBoardState() {
    _unassignedSplitItems.clear();
    _splitGroups.clear();
    _selectedSplitItemId = null;
    _popoverSplitItemId = null;
    _splitQuantityDraft = 1;
    _splitGroupCounter = 0;
    _splitItemCounter = 0;
  }

  String _nextSplitItemId(String prefix) {
    _splitItemCounter += 1;
    return '${prefix}_split_item_$_splitItemCounter';
  }

  Widget _buildCartExpandToggle() {
    return SizedBox(
      width: 32,
      height: 32,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        elevation: 2,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _toggleCartExpanded, // <-- CHANGED HERE
          child: Icon(
            _isCartExpanded ? Icons.chevron_right : Icons.chevron_left,
            size: 20,
          ),
        ),
      ),
    );
  }

  // void _toggleCartExpanded() {
  //   final shouldExpand = !_isCartExpandedNotifier.value;
  //   _isCartExpandedNotifier.value = shouldExpand;
  //   _resetSplitBoardState();

  //   if (!shouldExpand) return;
  //   final cart = context.read<CartProvider>();
  //   _ensureSplitBoardSeed(cart);
  // }
  void _toggleCartExpanded() {
    _isCartExpandedNotifier.value = !_isCartExpandedNotifier.value;
  }

  Widget _buildMenuCartDivider() {
    return SizedBox(
      width: 36,
      child: Stack(
        alignment: Alignment.center,
        children: [
          const VerticalDivider(width: 1, thickness: 1),
          _buildCartExpandToggle(),
        ],
      ),
    );
  }

  void _ensureSplitBoardSeed(CartProvider cart) {
    if (_unassignedSplitItems.isNotEmpty || _splitGroups.isNotEmpty) return;

    for (final entry in cart.items.entries) {
      final cartItem = entry.value;
      final extra = _modifierExtraFromData(cartItem.modifiersData);
      _unassignedSplitItems.add(
        _SplitBoardItem(
          id: _nextSplitItemId(entry.key),
          name: cartItem.name,
          quantity: cartItem.quantity,
          unitPrice: cartItem.price + extra,
        ),
      );
    }

    if (_splitGroups.isEmpty) {
      _splitGroups.add(_newSplitGroup());
    }
  }

  _SplitGroup _newSplitGroup() {
    _splitGroupCounter += 1;
    return _SplitGroup(
      id: 'group_$_splitGroupCounter',
      groupName: 'Group $_splitGroupCounter',
      items: <_SplitBoardItem>[],
    );
  }

  void _confirmSplit(_SplitBoardItem item) {
    if (_splitQuantityDraft <= 0 || _splitQuantityDraft >= item.quantity) {
      setState(() => _popoverSplitItemId = null);
      return;
    }

    setState(() {
      item.quantity -= _splitQuantityDraft;
      final index = _unassignedSplitItems.indexWhere(
        (entry) => entry.id == item.id,
      );
      final newItem = _SplitBoardItem(
        id: _nextSplitItemId(item.id),
        name: item.name,
        quantity: _splitQuantityDraft,
        unitPrice: item.unitPrice,
      );
      _unassignedSplitItems.insert(index + 1, newItem);
      _selectedSplitItemId = newItem.id;
      _popoverSplitItemId = null;
      _splitQuantityDraft = 1;
    });
  }

  num _groupSubtotal(_SplitGroup group) {
    return group.items.fold<num>(
      0,
      (sum, item) => sum + (item.quantity * item.unitPrice),
    );
  }

  num _allGroupsTotal() {
    return _splitGroups.fold<num>(
      0,
      (sum, group) => sum + _groupSubtotal(group),
    );
  }

  Future<void> _handlePaySplitGroup(_SplitGroup group) async {
    if (group.items.isEmpty) return;
    final total = _groupSubtotal(group).toDouble();
    final payment = await _showPaymentMethodModal(total);
    if (!mounted || payment == null) return;

    _showDropdownSnackbar(
      '${group.groupName} paid via ${payment.method.toUpperCase()} • ${_formatRupiah(total)}',
    );
  }

  Widget _buildSplitBoardBody() {
    return Stack(
      children: [
        Column(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Text(
                    'Split Bill / Group Order',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Container(
                      color: Colors.white,
                      child: ListView.builder(
                        itemCount: _unassignedSplitItems.length,
                        itemBuilder: (context, index) {
                          final item = _unassignedSplitItems[index];
                          final isSelected = _selectedSplitItemId == item.id;
                          final popoverOpen = _popoverSplitItemId == item.id;

                          return Card(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                children: [
                                  ListTile(
                                    tileColor: isSelected
                                        ? Colors.blue.withOpacity(0.08)
                                        : null,
                                    title: Text(item.name),
                                    subtitle: Text('Qty: ${item.quantity}'),
                                    trailing: Text(
                                      _formatRupiah(
                                        item.quantity * item.unitPrice,
                                      ),
                                    ),
                                    onTap: () {
                                      setState(() {
                                        _selectedSplitItemId = item.id;
                                      });
                                    },
                                    onLongPress: () {
                                      setState(() {
                                        _popoverSplitItemId = item.id;
                                        _splitQuantityDraft = 1;
                                      });
                                    },
                                  ),
                                  if (popoverOpen)
                                    Row(
                                      children: [
                                        IconButton(
                                          onPressed: _splitQuantityDraft > 1
                                              ? () => setState(
                                                  () => _splitQuantityDraft--,
                                                )
                                              : null,
                                          icon: const Icon(
                                            Icons.remove_circle_outline,
                                          ),
                                        ),
                                        Expanded(
                                          child: Center(
                                            child: Text(
                                              'Split $_splitQuantityDraft',
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          onPressed:
                                              _splitQuantityDraft <
                                                  item.quantity - 1
                                              ? () => setState(
                                                  () => _splitQuantityDraft++,
                                                )
                                              : null,
                                          icon: const Icon(
                                            Icons.add_circle_outline,
                                          ),
                                        ),
                                        ElevatedButton(
                                          onPressed: () => _confirmSplit(item),
                                          child: const Text('Confirm Split'),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 1.3,
                          ),
                      itemCount: _splitGroups.length + 1,
                      itemBuilder: (context, index) {
                        if (index == _splitGroups.length) {
                          return OutlinedButton.icon(
                            onPressed: () => setState(
                              () => _splitGroups.add(_newSplitGroup()),
                            ),
                            icon: const Icon(Icons.add),
                            label: const Text('Add New Group'),
                          );
                        }

                        final group = _splitGroups[index];
                        return Card(
                          child: InkWell(
                            onTap: () {
                              if (_selectedSplitItemId == null) return;
                              final selectedIndex = _unassignedSplitItems
                                  .indexWhere(
                                    (item) => item.id == _selectedSplitItemId,
                                  );
                              if (selectedIndex < 0) return;
                              setState(() {
                                final selected = _unassignedSplitItems.removeAt(
                                  selectedIndex,
                                );
                                group.items.add(selected);
                                _selectedSplitItemId = null;
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          group.groupName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip:
                                            'Pay & print ${group.groupName}',
                                        onPressed: group.items.isEmpty
                                            ? null
                                            : () => _handlePaySplitGroup(group),
                                        icon: const Icon(Icons.print),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: group.items.isEmpty
                                        ? const Text(
                                            'Tap item on left then tap this group',
                                          )
                                        : ListView(
                                            children: group.items
                                                .map(
                                                  (item) => Text(
                                                    '${item.quantity}x ${item.name}',
                                                  ),
                                                )
                                                .toList(growable: false),
                                          ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Subtotal: ${_formatRupiah(_groupSubtotal(group))}',
                                  ),
                                  const SizedBox(height: 6),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton(
                                      onPressed: group.items.isEmpty
                                          ? null
                                          : () => _handlePaySplitGroup(group),
                                      child: Text(
                                        'Pay ${_formatRupiah(_groupSubtotal(group))}',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                border: Border(top: BorderSide(color: Colors.grey.shade300)),
              ),
              child: Row(
                children: [
                  Text('Total groups: ${_formatRupiah(_allGroupsTotal())}'),
                  const Spacer(),
                  ElevatedButton(
                    onPressed:
                        _splitGroups.any((group) => group.items.isNotEmpty)
                        ? () => _showDropdownSnackbar(
                            'Pay all groups: ${_formatRupiah(_allGroupsTotal())}',
                          )
                        : null,
                    child: Text(
                      'Pay All Groups (${_formatRupiah(_allGroupsTotal())})',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: _buildCartExpandToggle(),
          ),
        ),
      ],
    );
  }

  List<Map<String, dynamic>> _buildReceiptItems(CartProvider cart) {
    return cart.items.values
        .map((item) {
          final modifierExtra = (item.modifiersData ?? <dynamic>[])
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

  Future<void> _handleSaveCartOrder(CartProvider cart) async {
    if ((_customerName ?? '').trim().isEmpty) {
      _showDropdownSnackbar('Enter customer name first.', isError: true);
      await _showOfflineOrderDetailModal();
      if ((_customerName ?? '').trim().isEmpty) {
        return;
      }
    }
    if (_activeShiftId == null) {
      _showDropdownSnackbar(
        'No open shift. Please open a shift first.',
        isError: true,
      );
      return;
    }

    try {
      final savedOrderId = _currentActiveOrderId != null
          ? await cart.updateExistingOrder(
              orderId: _currentActiveOrderId!,
              customerName: _customerName,
              tableName: _tableName,
              orderType: _orderType,
              status: 'active',
            )
          : await cart.submitOrder(
              customerName: _customerName,
              tableName: _tableName,
              orderType: _orderType,
              status: 'active',
              parentOrderId: _pendingParentOrderIdForNextSubmit,
              cashierId: _activeCashierId,
              shiftId: _activeShiftId,
              shouldClearCart: false,
            );

      if (!mounted) return;
      if (savedOrderId != 0) {
        setState(() {
          _currentActiveOrderId = savedOrderId;
          _pendingParentOrderIdForNextSubmit = null;
        });
      }
      _showDropdownSnackbar(
        (savedOrderId > 0)
            ? 'Order saved successfully.'
            : 'saved Offline. sync later from app menu.',
      );
    } catch (error) {
      if (!mounted) return;
      _showDropdownSnackbar('Failed to save order: $error', isError: true);
    }
  }

  Future<void> _handlePayCartOrder(CartProvider cart) async {
    if (cart.items.isEmpty) {
      _showDropdownSnackbar('Cart is empty. Add item first.', isError: true);
      return;
    }

    if ((_customerName ?? '').trim().isEmpty) {
      _showDropdownSnackbar('Enter customer name first.', isError: true);
      await _showOfflineOrderDetailModal();
      if ((_customerName ?? '').trim().isEmpty) {
        return;
      }
    }
    if (_activeShiftId == null) {
      _showDropdownSnackbar(
        'No open shift. Please open a shift first.',
        isError: true,
      );
      return;
    }

    final payment = await _showPaymentMethodModal(cart.totalAmount);
    if (!mounted || payment == null) {
      return;
    }

    final receiptItems = _buildReceiptItems(cart);
    final totalBeforeSubmit = cart.totalAmount;
    int? paidOrderId;

    try {
      if (_currentActiveOrderId != null) {
        paidOrderId = await cart.updateExistingOrder(
          orderId: _currentActiveOrderId!,
          customerName: _customerName,
          tableName: _tableName,
          orderType: _orderType,
          paymentMethod: payment.method,
          totalPaymentReceived: payment.totalPaymentReceived,
          changeAmount: payment.changeAmount,
          status: 'completed',
        );
      } else {
        paidOrderId = await cart.submitOrder(
          customerName: _customerName,
          tableName: _tableName,
          orderType: _orderType,
          paymentMethod: payment.method,
          totalPaymentReceived: payment.totalPaymentReceived,
          changeAmount: payment.changeAmount,
          status: 'completed',
          parentOrderId: _pendingParentOrderIdForNextSubmit,
          cashierId: _activeCashierId,
          shiftId: _activeShiftId,
        );
      }

      if ((paidOrderId ?? 0) > 0) {
        final prefs = await SharedPreferences.getInstance();
        final isAutoPrint = prefs.getBool('auto_print_receipt') ?? true;
        final shouldShowPopup =
            prefs.getBool('show_print_popup_after_payment') ?? true;
        if (isAutoPrint) {
          await ThermalPrinterService.instance.printPaymentReceipt(
            orderId: paidOrderId!,
            lines: receiptItems,
            total: totalBeforeSubmit,
            paymentMethod: payment.method,
            paid: payment.totalPaymentReceived,
            change: payment.changeAmount,
            customerName: _customerName,
            tableName: _tableName,
          );
        } else if (mounted && shouldShowPopup) {
          final preview = ThermalPrinterService.instance
              .generateReceiptPreviewText(
                orderId: paidOrderId!,
                lines: receiptItems,
                total: totalBeforeSubmit,
                paymentMethod: payment.method,
                paid: payment.totalPaymentReceived,
                change: payment.changeAmount,
                customerName: _customerName,
                tableName: _tableName,
              );
          final shouldPrint = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Payment Successful. Print Receipt?'),
              content: Container(
                width: 360,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  child: Text(
                    preview,
                    style: const TextStyle(fontFamily: 'Courier', fontSize: 12),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Skip'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Print'),
                ),
              ],
            ),
          );
          if (shouldPrint == true) {
            await ThermalPrinterService.instance.printPaymentReceipt(
              orderId: paidOrderId,
              lines: receiptItems,
              total: totalBeforeSubmit,
              paymentMethod: payment.method,
              paid: payment.totalPaymentReceived,
              change: payment.changeAmount,
              customerName: _customerName,
              tableName: _tableName,
            );
          }
        }
      }
    } catch (error) {
      if (!mounted) return;
      if (paidOrderId != null) {
        _showDropdownSnackbar(
          'Payment saved, but failed to print: $error',
          isError: true,
        );
      } else {
        _showDropdownSnackbar(
          'Failed to process payment: $error',
          isError: true,
        );
        return;
      }
    }

    _resetCurrentOrderDraft(showMessage: false);
    _showDropdownSnackbar(
      (paidOrderId ?? 0) > 0
          ? 'Payment success (${payment.method})'
          : 'Offline saved. Sync later from app menu.',
    );
  }

  String _buildCourierWhatsappMessage(CartProvider cart) {
    final itemsText = cart.items.values
        .map((item) => '- ${item.quantity}x ${item.name}')
        .join('\n');
    final mapLink = _extractOrderMapLink();
    return _courierMessageTemplate
        .replaceAll('{order_id}', (_currentActiveOrderId ?? '-').toString())
        .replaceAll('{customer_name}', (_customerName ?? '-').trim())
        .replaceAll('{order_type}', _orderType)
        .replaceAll('{order_total}', _formatRupiah(cart.totalAmount))
        .replaceAll('{map_link}', mapLink)
        .replaceAll('{order_items}', itemsText);
  }

  String _extractOrderMapLink() {
    final metadata = _currentOrderMetadata;
    final candidates = <String?>[
      metadata?['map_link']?.toString(),
      metadata?['maps_link']?.toString(),
      metadata?['location_link']?.toString(),
      metadata?['delivery_map_link']?.toString(),
      metadata?['delivery_address_link']?.toString(),
    ];
    for (final raw in candidates) {
      final value = raw?.trim() ?? '';
      if (value.startsWith('http://') || value.startsWith('https://')) {
        return value;
      }
    }

    final notes = metadata?['notes']?.toString() ?? '';
    final match = RegExp(r'https?://\S+').firstMatch(notes);
    if (match != null) {
      return match.group(0) ?? '-';
    }

    return '-';
  }

  Future<void> _handleSendOrderToCourier(CartProvider cart) async {
    if (_orderType != 'delivery') {
      _showDropdownSnackbar('Courier dispatch is only for delivery orders.');
      return;
    }
    final rawNumber = _courierWhatsappNumber.trim();
    if (rawNumber.isEmpty) {
      _showDropdownSnackbar(
        'Courier WhatsApp number is empty. Update it in App menu.',
        isError: true,
      );
      return;
    }

    final normalizedNumber = rawNumber.replaceAll(RegExp(r'[^0-9]'), '');
    final message = _buildCourierWhatsappMessage(cart);
    final uri = Uri.parse(
      'https://wa.me/$normalizedNumber?text=${Uri.encodeComponent(message)}',
    );
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    _showDropdownSnackbar(
      opened ? 'Courier WhatsApp opened.' : 'Could not open WhatsApp link.',
      isError: !opened,
    );
  }

  Future<void> _handleCompleteOnlineOrder() async {
    if (_currentActiveOrderId == null) {
      _showDropdownSnackbar('No active online order selected.', isError: true);
      return;
    }

    try {
      await supabase
          .from('orders')
          .update({'status': OrderStatus.completed})
          .eq('id', _currentActiveOrderId!);
      if (!mounted) return;
      _resetCurrentOrderDraft(showMessage: false);
      _showDropdownSnackbar('Order marked as completed.');
    } catch (error) {
      if (!mounted) return;
      _showDropdownSnackbar('Failed to complete order: $error', isError: true);
    }
  }

  Widget _buildMenuLayoutContent(List<Product> filteredProducts) {
    if (_menuLayout == 'list') {
      return ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        itemCount: filteredProducts.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final product = filteredProducts[index];
          return Card(
            child: ListTile(
              title: Text(product.name),
              subtitle: Text(product.category),
              trailing: Text(_formatRupiah(product.price)),
              onTap: () => _onProductTap(product),
            ),
          );
        },
      );
    }

    final crossAxisCount = _menuLayout == 'grid_3'
        ? 3
        : _menuLayout == 'grid_5'
        ? 5
        : 4;

    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16.0),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 4 / 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: filteredProducts.length,
      itemBuilder: (context, index) {
        final product = filteredProducts[index];
        return _buildProductCard(product);
      },
    );
  }

  Future<void> _showMenuViewSettingsDialog() async {
    final products = await _future;
    if (!mounted) return;

    final categories =
        products.map((product) => product.category).toSet().toList()..sort();

    final tempHiddenCategories = Set<String>.from(_hiddenMenuCategories);
    final tempCategoryColors = Map<String, Color>.from(_menuCategoryColors);
    var tempLayout = _menuLayout;
    var tempShowSearchBar = _showMenuSearchBar;
    var showVisibilitySettings = false;
    var showLayoutSettings = false;
    var showColorSettings = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Menu view settings'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExpansionTile(
                    title: const Text(
                      'Visible categories',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    initiallyExpanded: false,
                    maintainState: true,
                    onExpansionChanged: (value) =>
                        setDialogState(() => showVisibilitySettings = value),
                    children: [
                      if (showVisibilitySettings)
                        ...categories.map((category) {
                          final visible = !tempHiddenCategories.contains(
                            category,
                          );
                          return CheckboxListTile(
                            value: visible,
                            contentPadding: EdgeInsets.zero,
                            title: Text(category),
                            onChanged: (value) {
                              setDialogState(() {
                                if (value == true) {
                                  tempHiddenCategories.remove(category);
                                } else {
                                  tempHiddenCategories.add(category);
                                }
                              });
                            },
                          );
                        }),
                    ],
                  ),
                  ExpansionTile(
                    title: const Text(
                      'Layout',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    initiallyExpanded: false,
                    maintainState: true,
                    onExpansionChanged: (value) =>
                        setDialogState(() => showLayoutSettings = value),
                    children: [
                      if (showLayoutSettings) ...[
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Show search bar'),
                          value: tempShowSearchBar,
                          onChanged: (value) =>
                              setDialogState(() => tempShowSearchBar = value),
                        ),
                        RadioListTile<String>(
                          value: 'list',
                          groupValue: tempLayout,
                          title: const Text('List product layout'),
                          onChanged: (value) => setDialogState(
                            () => tempLayout = value ?? 'list',
                          ),
                        ),
                        RadioListTile<String>(
                          value: 'grid_3',
                          groupValue: tempLayout,
                          title: const Text('3 x 3 product grid'),
                          onChanged: (value) => setDialogState(
                            () => tempLayout = value ?? 'grid_3',
                          ),
                        ),
                        RadioListTile<String>(
                          value: 'grid_4',
                          groupValue: tempLayout,
                          title: const Text('4 x 4 product grid'),
                          onChanged: (value) => setDialogState(
                            () => tempLayout = value ?? 'grid_4',
                          ),
                        ),
                        RadioListTile<String>(
                          value: 'grid_5',
                          groupValue: tempLayout,
                          title: const Text('5 x 5 product grid'),
                          onChanged: (value) => setDialogState(
                            () => tempLayout = value ?? 'grid_5',
                          ),
                        ),
                      ],
                    ],
                  ),
                  ExpansionTile(
                    title: const Text(
                      'Category colors',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    initiallyExpanded: false,
                    maintainState: true,
                    onExpansionChanged: (value) =>
                        setDialogState(() => showColorSettings = value),
                    children: [
                      if (showColorSettings)
                        ...categories.map((category) {
                          final selectedColor =
                              tempCategoryColors[category] ??
                              _defaultCategoryColor(category);
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(category),
                            subtitle: Wrap(
                              spacing: 8,
                              children: [
                                ..._menuCategoryPalette.map((color) {
                                  final isSelected =
                                      selectedColor.value == color.value;
                                  return InkWell(
                                    onTap: () => setDialogState(
                                      () =>
                                          tempCategoryColors[category] = color,
                                    ),
                                    borderRadius: BorderRadius.circular(99),
                                    child: Container(
                                      width: 26,
                                      height: 26,
                                      decoration: BoxDecoration(
                                        color: color,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: isSelected
                                              ? Colors.black
                                              : Colors.transparent,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ],
                            ),
                          );
                        }),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _hiddenMenuCategories
                    ..clear()
                    ..addAll(tempHiddenCategories);
                  _menuCategoryColors
                    ..clear()
                    ..addAll(tempCategoryColors);
                  _menuLayout = tempLayout;
                  _showMenuSearchBar = tempShowSearchBar;
                  if (!_showMenuSearchBar) {
                    _menuSearchController.clear();
                    _menuSearchQuery = '';
                  }
                });
                unawaited(_refreshMenuProjection());
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  static const List<Color> _menuCategoryPalette = [
    Colors.blue,
    Colors.teal,
    Colors.green,
    Colors.orange,
    Colors.deepOrange,
    Colors.purple,
    Colors.indigo,
    Colors.brown,
    Colors.red,
    Colors.blueGrey,
  ];

  Color _defaultCategoryColor(String category) {
    switch (category.trim().toLowerCase()) {
      case 'coffee':
        return Colors.blue.shade700;
      case 'tea':
        return Colors.lightBlue.shade600;
      case 'non coffee':
      case 'non-coffee':
        return Colors.indigo.shade400;
      case 'dessert':
      case 'pastry':
        return Colors.blue.shade400;
      default:
        return Colors.blueGrey.shade500;
    }
  }

  Color _categoryColor(String category) {
    return _menuCategoryColors[category] ?? _defaultCategoryColor(category);
  }

  Map<String, CartItem> _selectedCartEntries() {
    final cart = context.read<CartProvider>();
    final selected = <String, CartItem>{};
    for (final key in _selectedCartItems) {
      final item = cart.items[key];
      if (item != null) {
        selected[key] = item;
      }
    }
    return selected;
  }

  Future<Map<String, dynamic>?> _showSelectOrderDialog({
    required String title,
    required List<Map<String, dynamic>> orders,
  }) async {
    if (orders.isEmpty) {
      return null;
    }

    final sortedOrders = List<Map<String, dynamic>>.from(orders)
      ..sort((a, b) {
        final aTime = DateTime.tryParse((a['created_at'] ?? '').toString());
        final bTime = DateTime.tryParse((b['created_at'] ?? '').toString());
        if (aTime == null && bTime == null) {
          final aId = (a['id'] as num?)?.toInt() ?? 0;
          final bId = (b['id'] as num?)?.toInt() ?? 0;
          return bId.compareTo(aId);
        }
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 500,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: sortedOrders.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final order = sortedOrders[index];
                final orderId = order['id'];
                final customerName = order['customer_name'] ?? 'Guest';
                final total = order['total_price'] ?? 0;
                final orderTime = _onlineTimeLabel(order['created_at']);
                return ListTile(
                  title: Text('Order #$orderId - $customerName'),
                  subtitle: Text(
                    'Total: ${CurrencyFormatters.formatRupiah(total)} • $orderTime',
                  ),
                  onTap: () => Navigator.of(dialogContext).pop(order),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  dynamic _canonicalizeJsonValue(dynamic value) {
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      return {
        for (final entry in entries)
          entry.key.toString(): _canonicalizeJsonValue(entry.value),
      };
    }

    if (value is List) {
      final canonicalItems = value.map(_canonicalizeJsonValue).toList();
      final allScalar = canonicalItems.every(
        (item) => item is String || item is num || item is bool || item == null,
      );
      if (allScalar) {
        canonicalItems.sort((a, b) => a.toString().compareTo(b.toString()));
        return canonicalItems;
      }

      canonicalItems.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
      return canonicalItems;
    }

    return value;
  }

  Future<List<int>> _matchSelectedOrderItemIds({
    required List<Map<String, dynamic>> rows,
    required Iterable<CartItem> selectedItems,
  }) async {
    final rowPayload = rows
        .map(
          (row) => {'id': row['id'], 'signature': _orderItemRowSignature(row)},
        )
        .toList(growable: false);
    final selectedSignatures = selectedItems
        .map(_selectedCartItemSignature)
        .toList(growable: false);
    return compute(_matchSelectedOrderItemIdsWorker, {
      'rows': rowPayload,
      'selectedSignatures': selectedSignatures,
    });
  }

  num _normalizeNum(num value) {
    final rounded = value.roundToDouble();
    if ((value - rounded).abs() < 0.000001) {
      return rounded.toInt();
    }
    return value;
  }

  String? _buildOrderNotes({String? tableName, String? extraNote}) {
    final parts = <String>[];
    final normalizedTable = tableName?.trim() ?? '';
    final normalizedExtra = extraNote?.trim() ?? '';

    if (normalizedTable.isNotEmpty) {
      parts.add('Table: $normalizedTable');
    }

    if (normalizedExtra.isNotEmpty) {
      parts.add(normalizedExtra);
    }

    if (parts.isEmpty) {
      return null;
    }

    return parts.join('\n');
  }

  String? _tableNameFromNotes(String? notes) {
    if (notes == null || notes.trim().isEmpty) {
      return null;
    }

    for (final line in notes.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('Table:')) {
        final table = trimmed.replaceFirst('Table:', '').trim();
        return table.isEmpty ? null : table;
      }
    }

    return null;
  }

  Future<int> _createActiveOrderDraft({
    String? customerName,
    String? tableName,
    required String orderType,
    int? parentOrderId,
    String? extraNote,
  }) async {
    final orderId = await _generateDailyUniqueOrderId();
    await supabase.from('orders').insert({
      'id': orderId,
      'status': 'active',
      'type': orderType,
      'order_source': 'cashier',
      'payment_method': null,
      'total_price': 0,
      'subtotal': 0,
      'discount_total': 0,
      'points_earned': 0,
      'points_used': 0,
      'total_payment_received': null,
      'change_amount': null,
      'customer_name': customerName,
      'parent_order_id': parentOrderId,
      'cashier_id': _activeCashierId,
      'shift_id': _activeShiftId,
      'notes': _buildOrderNotes(tableName: tableName, extraNote: extraNote),
    });

    return orderId;
  }

  Future<void> _insertCartEntriesToOrder({
    required int orderId,
    required Iterable<CartItem> items,
  }) async {
    final payload = items
        .map(
          (item) => {
            'order_id': orderId,
            'product_id': item.id,
            'quantity': item.quantity,
            'price_at_time': item.price,
            'modifiers': item.modifiers?.toJson(),
          },
        )
        .toList();

    if (payload.isEmpty) {
      return;
    }

    await supabase.from('order_items').insert(payload);
  }

  Future<bool> _cancelSourceIfNoRemainingItems(
    int sourceOrderId, {
    String? extraNote,
  }) async {
    final remaining = await _fetchOrderItemRows(sourceOrderId);
    if (remaining.isNotEmpty) {
      return false;
    }

    final existingOrder = await supabase
        .from('orders')
        .select('notes')
        .eq('id', sourceOrderId)
        .single();
    final existingNotes = existingOrder['notes']?.toString();

    final updatedNotes = _buildOrderNotes(
      tableName: _tableNameFromNotes(existingNotes),
      extraNote: extraNote,
    );

    await supabase
        .from('orders')
        .update({'status': OrderStatus.cancelled, 'notes': updatedNotes})
        .eq('id', sourceOrderId);
    return true;
  }

  Future<_ModifierSelectionResult?> _showProductConfigModal(
    Product product,
    List<ProductModifier> modifiers, {
    int initialQuantity = 1,
    CartModifiers? initialModifiers,
  }) async {
    var quantity = initialQuantity;
    final selectedByModifier = <String, List<ModifierOption>>{
      for (final modifier in modifiers) modifier.id: <ModifierOption>[],
    };

    if (initialModifiers != null) {
      for (final modifier in modifiers) {
        final names = initialModifiers.selections[modifier.name] ?? <String>[];
        selectedByModifier[modifier.id] = modifier.options
            .where((option) => names.contains(option.name))
            .toList();
      }
    }

    return showDialog<_ModifierSelectionResult>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogStateContext, setState) {
            final selectedModifierExtra = selectedByModifier.values
                .expand((items) => items)
                .fold<double>(0, (sum, option) => sum + option.price);
            final lineTotal =
                (product.price + selectedModifierExtra) * quantity;

            return AlertDialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 28,
                vertical: 24,
              ),
              constraints: const BoxConstraints(maxWidth: 460),
              title: Text('Customize ${product.name}'),
              content: SizedBox(
                width: 420,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Quantity',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: quantity > 1
                              ? () => setState(() => quantity--)
                              : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        Text('$quantity', style: const TextStyle(fontSize: 16)),
                        IconButton(
                          onPressed: () => setState(() => quantity++),
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                    const Divider(),
                    ...modifiers.map((modifier) {
                      final currentSelected =
                          selectedByModifier[modifier.id] ?? <ModifierOption>[];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${modifier.name}${modifier.isRequired ? ' *' : ''}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            ...modifier.options.map((option) {
                              final isSingle = modifier.type == 'single';
                              final isSelected = currentSelected.any(
                                (item) => item.id == option.id,
                              );

                              if (isSingle) {
                                return RadioListTile<String>(
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  title: Text(_optionLabel(option)),
                                  value: option.id,
                                  groupValue: currentSelected.isEmpty
                                      ? null
                                      : currentSelected.first.id,
                                  onChanged: (_) {
                                    setState(() {
                                      selectedByModifier[modifier.id] = [
                                        option,
                                      ];
                                    });
                                  },
                                );
                              }

                              return CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: Text(_optionLabel(option)),
                                value: isSelected,
                                onChanged: (checked) {
                                  setState(() {
                                    final next = List<ModifierOption>.from(
                                      currentSelected,
                                    );
                                    if (checked == true) {
                                      if (!next.any(
                                        (item) => item.id == option.id,
                                      )) {
                                        next.add(option);
                                      }
                                    } else {
                                      next.removeWhere(
                                        (item) => item.id == option.id,
                                      );
                                    }
                                    selectedByModifier[modifier.id] = next;
                                  });
                                },
                              );
                            }),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
              actions: [
                SizedBox(
                  width: double.maxFinite,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Total: ${_formatRupiah(lineTotal)}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () {
                                final missingRequired = modifiers.any(
                                  (modifier) =>
                                      modifier.isRequired &&
                                      (selectedByModifier[modifier.id] ??
                                              <ModifierOption>[])
                                          .isEmpty,
                                );

                                if (missingRequired) {
                                  _showDropdownSnackbar(
                                    'Please complete all required modifiers.',
                                    isError: true,
                                  );
                                  return;
                                }

                                final cartSelections = <String, List<String>>{};
                                final modifiersData = <Map<String, dynamic>>[];

                                for (final modifier in modifiers) {
                                  final selected =
                                      selectedByModifier[modifier.id] ??
                                      <ModifierOption>[];
                                  if (selected.isEmpty) continue;

                                  cartSelections[modifier.name] = selected
                                      .map((item) => item.name)
                                      .toList();

                                  modifiersData.add({
                                    'modifier_id': modifier.id,
                                    'modifier_name': modifier.name,
                                    'type': modifier.type,
                                    'selected_options': selected
                                        .map(
                                          (option) => {
                                            'id': option.id,
                                            'name': option.name,
                                            'price': option.price,
                                          },
                                        )
                                        .toList(),
                                  });
                                }

                                Navigator.of(dialogContext).pop(
                                  _ModifierSelectionResult(
                                    quantity: quantity,
                                    cartModifiers: cartSelections.isEmpty
                                        ? null
                                        : CartModifiers(
                                            selections: cartSelections,
                                            notes: '',
                                          ),
                                    modifiersData: modifiersData,
                                  ),
                                );
                              },
                              child: const Text('Add to Cart'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  bool get _hasOrderDetailDraft {
    final customer = _customerName?.trim() ?? '';
    final table = _tableName?.trim() ?? '';
    return customer.isNotEmpty || table.isNotEmpty;
  }

  dynamic _normalizeRawModifiers(dynamic rawModifiers) {
    if (rawModifiers is String) {
      try {
        return jsonDecode(rawModifiers);
      } catch (_) {
        return null;
      }
    }
    return rawModifiers;
  }

  Map<String, String> _modifierGroupNameLookup(Product product) {
    final lookup = <String, String>{};
    final groups = product.productModifiers;
    if (groups == null) {
      return lookup;
    }

    for (final group in groups.whereType<Map<String, dynamic>>()) {
      final id = group['id']?.toString();
      final name = group['name']?.toString();
      if (id != null && name != null && name.isNotEmpty) {
        lookup[id] = name;
      }
    }

    return lookup;
  }

  Map<String, double> _modifierOptionPriceByNameLookup(Product product) {
    final lookup = <String, double>{};
    final groups = product.productModifiers;
    if (groups == null) {
      return lookup;
    }

    for (final group in groups.whereType<Map<String, dynamic>>()) {
      final options =
          (group['options'] as List<dynamic>?) ??
          (group['modifier_options'] as List<dynamic>?) ??
          <dynamic>[];
      for (final option in options.whereType<Map<String, dynamic>>()) {
        final name = option['name']?.toString();
        if (name != null && name.isNotEmpty) {
          lookup[name] = (option['price'] as num?)?.toDouble() ?? 0;
        }
      }
    }

    return lookup;
  }

  Map<String, String> _modifierOptionNameLookup(Product product) {
    final lookup = <String, String>{};
    final groups = product.productModifiers;
    if (groups == null) {
      return lookup;
    }

    for (final group in groups.whereType<Map<String, dynamic>>()) {
      final options =
          (group['options'] as List<dynamic>?) ??
          (group['modifier_options'] as List<dynamic>?) ??
          <dynamic>[];
      for (final option in options.whereType<Map<String, dynamic>>()) {
        final id = option['id']?.toString();
        final name = option['name']?.toString();
        if (id != null && name != null && name.isNotEmpty) {
          lookup[id] = name;
        }
      }
    }

    return lookup;
  }

  Map<String, double> _modifierOptionPriceLookup(Product product) {
    final lookup = <String, double>{};
    final groups = product.productModifiers;
    if (groups == null) {
      return lookup;
    }

    for (final group in groups.whereType<Map<String, dynamic>>()) {
      final options =
          (group['options'] as List<dynamic>?) ??
          (group['modifier_options'] as List<dynamic>?) ??
          <dynamic>[];
      for (final option in options.whereType<Map<String, dynamic>>()) {
        final id = option['id']?.toString();
        if (id != null) {
          lookup[id] = (option['price'] as num?)?.toDouble() ?? 0;
        }
      }
    }

    return lookup;
  }

  CartModifiers? _toCartModifiers(dynamic rawModifiers, Product product) {
    final normalized = _normalizeRawModifiers(rawModifiers);
    if (normalized == null) {
      return null;
    }

    if (normalized is Map<String, dynamic>) {
      final selectionsRaw = normalized['selections'];
      if (selectionsRaw is Map<String, dynamic>) {
        return CartModifiers.fromJson(normalized);
      }

      final selectedOptions = normalized['selected_options'];
      if (selectedOptions is List) {
        final names = selectedOptions
            .whereType<Map<String, dynamic>>()
            .map((entry) => entry['name']?.toString() ?? '')
            .where((name) => name.isNotEmpty)
            .toList();

        return CartModifiers(
          selections: {
            normalized['modifier_name']?.toString() ?? 'Modifier': names,
          },
          notes: '',
        );
      }

      final groupNameLookup = _modifierGroupNameLookup(product);
      final optionLookup = _modifierOptionNameLookup(product);
      final selections = <String, List<String>>{};

      for (final entry in normalized.entries) {
        final optionIds = (entry.value as List<dynamic>? ?? <dynamic>[])
            .map((item) => item.toString())
            .toList();

        if (optionIds.isEmpty) {
          continue;
        }

        final groupName = groupNameLookup[entry.key] ?? entry.key;
        final optionNames = optionIds
            .map((id) => optionLookup[id] ?? id)
            .toList();
        selections[groupName] = optionNames;
      }

      if (selections.isNotEmpty) {
        return CartModifiers(selections: selections, notes: '');
      }
    }

    if (normalized is List) {
      final selections = <String, List<String>>{};
      for (final group in normalized.whereType<Map<String, dynamic>>()) {
        final groupName =
            group['modifier_name']?.toString() ??
            group['name']?.toString() ??
            'Modifier';
        final selected =
            (group['selected_options'] as List<dynamic>? ?? <dynamic>[])
                .whereType<Map<String, dynamic>>()
                .map((entry) => entry['name']?.toString() ?? '')
                .where((name) => name.isNotEmpty)
                .toList();
        if (selected.isNotEmpty) {
          selections[groupName] = selected;
        }
      }
      if (selections.isNotEmpty) {
        return CartModifiers(selections: selections, notes: '');
      }
    }

    return null;
  }

  List<dynamic>? _toModifiersData(dynamic rawModifiers, Product product) {
    final normalized = _normalizeRawModifiers(rawModifiers);
    if (normalized == null) {
      return null;
    }

    if (normalized is List) {
      return normalized;
    }

    if (normalized is Map<String, dynamic>) {
      if (normalized['selected_options'] != null) {
        return [normalized];
      }

      if (normalized['selections'] is Map<String, dynamic>) {
        final optionPriceByName = _modifierOptionPriceByNameLookup(product);
        final selections =
            normalized['selections'] as Map<String, dynamic>? ??
            <String, dynamic>{};
        final list = <Map<String, dynamic>>[];

        for (final entry in selections.entries) {
          final selectedOptions = (entry.value as List<dynamic>? ?? <dynamic>[])
              .map((value) => value.toString())
              .where((name) => name.isNotEmpty)
              .map(
                (name) => {'name': name, 'price': optionPriceByName[name] ?? 0},
              )
              .toList();

          if (selectedOptions.isEmpty) {
            continue;
          }

          list.add({
            'modifier_name': entry.key,
            'selected_options': selectedOptions,
          });
        }

        return list.isEmpty ? null : list;
      }

      final groupNameLookup = _modifierGroupNameLookup(product);
      final optionLookup = _modifierOptionNameLookup(product);
      final optionPriceLookup = _modifierOptionPriceLookup(product);
      final list = <Map<String, dynamic>>[];

      for (final entry in normalized.entries) {
        final selectedOptions = (entry.value as List<dynamic>? ?? <dynamic>[])
            .map((id) {
              final optionId = id.toString();
              return {
                'id': optionId,
                'name': optionLookup[optionId] ?? optionId,
                'price': optionPriceLookup[optionId] ?? 0,
              };
            })
            .toList();

        if (selectedOptions.isEmpty) {
          continue;
        }

        list.add({
          'modifier_id': entry.key,
          'modifier_name': groupNameLookup[entry.key] ?? entry.key,
          'selected_options': selectedOptions,
        });
      }

      return list.isEmpty ? null : list;
    }

    return null;
  }
}

class _SplitBoardItem {
  _SplitBoardItem({
    required this.id,
    required this.name,
    required this.quantity,
    required this.unitPrice,
  });

  final String id;
  final String name;
  int quantity;
  final num unitPrice;
}

class _SplitGroup {
  _SplitGroup({required this.id, required this.groupName, required this.items});

  final String id;
  final String groupName;
  final List<_SplitBoardItem> items;
}
