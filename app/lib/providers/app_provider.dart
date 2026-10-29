import '../data/store_catalog.dart';
import 'package:flutter/material.dart';
import 'dart:async';

import '../services/api_service.dart';
import '../data/product_catalog.dart';
import '../data/inventory_preview.dart';

class AppProvider with ChangeNotifier {
  String? role; // 'manager', 'staff', 'customer'
  Map<String, dynamic>? currentUser;

  String selectedStoreId = 'STORE_01';
  String get selectedStoreName => storeName(selectedStoreId);
  bool get isPreview => !isBackendOnline;
  String? _normalDate;
  Timer? _demoCalendarTimer;
  bool _disposed = false;
  Timer? _sessionExpiryTimer;
  bool get isAccountAdmin => currentUser?['role'] == 'admin';
  Future<void> updateAccountProfile(String name, String phone) async {
    currentUser = Map<String, dynamic>.from(
      await ApiService.accountRequest('PATCH', 'auth/me', {
        'name': name,
        'phone': phone,
      }),
    );
    notifyListeners();
  }

  List<String> get accessibleStoreIds {
    if (role == 'customer' ||
        currentUser?['role'] == 'admin' ||
        currentUser == null) {
      return ['STORE_01', 'STORE_02', 'STORE_03', 'STORE_04'];
    }
    return List<String>.from(currentUser?['stores'] ?? []);
  }

  Future<void> signInAccount(
    String action,
    Map<String, dynamic> body, {
    bool demo = false,
  }) async {
    final session = await ApiService.accountRequest(
      'POST',
      'auth/$action',
      body,
      demo,
    );
    _demoCalendarTimer?.cancel();
    ApiService.demoMode = demo;
    ApiService.accessToken = session['access_token'] as String;
    currentUser = Map<String, dynamic>.from(session['user']);
    role = currentUser!['role'] == 'admin'
        ? 'manager'
        : currentUser!['role'] as String;
    final stores = accessibleStoreIds;
    if (!stores.contains(selectedStoreId)) selectedStoreId = stores.first;
    ApiService.defaultStoreId = selectedStoreId;
    ApiService.defaultDate = demo
        ? ApiService.demoDate
        : DateTime.now()
              .toUtc()
              .add(const Duration(hours: 7))
              .toIso8601String()
              .substring(0, 10);
    _sessionExpiryTimer?.cancel();
    final expiry = DateTime.fromMillisecondsSinceEpoch(
      ((session['expires_at'] as num) * 1000).toInt(),
      isUtc: true,
    );
    _sessionExpiryTimer = Timer(
      expiry.difference(DateTime.now().toUtc()),
      () => setRole(null),
    );
    notifyListeners();
    await checkBackendConnection();
    _startDemoCalendarTimer();
  }

  void setRole(String? newRole) {
    if (newRole != null) {
      return; // Both realms use the identity returned by the server.
    }
    if (newRole == null) {
      // Revoke the server session, then clear local identity immediately.
      final token = ApiService.accessToken;
      if (token != null) {
        unawaited(
          ApiService.accountRequest(
            'POST',
            'auth/logout',
          ).catchError((_) => <String, dynamic>{}),
        );
      }
      ApiService.accessToken = null;
      _sessionExpiryTimer?.cancel();
      currentUser = null;
      role = null;
      savedDealIds.clear();
      claimedVouchers.clear();
      backendInventory = [];
      backendRecommendations = [];
      backendDashboardSummary = null;
      backendDeals = [];
      discounts = [];
      alerts = [];
      notifications = [];
      aisles = [];
    }
    notifyListeners();
  }

