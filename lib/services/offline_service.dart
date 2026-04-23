import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'supabase_service.dart';
import 'auth_service.dart';

class OfflineService {
  static final OfflineService instance = OfflineService._internal();
  OfflineService._internal();

  late Box _orderBox;
  late Box _operationBox; // Generic queue for ALL offline operations
  final ValueNotifier<int> syncStatus = ValueNotifier<int>(0); // 0:Idle, 1:Syncing, 2:Success, 3:Error
  // Exposed for the global sync banner so UI can react without polling.
  final ValueNotifier<int> pendingCountNotifier = ValueNotifier<int>(0);

  Timer? _cacheRefreshTimer;
  Timer? _syncDebounce;
  Timer? _endOfDayTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  DateTime? _lastEndOfDayAlert;

  Future<void> init() async {
    _orderBox = await Hive.openBox('offline_orders');
    _operationBox = await Hive.openBox('offline_operations');
    _refreshPendingCount();
  }

  void _refreshPendingCount() {
    pendingCountNotifier.value = _orderBox.length + _operationBox.length;
  }

  /// Exposed for the banner's Retry button. Same as syncAll but refreshes
  /// the pending-count notifier on completion so the banner updates.
  Future<void> forceSyncNow() async {
    await syncAll();
    _refreshPendingCount();
  }