  Future<void> setDealDemo(bool enabled) async {
    if (isSyncingBackend || ApiService.demoMode == enabled) return;
    lastBackendError = null;
    isSyncingBackend = true;
    notifyListeners();
    try {
      if (enabled) {
        final setup = await ApiService.setupDealDemo();
        ApiService.demoSessionDate =
            setup['session_started_date'] as String? ?? '';
        ApiService.demoDate = setup['business_date'] as String;
        final day = await ApiService.demoDayAction('day', selectedStoreId);
        ApiService.demoAutomaticCalendar = day['automatic_calendar'] == true;
        ApiService.demoDate = day['business_date'] as String;
      }
      if (enabled) _normalDate = ApiService.defaultDate;
      setRole(null);
      ApiService.demoMode = enabled;
      if (!enabled && !accessibleStoreIds.contains(selectedStoreId)) {
        selectedStoreId = accessibleStoreIds.first;
        ApiService.defaultStoreId = selectedStoreId;
      }
      ApiService.defaultDate = enabled
          ? ApiService.demoDate
          : (_normalDate ?? ApiService.demoDate);
      if (enabled) ApiService.weatherMode = 'mock';
      aisles = [];
      discounts = [];
      alerts = [];
      notifications = [];
      backendRecommendations = [];
      backendDeals = [];
      backendDashboardSummary = null;
      await checkBackendConnection();
      _startDemoCalendarTimer();
    } catch (error) {
      lastBackendError = error.toString();
      backendStatusMessage = lastBackendError!;
    } finally {
      isSyncingBackend = false;
      notifyListeners();
    }
  }

  void _startDemoCalendarTimer() {
    _demoCalendarTimer?.cancel();
    if (ApiService.demoMode && ApiService.demoAutomaticCalendar) {
      _demoCalendarTimer = Timer.periodic(const Duration(seconds: 30), (
        _,
      ) async {
        if (!ApiService.demoMode || !isBackendOnline || isSyncingBackend) {
          return;
        }
        try {
          final store = selectedStoreId;
          final day = await ApiService.demoDayAction('day', selectedStoreId);
          if (_disposed || store != selectedStoreId || !ApiService.demoMode) {
            return;
          }
          if (day['business_date'] != ApiService.defaultDate) {
            await syncWithBackend();
          }
        } catch (error) {
          if (_disposed) return;
          lastBackendError = 'Demo calendar refresh failed: $error';
          notifyListeners();
        }
      });
    }
  }

  bool isDealAvailable(Map<String, dynamic> deal) {
    if (deal['status'] != 'active' ||
        deal['saleAllowed'] != true ||
        (deal['stock'] as num? ?? 0) <= 0) {
      return false;
    }
    final expiry = DateTime.tryParse(deal['expiryDate']?.toString() ?? '');
    if (expiry == null) return false;
    if ((deal['demoMode'] == true) != ApiService.demoMode) return false;
    final bangkok = ApiService.demoMode
        ? DateTime.parse(ApiService.demoDate)
        : DateTime.now().toUtc().add(const Duration(hours: 7));
    final today = DateTime.utc(bangkok.year, bangkok.month, bangkok.day);
    return !DateTime.utc(expiry.year, expiry.month, expiry.day).isBefore(today);
  }

  @override
  void dispose() {
    _disposed = true;
    _demoCalendarTimer?.cancel();
    _sessionExpiryTimer?.cancel();
    super.dispose();
  }

  Future<String> runDemoDayAction(String action) async {
    if (!ApiService.demoMode || isSyncingBackend) {
      return 'Demo is unavailable or busy.';
    }
    isSyncingBackend = true;
    notifyListeners();
    try {
      final result = await ApiService.demoDayAction(action, selectedStoreId);
      if (action == 'advance') {
        ApiService.demoDate = result['business_date'] as String;
        ApiService.defaultDate = ApiService.demoDate;
      }
      await syncWithBackend();
      if (action == 'reset-discount-approvals') {
        return 'Reset ${result['reset_count']} discount approvals. Customer offers withdrawn.';
      }
      return action == 'advance'
          ? 'Demo advanced to ${ApiService.demoDate}. Run a new forecast.'
          : 'Simulated ${result['simulated_products']} products; preserved ${result['preserved_products']} existing closures.';
    } catch (error) {
      return error.toString();
    } finally {
      isSyncingBackend = false;
      notifyListeners();
    }
  }

  List<Map<String, dynamic>> get customerDeals =>
      discounts.where(isDealAvailable).toList();
  String? lastBackendError;
  DateTime? lastSuccessfulSyncAt;
  List<String> syncFailures = [];

  Future<void> selectDate(String day) async {
    if (isSyncingBackend) return;
    if (ApiService.demoMode && day != ApiService.demoDate) return;
    ApiService.defaultDate = day;
    if (isBackendOnline) {
      await syncWithBackend();
    } else {
      aisles = [];
      discounts = [];
      alerts = [];
      backendRecommendations = [];
      backendDashboardSummary = null;
      notifyListeners();
    }
  }

  void _loadPreview() {
    aisles = previewInventory
        .where((row) => row['storeId'] == selectedStoreId)
        .map((row) {
          final product = _getCatalogItem(row['productId'] as String);
          final stock = row['stock'] as int;
          final days = row['daysToExpiry'] as num;
          return <String, dynamic>{
            ...row,
            'id': '${row['storeId']}-${row['productId']}',
            'name': product['name'],
            'label': product['name'],
            'category': product['category'],
            'icon': product['emoji'],
            'price': product['price'],
            'maxStock': stock > 40 ? stock : 40,
            'status': stock == 0
                ? 'critical'
                : (days <= 2 ? 'expiring' : 'normal'),
            'snapshotDate': previewDate,
            'snapshotSource': 'MOCK inventory preview',
          };
        })
        .toList();
  }

  Future<void> selectStore(String storeId) async {
    if (isSyncingBackend || storeId == selectedStoreId) return;
    if (!accessibleStoreIds.contains(storeId)) return;
    selectedStoreId = storeId;
    ApiService.defaultStoreId = storeId;
    if (ApiService.demoMode && isBackendOnline) {
      final day = await ApiService.demoDayAction('day', storeId);
      ApiService.demoDate = day['business_date'] as String;
      ApiService.defaultDate = ApiService.demoDate;
    }
    if (currentUser != null) {
      currentUser = {...currentUser!, 'branch': selectedStoreName};
    }
    discounts = [];
    alerts = [];
    notifications = [];
    if (isBackendOnline) {
      await syncWithBackend();
    } else {
      _loadPreview();
      notifyListeners();
    }
  }

  // Backend Integration State
  bool isBackendOnline = false;
  bool isSyncingBackend = false;
  String backendStatusMessage = 'Offline (Using Mock Data)';
  Map<String, dynamic>? backendDashboardSummary;
  List<Map<String, dynamic>> backendInventory = [];
  List<Map<String, dynamic>> backendRecommendations = [];
  List<Map<String, dynamic>> backendDeals = [];

  AppProvider({bool connectOnStart = true}) {
    // Proactively check backend connection on app launch
    _loadPreview();
    if (connectOnStart) checkBackendConnection();
  }

  List<Map<String, dynamic>> aisles = [];
  List<Map<String, dynamic>> alerts = [];
  List<Map<String, dynamic>> discounts = [];
  List<Map<String, dynamic>> notifications = [];

  final Set<String> savedDealIds = {'d1', 'd2'};
  final List<Map<String, dynamic>> claimedVouchers = [];

  int demoScenarioStep =
      0; // 0: Normal, 1: 16:00, 2: 18:00 Rain, 3: 19:00 Stockout, 4: Restocked, 5: Summary

  // Restock an aisle by ID (used by both Manager and Staff)
  void restockAisle(String aisleId, {int newStock = 40}) {
    if (isBackendOnline) return;
    for (int i = 0; i < aisles.length; i++) {
      if (aisles[i]['id'] == aisleId) {
        final maxStock = (aisles[i]['maxStock'] as num?)?.toInt() ?? 40;
        aisles[i] = {
          ...aisles[i],
          'status': 'normal',
          'stock': newStock > maxStock ? maxStock : newStock,
        };
      }
    }

    // Resolve any open alerts for this aisle
    for (int i = 0; i < alerts.length; i++) {
      if (alerts[i]['aisleId'] == aisleId &&
          alerts[i]['status'] != 'resolved') {
        alerts[i] = {
          ...alerts[i],
          'status': 'resolved',
          'detail': 'Restocked successfully by Staff Alex.',
        };
      }
    }

    // Add resolved notification
    notifications.insert(0, {
      'id': 'n-restock-${DateTime.now().millisecondsSinceEpoch}',
      'type': 'resolved',
      'title': 'Restock Completed — $aisleId',
      'detail': 'Display replenished to full capacity.',
      'time': 'Just now',
      'unread': true,
    });

    notifyListeners();
  }