  /// Starts connectivity monitoring for offline sync AND
  /// sets up a 1-hour cache auto-refresh timer.
  void startMonitoring() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      if (results.isNotEmpty && !results.contains(ConnectivityResult.none)) {
        _syncDebounce?.cancel();
        _syncDebounce = Timer(const Duration(seconds: 2), () {
          syncAll();
        });
      }
    });

    _cacheRefreshTimer?.cancel();
    _cacheRefreshTimer = Timer.periodic(const Duration(hours: 1), (_) async {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) return;

      // Hourly: also retry any pending sync work so queued orders don't rot
      // silently between connectivity blips.
      if (pendingCountNotifier.value > 0) {
        debugPrint('[OfflineService] Hourly auto-resync firing for ${pendingCountNotifier.value} pending');
        await syncAll();
      }

      debugPrint('[OfflineService] Auto-refreshing cache');
      try {
        await SupabaseService.instance.getProducts(forceRefresh: true);
        await SupabaseService.instance.getCustomers(forceRefresh: true);
        await SupabaseService.instance.getProductCategories(forceRefresh: true);
        await SupabaseService.instance.getRecentOrders(forceRefresh: true);
        await SupabaseService.instance.getSalesAnalytics();
      } catch (e) {
        debugPrint('[OfflineService] Cache refresh error: $e');
      }
    });

    // Daily end-of-day check: every 10 min, if local hour >= 21 (9 PM) and
    // work is still pending, fire one last syncAll and then log an admin
    // alert if the queue is still non-empty. Use a _lastEndOfDayAlert guard
    // so we only alert once per day even though the check runs every 10 min.
    _endOfDayTimer?.cancel();
    _endOfDayTimer = Timer.periodic(const Duration(minutes: 10), (_) async {
      final now = DateTime.now();
      if (now.hour < 21) return;
      if (pendingCountNotifier.value == 0) return;
      // Dedup: one alert per calendar day
      if (_lastEndOfDayAlert != null &&
          _lastEndOfDayAlert!.year == now.year &&
          _lastEndOfDayAlert!.month == now.month &&
          _lastEndOfDayAlert!.day == now.day) {
        return;
      }
      debugPrint('[OfflineService] End-of-day sync check — ${pendingCountNotifier.value} still pending');
      await syncAll();
      if (pendingCountNotifier.value > 0) {
        try {
          await SupabaseService.instance.client.from('app_error_logs').insert({
            'error_type': 'sync_unfinished_eod',
            'error_message':
                '${pendingCountNotifier.value} offline operation(s) still unsynced at end of day on ${now.toIso8601String()}',
            'resolved': false,
            'team_id': AuthService.currentTeam,
          });
          _lastEndOfDayAlert = now;
        } catch (e) {
          debugPrint('[OfflineService] Failed to push EoD admin alert: $e');
        }
      } else {
        _lastEndOfDayAlert = now; // avoid re-checking today
      }
    });
  }

  void stopMonitoring() {
    _cacheRefreshTimer?.cancel();
    _cacheRefreshTimer = null;
    _syncDebounce?.cancel();
    _syncDebounce = null;
    _endOfDayTimer?.cancel();
    _endOfDayTimer = null;
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  // ─── CHECK CONNECTIVITY ──────────────────────────────────────

  Future<bool> isOnline() async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  // ─── GENERIC OFFLINE OPERATION QUEUE ─────────────────────────

  /// Queue any operation for offline execution.
  /// [type]: 'order', 'collection', 'delivery_status', 'bill_upload', etc.
  /// [data]: operation-specific payload.
  Future<void> queueOperation(String type, Map<String, dynamic> data) async {
    // Dedup on content, not just order_id — otherwise editing an order offline
    // is silently dropped because it shares the order_id with the original.
    // Two queued ops with the same type + same order_id are only duplicates
    // when the payload JSON is byte-identical.
    final newFingerprint = jsonEncode(data);
    final existingOps = _operationBox.values.toList();
    final isDuplicate = existingOps.any((op) {
      final existingType = (op as Map)['type'];
      final existingData = op['data'];
      if (existingType != type) return false;
      try {
        return jsonEncode(existingData) == newFingerprint;
      } catch (_) {
        return false;
      }
    });
    if (isDuplicate) {
      debugPrint('\u26a0\ufe0f OfflineService: Skipping identical $type for order ${data['order_id']}');
      return;
    }

    await _operationBox.add({
      'type': type,
      'data': data,
      'queued_at': DateTime.now().toIso8601String(),
      'team_id': AuthService.currentTeam,
    });
    _refreshPendingCount();
    debugPrint('[OfflineService] Queued $type operation');
    // Try to sync immediately
    syncAll();
  }

  // ─── ORDER-SPECIFIC (backward compat) ────────────────────────

  Future<void> saveOrderOffline(
    Map<String, dynamic> orderData,
    List<Map<String, dynamic>> orderItems,
  ) async {
    // Stamp the active team on the envelope so replay after a team-switch
    // can skip (not misattribute) orders queued under the other team.
    await _orderBox.add({
      'order': orderData,
      'items': orderItems,
      'team_id': AuthService.currentTeam,
    });
    _refreshPendingCount();
    syncAll();
  }

  // ─── SYNC ALL ────────────────────────────────────────────────

  Future<void> syncAll() async {
    if (syncStatus.value == 1) return;
    _refreshPendingCount();
    if (!await isOnline()) return;

    syncStatus.value = 1;
    int synced = 0;
    int failed = 0;

    // 1. Sync legacy orders
    await _syncOrders().then((r) { synced += r.$1; failed += r.$2; });

    // 2. Sync generic operations
    await _syncOperations().then((r) { synced += r.$1; failed += r.$2; });

    _refreshPendingCount();

    if (failed > 0 && synced == 0) {
      syncStatus.value = 3;
    } else {
      syncStatus.value = 2;
    }
    if (synced > 0 || failed > 0) {
      debugPrint('[OfflineService] Sync done: $synced synced, $failed failed');
    }
    Future.delayed(const Duration(seconds: 3), () {
      if (syncStatus.value == 2 || syncStatus.value == 3) syncStatus.value = 0;
    });
  }

  // Backward compat: sync orders from _orderBox
  Future<(int, int)> _syncOrders() async {
    if (_orderBox.isEmpty) return (0, 0);
    int synced = 0, failed = 0;

    final keys = _orderBox.keys.toList();
    for (var key in keys) {
      try {
        final entry = _orderBox.get(key);
        if (entry == null) continue;

        final Map<String, dynamic> orderData;
        final List<Map<String, dynamic>> itemsList;
        String? stampedTeam;
        if (entry is Map && entry.containsKey('order') && entry['order'] is Map) {
          orderData = Map<String, dynamic>.from(entry['order'] as Map);
          final rawItems = entry['items'];
          itemsList = (rawItems is List) ? rawItems.map((i) => i is Map ? Map<String, dynamic>.from(i) : <String, dynamic>{}).toList() : [];
          stampedTeam = entry['team_id'] as String?;
        } else if (entry is Map) {
          orderData = Map<String, dynamic>.from(entry);
          itemsList = [];
        } else {
          await _orderBox.delete(key);
          continue;
        }

        // Cross-team guard: if this order was queued under a different team,
        // defer syncing until the user switches back. Don't delete, don't misattribute.
        if (stampedTeam != null && stampedTeam != AuthService.currentTeam) {
          debugPrint('[OfflineService] Skipping order queued for team $stampedTeam (current: ${AuthService.currentTeam})');
          continue;
        }

        final orderId = orderData['id'] as String?;
        final customerName = orderData['customer_name'] as String?;
        final deliveryDateStr = orderData['delivery_date'] as String?;
        if (orderId == null || customerName == null || deliveryDateStr == null) {
          await _orderBox.delete(key);
          failed++;
          continue;
        }

        DateTime deliveryDate;
        try { deliveryDate = DateTime.parse(deliveryDateStr); } catch (_) { await _orderBox.delete(key); failed++; continue; }

        await SupabaseService.instance.createOrder(
          orderId: orderId,
          customerId: orderData['customer_id'] as String?,
          customerName: customerName,
          beat: orderData['beat_name'] as String? ?? '',
          deliveryDate: deliveryDate,
          subtotal: (orderData['subtotal'] as num).toDouble(),
          vat: (orderData['vat'] as num).toDouble(),
          grandTotal: (orderData['grand_total'] as num).toDouble(),
          itemCount: orderData['item_count'] as int? ?? itemsList.length,
          totalUnits: orderData['total_units'] as int? ?? 0,
          notes: orderData['notes'] as String? ?? '',
          items: itemsList,
        );
        await _orderBox.delete(key);
        synced++;
      } catch (e) {
        failed++;
        debugPrint('[OfflineService] Order sync failed for key $key: $e');
      }
    }
    return (synced, failed);
  }

  // Sync generic operations from _operationBox
  Future<(int, int)> _syncOperations() async {
    if (_operationBox.isEmpty) return (0, 0);
    int synced = 0, failed = 0;

    final keys = _operationBox.keys.toList();
    for (var key in keys) {
      try {
        final entry = _operationBox.get(key);
        if (entry == null || entry is! Map) { await _operationBox.delete(key); continue; }

        final type = entry['type'] as String? ?? '';
        final data = Map<String, dynamic>.from(entry['data'] as Map);
        final stampedTeam = entry['team_id'] as String?;

        // Cross-team guard: ops are stamped at queue-time (see queueOperation).
        // If the active team has changed since then, defer this op — don't
        // replay it against the wrong team.
        if (stampedTeam != null && stampedTeam != AuthService.currentTeam) {
          debugPrint('[OfflineService] Skipping $type queued for team $stampedTeam (current: ${AuthService.currentTeam})');
          continue;
        }

        switch (type) {
          case 'order':
            await _syncOrderOperation(data);
            break;
          case 'collection':
            await _syncCollection(data);
            break;
          case 'delivery_status':
            await _syncDeliveryStatus(data);
            break;
          case 'bill_upload':
            await _syncBillUpload(data);
            break;
          case 'visit_log':
            await _syncVisitLog(data);
            break;
          default:
            debugPrint('[OfflineService] Unknown operation type: $type');
        }

        await _operationBox.delete(key);
        synced++;
      } catch (e) {
        failed++;
        debugPrint('[OfflineService] Operation sync failed for key $key: $e');
      }
    }
    return (synced, failed);
  }

  // ─── OPERATION HANDLERS ──────────────────────────────────────

  Future<void> _syncOrderOperation(Map<String, dynamic> data) async {
    final rawItems = data['items'];
    final items = (rawItems is List)
        ? rawItems.map((i) => i is Map ? Map<String, dynamic>.from(i) : <String, dynamic>{}).toList()
        : <Map<String, dynamic>>[];

    await SupabaseService.instance.createOrder(
      orderId: data['order_id'] as String,
      customerId: data['customer_id'] as String?,
      customerName: data['customer_name'] as String,
      beat: data['beat'] as String? ?? '',
      deliveryDate: DateTime.parse(data['delivery_date'] as String),
      subtotal: (data['subtotal'] as num).toDouble(),
      vat: (data['vat'] as num).toDouble(),
      grandTotal: (data['grand_total'] as num).toDouble(),
      itemCount: data['item_count'] as int? ?? items.length,
      totalUnits: data['total_units'] as int? ?? 0,
      notes: data['notes'] as String? ?? '',
      items: items,
      isOutOfBeat: data['is_out_of_beat'] as bool? ?? false,
    );
  }

  Future<void> _syncCollection(Map<String, dynamic> data) async {
    await SupabaseService.instance.createCollection(
      customerId: data['customer_id'] as String,
      customerName: data['customer_name'] as String,
      amountCollected: (data['amount_collected'] as num).toDouble(),
      outstandingBefore: (data['outstanding_before'] as num).toDouble(),
      paymentMode: data['payment_mode'] as String? ?? 'Cash',
      billNo: data['bill_no'] as String?,
      notes: data['notes'] as String? ?? '',
      chequeNumber: data['cheque_number'] as String?,
      upiTransactionId: data['upi_transaction_id'] as String?,
    );
  }

  Future<void> _syncDeliveryStatus(Map<String, dynamic> data) async {
    await SupabaseService.instance.updateOrderStatus(
      data['order_id'] as String,
      data['new_status'] as String,
      isSuperAdmin: data['is_super_admin'] as bool? ?? true,
    );
  }

  Future<void> _syncBillUpload(Map<String, dynamic> data) async {
    // Bill photo bytes stored as base64 in Hive
    final base64Bytes = data['image_base64'] as String?;
    if (base64Bytes == null) return;
    final bytes = base64Decode(base64Bytes);
    await SupabaseService.instance.uploadBillPhoto(bytes.toList(), data['order_id'] as String, fileName: data['file_name'] as String?);
  }

  Future<void> _syncVisitLog(Map<String, dynamic> data) async {
    await SupabaseService.instance.logVisit(
      customerId: data['customer_id'] as String,
      beatId: data['beat_id'] as String,
      reason: data['visit_purpose'] as String? ?? data['reason'] as String? ?? 'sales_call',
      notes: data['notes'] as String? ?? '',
      isOutOfBeat: data['is_out_of_beat'] as bool? ?? false,
    );
  }

  // ─── PENDING COUNT ───────────────────────────────────────────

  int get pendingCount => _orderBox.length + _operationBox.length;

  // ─── GENERIC CACHE HELPERS ───────────────────────────────────

  Future<String?> getCached(String boxName, String key) async {
    final box = Hive.isBoxOpen(boxName) ? Hive.box(boxName) : await Hive.openBox(boxName);
    return box.get(key) as String?;
  }

  Future<void> setCached(String boxName, String key, dynamic data) async {
    final box = Hive.isBoxOpen(boxName) ? Hive.box(boxName) : await Hive.openBox(boxName);
    await box.put(key, jsonEncode(data));
    await box.put('${key}_ts', DateTime.now().millisecondsSinceEpoch);
  }

  bool isCacheStale(String boxName, String key, {int minutesOld = 30}) {
    if (!Hive.isBoxOpen(boxName)) return true;
    final tsMs = Hive.box(boxName).get('${key}_ts') as int?;
    if (tsMs == null) return true;
    return DateTime.now().millisecondsSinceEpoch - tsMs > minutesOld * 60 * 1000;
  }

  Map<String, dynamic> getCacheInfo() {
    final info = <String, dynamic>{};
    for (final teamId in ['JA', 'MA']) {
      final boxName = 'cache_$teamId';
      if (Hive.isBoxOpen(boxName)) {
        final box = Hive.box(boxName);
        final keys = box.keys.where((k) => !(k as String).endsWith('_ts')).toList();
        info[teamId] = {'keys': keys.length, 'entries': keys};
      } else {
        info[teamId] = {'status': 'not_open'};
      }
    }
    info['pending_orders'] = _orderBox.length;
    info['pending_operations'] = _operationBox.length;
    return info;
  }
}