  // Adjust stock count manually
  void adjustStock(String aisleId, int delta) {
    if (isBackendOnline) return;
    for (int i = 0; i < aisles.length; i++) {
      if (aisles[i]['id'] == aisleId) {
        final current = (aisles[i]['stock'] as num).toInt();
        final maxStock = (aisles[i]['maxStock'] as num).toInt();
        final updated = (current + delta).clamp(0, maxStock);

        String newStatus = aisles[i]['status'];
        if (updated <= 5) {
          newStatus = 'critical';
        } else if (updated <= 10) {
          newStatus = 'low';
        } else if (newStatus == 'critical' || newStatus == 'low') {
          newStatus = 'normal';
        }

        aisles[i] = {...aisles[i], 'stock': updated, 'status': newStatus};
      }
    }
    notifyListeners();
  }

  // Apply or update dynamic discount
  void applyDiscount(String dealId, int discountPercent) {
    for (int i = 0; i < discounts.length; i++) {
      if (discounts[i]['id'] == dealId &&
          !isBackendOnline &&
          isDealAvailable(discounts[i])) {
        final original = (discounts[i]['originalPrice'] as num).toDouble();
        final finalPrice = original * (1 - (discountPercent / 100));
        discounts[i] = {
          ...discounts[i],
          'discountPercent': discountPercent,
          'finalPrice': (finalPrice * 10).round() / 10,
          'status': 'active',
        };

        // Also update aisle status to promo
        final aisleId = discounts[i]['aisleId'];
        if (aisleId != null) {
          for (int a = 0; a < aisles.length; a++) {
            if (aisles[a]['id'] == aisleId) {
              aisles[a] = {...aisles[a], 'status': 'promo'};
            }
          }
        }
      }
    }

    notifications.insert(0, {
      'id': 'n-disc-${DateTime.now().millisecondsSinceEpoch}',
      'type': 'ai',
      'title': 'AI Pricing Activated: $discountPercent% OFF',
      'detail': 'Updated in POS and published to Customer Feed.',
      'time': 'Just now',
      'unread': true,
    });

    notifyListeners();
  }

  // Toggle Save Deal bookmark
  void toggleSaveDeal(String dealId) {
    if (savedDealIds.contains(dealId)) {
      savedDealIds.remove(dealId);
    } else {
      savedDealIds.add(dealId);
    }
    notifyListeners();
  }

  // Claim Deal Voucher
  Map<String, dynamic>? claimDeal(String dealId) {
    for (int i = 0; i < discounts.length; i++) {
      if (discounts[i]['id'] == dealId) {
        if (!isDealAvailable(discounts[i])) return null;

        final voucher = {
          'id':
              'VOUCH-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
          'dealId': dealId,
          'productId': discounts[i]['productId'],
          'discountPercent': discounts[i]['discountPercent'],
          'finalPrice': discounts[i]['finalPrice'],
          'claimedAt': DateTime.now(),
          'expiresIn': 'valid through ${discounts[i]['expiryDate']} (Bangkok)',
          'expiryDate': discounts[i]['expiryDate'],
          'qrCode':
              'FRESH-${discounts[i]['productId']}-${DateTime.now().millisecondsSinceEpoch}',
        };

        voucher['demoMode'] = ApiService.demoMode;
        voucher['storeId'] = selectedStoreId;
        claimedVouchers.insert(0, voucher);
        notifyListeners();
        return voucher;
      }
    }
    return null;
  }

  // Scenario Player for pitch demonstrations
  void applyScenarioStep(int step) {
    // Legacy hourly scenarios are unsupported by the daily model.
  }

  /// Check whether FastAPI backend at http://127.0.0.1:8000 is reachable
  Future<bool> checkBackendConnection() async {
    isSyncingBackend = true;
    notifyListeners();

    try {
      final healthy = await ApiService.checkHealth();
      isBackendOnline = healthy;
      if (healthy) {
        backendStatusMessage = 'Connected: FastAPI (${ApiService.baseUrl})';
        // Auto fetch initial data
        await syncWithBackend();
      } else {
        backendStatusMessage = 'Offline (Using Mock Data)';
        backendDashboardSummary = null;
        backendRecommendations = [];
        backendDeals = [];
        discounts = [];
        alerts = [];
        notifications = [];
        if (ApiService.defaultDate == previewDate) {
          _loadPreview();
        } else {
          aisles = [];
        }
      }
    } catch (e) {
      isBackendOnline = false;
      backendStatusMessage = 'Offline: $e';
    } finally {
      isSyncingBackend = false;
      notifyListeners();
    }
    return isBackendOnline;
  }

  /// Sync all live data from FastAPI Backend
  Future<void> syncWithBackend() async {
    if (!isBackendOnline) return;

    isSyncingBackend = true;
    syncFailures = [];
    lastBackendError = null;
    lastSuccessfulSyncAt = null;
    notifyListeners();

    try {
      if (ApiService.demoMode) {
        final day = await ApiService.demoDayAction('day', selectedStoreId);
        ApiService.demoAutomaticCalendar = day['automatic_calendar'] == true;
        ApiService.demoDate = day['business_date'] as String;
        ApiService.defaultDate = ApiService.demoDate;
        ApiService.demoSessionDate =
            day['session_started_date'] as String? ?? '';
      }
      final errors = <String>[];
      backendDashboardSummary = null;
      backendInventory = [];
      backendRecommendations = [];
      backendDeals = [];
      aisles = [];
      discounts = [];
      alerts = [];
      if (role == 'customer' || ApiService.accessToken == null) {
        backendDeals = await ApiService.getDeals();
        discounts = backendDeals
            .map(
              (offer) => <String, dynamic>{
                'id':
                    '${ApiService.demoMode ? 'DEMO-' : ''}REC-${offer['recommendation_id']}',
                'productId': offer['product_id'],
                'productName': offer['product_name'],
                'name': offer['product_name'],
                'storeId': offer['store_id'],
                'originalPrice': offer['original_price_usd'],
                'finalPrice': offer['selling_price_usd'],
                'discountPercent': offer['discount_percent'],
                'stock': offer['stock_units'],
                'expiryDate': offer['expiry_date'],
                'expiryFormatted': '${offer['expiry_date']} (Bangkok)',
                'status': 'active',
                'saleAllowed': true,
                'demoMode': ApiService.demoMode,
                'approvalStatus': 'APPROVED',
                'category': _getCatalogItem(offer['product_id'])['category'],
              },
            )
            .toList();
        notifications = [];
        backendStatusMessage = 'Connected to store offers';
        lastSuccessfulSyncAt = DateTime.now().toUtc();
        return;
      }
      // 1. Fetch dashboard summary
      try {
        final summary = await ApiService.getDashboardSummary();
        backendDashboardSummary = summary;
      } catch (e) {
        errors.add('Dashboard summary');
        debugPrint('[AppProvider] Dashboard summary fetch failed: $e');
      }

      // 2. Fetch inventory snapshots & map into active aisles
      try {
        final inv = await ApiService.getInventory(storeId: selectedStoreId);
        backendInventory = inv;
        if (inv.isNotEmpty) {
          aisles = inv.map((item) {
            final pId = item['product_id']?.toString() ?? 'PROD_001';
            final cat = _getCatalogItem(pId);
            final stock =
                (item['opening_inventory_units'] as num?)?.toInt() ?? 0;
            final days = (item['days_to_expiry'] as num?)?.toInt() ?? 3;

            String status = 'normal';
            if (stock == 0) {
              status = 'critical';
            } else if (days <= 2) {
              status = 'expiring';
            } else if (stock < 5) {
              status = 'low';
            }

            return {
              'id': 'SNAP-${item['snapshot_id']}',
              'productId': pId,
              'name': cat['name'],
              'label': cat['name'],
              'category': cat['category'],
              'icon': cat['emoji'],
              'price': cat['price'],
              'stock': stock,
              'maxStock': stock > 40 ? stock : 40,
              'daysToExpiry': days,
              'shelfLifeDays': item['standard_shelf_life_days'] ?? 6,
              'status': status,
              'snapshotSource':
                  item['snapshot_source'] ?? 'FastAPI SQLite Database',
              'storeId': item['store_id'] ?? selectedStoreId,
              'snapshotDate': item['snapshot_date'] ?? ApiService.demoDate,
            };
          }).toList();
        }
      } catch (e) {
        errors.add('Inventory');
        debugPrint('[AppProvider] Inventory fetch failed: $e');
      }

      // 3. Fetch recommendation actions & map into active discounts
      try {
        final recs = await ApiService.getRecommendations();
        backendRecommendations = recs;
        alerts = recs
            .where(
              (rec) =>
                  (rec['result']?['restock_quantity_units'] as num? ?? 0) > 0,
            )
            .map((rec) {
              final snapshot = rec['input_payload']['snapshot'];
              final quantity = rec['result']['restock_quantity_units'];
              return <String, dynamic>{
                'id': 'RESTOCK-${rec['recommendation_id']}',
                'recommendationId': rec['recommendation_id'].toString(),
                'productId': rec['product_id'],
                'aisleId': 'SNAP-${rec['snapshot_id']}',
                'type': 'warning',
                'title':
                    '${snapshot['product_name']} — replenish $quantity units',
                'message': 'Recommended order: $quantity units',
                'detail':
                    'ML baseline + ${rec['result']['policy_version']}. Stock source: ${rec['inventory_source']}',
                'time': rec['created_at'],
                'status': rec['approval_status'] == 'REJECTED'
                    ? 'resolved'
                    : 'open',
                'estimatedMinutes': 0,
                'actionRequired':
                    'Review the recommendation; receive actual delivery through Daily entry.',
              };
            })
            .toList();

        final recDiscounts = <Map<String, dynamic>>[];
        for (final rec in recs) {
          final actions = (rec['actions'] as List?) ?? [];
          final discountAction = actions.firstWhere(
            (a) => a['action'] == 'DISCOUNT',
            orElse: () => null,
          );
          if (discountAction != null) {
            final snapshot = rec['input_payload']?['snapshot'] ?? {};
            final pId = snapshot['product_id']?.toString() ?? 'PROD_001';
            final cat = _getCatalogItem(pId);
            final origPrice = (cat['price'] as num).toDouble();
            final discPercent =
                (discountAction['discount_percent'] as num?)?.toInt() ?? 20;
            final finalPrice =
                (rec['result']['selling_price_usd'] as num?)?.toDouble() ??
                origPrice * (100 - discPercent) / 100;
            final excess =
                (discountAction['potential_excess_units'] as num?)
                    ?.toDouble() ??
                4.0;
            final stock =
                ((rec['discount_units_now'] ??
                            rec['result']['discount_eligible_units'] ??
                            snapshot['opening_inventory_units'])
                        as num?)
                    ?.toInt() ??
                0;
            final days = (snapshot['days_to_expiry'] as num?)?.toInt() ?? 2;

            recDiscounts.add({
              'id':
                  '${ApiService.demoMode ? "DEMO-" : ""}REC-${rec['recommendation_id']}',
              'demoMode': ApiService.demoMode,
              'recommendationId': rec['recommendation_id'].toString(),
              'productId': pId,
              'productName': cat['name'],
              'category': cat['category'],
              'storeId': selectedStoreId,
              'name': cat['name'],
              'emoji': cat['emoji'],
              'aisleId': 'Snapshot #${rec['snapshot_id']}',
              'originalPrice': origPrice,
              'discountPercent': discPercent,
              'finalPrice': finalPrice,
              'stock': stock,
              'daysToExpiry': days,
              'saleAllowed': rec['sale_eligible_now'] == true,
              'expiryDate': rec['expiry_date'],
              'expiryFormatted':
                  'Valid through ${rec['expiry_date']} (Bangkok)',
              'status': rec['approval_status'] == 'APPROVED'
                  ? 'active'
                  : 'proposed',
              'approvalStatus': rec['approval_status'] ?? 'PROPOSED',
              'reasonCode':
                  discountAction['reason_code'] ?? 'NEAR_EXPIRY_EXCESS',
              'aiReasoning':
                  'Remaining shelf life: $days days; stock: $stock units. Projected surplus: $excess units. Policy ${rec['policy_version']} recommends $discPercent% markdown; business benefit is not established.',
              'isFromBackend': true,
            });
          }
        }
        if (recDiscounts.isNotEmpty) {
          discounts = recDiscounts;
        }
      } catch (e) {
        errors.add('Recommendations');
        debugPrint('[AppProvider] Recommendations fetch failed: $e');
      }

      // 4. Fetch customer deals
      try {
        final deals = await ApiService.getDeals();
        backendDeals = deals;
        notifications = await ApiService.getNotifications();
      } catch (e) {
        errors.add('Deals');
        debugPrint('[AppProvider] Deals fetch failed: $e');
      }

      backendStatusMessage = errors.isEmpty
          ? 'API connected • ML model • inventory source shown separately'
          : 'Partial sync failed: ${errors.join(', ')}';
      syncFailures = errors;
      if (errors.isEmpty) lastSuccessfulSyncAt = DateTime.now().toUtc();
    } catch (e) {
      lastBackendError = e.toString();
      syncFailures = ['Data refresh'];
      debugPrint('[AppProvider] Sync error: $e');
    } finally {
      isSyncingBackend = false;
      notifyListeners();
    }
  }

  static final Map<String, Map<String, dynamic>> _productCatalog = {
    for (final product in trainingProducts) product['id'] as String: product,
  };

  Map<String, dynamic> _getCatalogItem(String productId) {
    if (_productCatalog.containsKey(productId)) {
      return _productCatalog[productId]!;
    }
    return {
      'name': 'Retail Product $productId',
      'emoji': 'ðŸ“¦',
      'category': 'Fresh Grocery',
      'price': 65.0,
    };
  }

  /// Send Recommendation Run to backend (e.g. rain-demo or clear-demo)
  Future<bool> triggerBackendScenario(String scenarioId) async {
    if (!isBackendOnline) return false;

    isSyncingBackend = true;
    notifyListeners();

    try {
      await ApiService.createRecommendationRun(scenarioId: scenarioId);
      await syncWithBackend();
      return true;
    } catch (e) {
      lastBackendError = e.toString();
      debugPrint('[AppProvider] Trigger scenario failed: $e');
      return false;
    } finally {
      isSyncingBackend = false;
      notifyListeners();
    }
  }

  /// Approve recommendation in backend
  Future<bool> approveRecommendation(
    String recId, {
    bool acknowledgeBelowCost = false,
  }) async {
    if (isBackendOnline) {
      final ok = await ApiService.updateRecommendationStatus(
        recommendationId: recId,
        status: 'APPROVED',
        acknowledgeBelowCost: acknowledgeBelowCost,
      );
      if (ok) {
        await syncWithBackend();
        return true;
      }
    }
    // Never report a failed backend write as successful.
    return false;
  }

  /// Reject recommendation in backend
  Future<bool> rejectRecommendation(String recId) async {
    if (isBackendOnline) {
      final ok = await ApiService.updateRecommendationStatus(
        recommendationId: recId,
        status: 'REJECTED',
      );
      if (ok) {
        await syncWithBackend();
        return true;
      }
    }
    // Never report a failed backend write as successful.
    return false;
  }
}
