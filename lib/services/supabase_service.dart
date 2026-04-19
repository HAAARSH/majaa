import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_service.dart';
import 'google_drive_auth_service.dart';
import 'gemini_ocr_service.dart';
import '../models/models.dart';
export '../models/models.dart';

// ─── MODELS (canonical definitions now in lib/models/) ──────────────
// Existing code that imports supabase_service.dart still sees all model
// classes via the `import '../models/models.dart'` above.

/// One bill's share of a settle event — see [SupabaseService.settleOrderBills].
class BillAllocation {
  final String billNo;
  final String? orderId;
  final double amount;
  final double orderOutstanding;

  const BillAllocation({
    required this.billNo,
    this.orderId,
    required this.amount,
    required this.orderOutstanding,
  });
}

// ─── CORE SERVICE ────────────────────────────────────────────────────────

/// Sentinel marker distinguishing "teamId omitted" (use currentTeam) from
/// "teamId passed as null" (all teams, no filter). Needed because nullable
/// String params can't tell omission from explicit null.
const Object _kTeamIdDefault = Object();

class SupabaseService {
  static SupabaseService? _instance;
  static SupabaseService get instance => _instance ??= SupabaseService._();
  SupabaseService._();

  String? currentUserId;
  String? currentUserName;
  String? currentUserRole;

  bool get isAdmin => currentUserRole == 'admin' || currentUserRole == 'super_admin';
  bool isOfflineMode = false;
  String? _resolvedAppUserId; // cached resolved app_users.id
  void clearResolvedUserId() => _resolvedAppUserId = null;

  /// Resolves auth UID to app_users.id (they may differ for early users)
  Future<String> _resolveAppUserId(String authUid) async {
    if (_resolvedAppUserId != null) return _resolvedAppUserId!;
    try {
      // First try direct match
      final direct = await client.from('app_users').select('id').eq('id', authUid).maybeSingle();
      if (direct != null) {
        _resolvedAppUserId = authUid;
        return authUid;
      }
      // Fall back to email match
      final email = client.auth.currentUser?.email;
      if (email != null) {
        final byEmail = await client.from('app_users').select('id').eq('email', email).maybeSingle();
        if (byEmail == null) return authUid;
        _resolvedAppUserId = byEmail['id'] as String;
        return _resolvedAppUserId!;
      }
    } catch (e) {
      debugPrint('[_resolveAppUserId] error: $e');
    }
    return authUid; // fallback to auth UID
  }
  static bool _initialized = false;
  SupabaseClient get client => Supabase.instance.client;

  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      // 1. Physically load and read the env.json file
      final envString = await rootBundle.loadString('env.json');
      final Map<String, dynamic> envData = jsonDecode(envString);

      final url = envData['SUPABASE_URL'] ?? '';
      final key = envData['SUPABASE_ANON_KEY'] ?? '';

      if (url.isNotEmpty && key.isNotEmpty) {
        await Supabase.initialize(url: url, anonKey: key, debug: kDebugMode);
        _initialized = true;
        debugPrint("✅ Supabase Initialized Successfully from env.json");
      } else {
        debugPrint("🚨 Supabase keys are empty inside env.json!");
      }
    } catch (e) {
      debugPrint("🚨 Failed to load env.json: $e");

      // Fallback just in case you use terminal commands later
      const fallbackUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
      const fallbackKey = String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');
      if (fallbackUrl.isNotEmpty && fallbackKey.isNotEmpty) {
        await Supabase.initialize(url: fallbackUrl, anonKey: fallbackKey, debug: kDebugMode);
        _initialized = true;
      }
    }
  }

  // ─── THE OFFICE BRIDGE (EXCEL RECONCILIATION) ───

  /// Takes a list of rows from your Office Excel export and updates the app.
  /// Expects a list of maps with keys: 'order_id', 'final_bill_no', 'billed_amount'
  /// Returns a map with keys 'updated' (int) and 'failed' (List of maps).
  Future<Map<String, dynamic>> syncOfficeBilling(List<Map<String, dynamic>> officeData) async {
    int updatedCount = 0;
    final List<Map<String, dynamic>> failed = [];

    for (var row in officeData) {
      final String orderId = row['order_id'].toString();
      final String finalBill = row['final_bill_no'].toString();
      final double billedAmount = double.tryParse(row['billed_amount'].toString()) ?? 0.0;

      try {
        await client.from('orders').update({
          'final_bill_no': finalBill,
          'actual_billed_amount': billedAmount,
          'status': 'Invoiced',
        }).eq('id', orderId).eq('team_id', AuthService.currentTeam);

        updatedCount++;
      } catch (e) {
        debugPrint('🚨 Failed to sync order $orderId: $e');
        failed.add({'order_id': orderId, 'reason': e.toString()});
      }
    }
    return {'updated': updatedCount, 'failed': failed};
  }

  // Blueprint: High-Speed Hive Cache (cache-first, 30-min TTL, optional background refresh)
  Future<List<dynamic>> _fetchWithCache(
      String key,
      Future<List<dynamic>> Function() networkFetch, {
        void Function(List<dynamic>)? onRefreshed,
        bool forceRefresh = false,
        int ttlMinutes = 30,
      }) async {
    final teamKey = '${key}_${AuthService.currentTeam}';
    final tsKey = '${teamKey}_ts';
    final box = Hive.isBoxOpen('cache_${AuthService.currentTeam}')
        ? Hive.box('cache_${AuthService.currentTeam}')
        : await Hive.openBox('cache_${AuthService.currentTeam}');

    final cachedStr = box.get(teamKey) as String?;
    final tsMs = box.get(tsKey) as int?;
    final isFresh = !forceRefresh &&
        cachedStr != null &&
        tsMs != null &&
        DateTime.now().millisecondsSinceEpoch - tsMs < ttlMinutes * 60 * 1000;

    if (isFresh) {
      final cached = jsonDecode(cachedStr) as List<dynamic>;
      if (onRefreshed != null) {
        networkFetch().then((data) async {
          await box.put(teamKey, jsonEncode(data));
          await box.put(tsKey, DateTime.now().millisecondsSinceEpoch);
          onRefreshed(data);
        }).catchError((_) {});
      }
      return cached;
    }

    try {
      final data = await networkFetch();
      await box.put(teamKey, jsonEncode(data));
      await box.put(tsKey, DateTime.now().millisecondsSinceEpoch);
      return data;
    } catch (e) {
      if (cachedStr != null) return jsonDecode(cachedStr) as List<dynamic>;
      rethrow;
    }
  }

  /// Invalidates a cached key for the current team, forcing fresh fetch next time.
  /// Invalidates a cached key for the current team, forcing fresh fetch next time.
  Future<void> invalidateCache(String key) async {
    final teamKey = '${key}_${AuthService.currentTeam}';
    final tsKey = '${teamKey}_ts';
    final boxName = 'cache_${AuthService.currentTeam}';
    if (Hive.isBoxOpen(boxName)) {
      final box = Hive.box(boxName);
      await box.delete(teamKey);
      await box.delete(tsKey);
    }
  }

  /// Full data refresh for sales/delivery reps.
  /// Clears all local cached data. On re-fetch, only last 60 days of
  /// orders/collections are loaded from Supabase (older data stays in DB
  /// but is not sent to the phone).
  /// Hero images (avatars) are retained — they're small thumbnails.
  Future<void> fullRefreshForSalesRep() async {
    // Clear all cache boxes except hero images
    for (final boxName in [
      'cache_JA', 'cache_MA', 'cart', 'orders',
      'offline_orders', 'offline_operations',
    ]) {
      try {
        if (Hive.isBoxOpen(boxName)) {
          await Hive.box(boxName).clear();
        } else {
          final box = await Hive.openBox(boxName);
          await box.clear();
        }
      } catch (_) {}
    }
    // Hero images retained — small avatar thumbnails, no age tracking needed
  }

  // ─── DATA FETCHING (Filtered by Team) ───

  Future<List<ProductModel>> getProducts({bool forceRefresh = false, String? teamId}) async {
    final effectiveTeam = teamId ?? AuthService.currentTeam;
    final response = await _fetchWithCache('products_$effectiveTeam', () async {
      // Supabase PostgREST caps at 1000 rows per request — paginate to get all
      final all = <dynamic>[];
      const batchSize = 1000;
      int offset = 0;
      while (true) {
        final batch = await client.from('products').select()
            .eq('team_id', effectiveTeam)
            .order('name')
            .range(offset, offset + batchSize - 1);
        all.addAll(batch);
        if (batch.length < batchSize) break;
        offset += batchSize;
      }
      return all;
    }, forceRefresh: forceRefresh);
    return response.map((e) => ProductModel.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  /// When [teamId] is explicitly passed, that team is used (or null = all
  /// teams, no filter). When the named param is omitted, falls back to
  /// currentTeam — preserves prior behavior for non-admin callers.
  Future<List<BeatModel>> getBeats({
    bool forceRefresh = false,
    Object? teamId = _kTeamIdDefault,
  }) async {
    final String? effectiveTeam = identical(teamId, _kTeamIdDefault)
        ? AuthService.currentTeam
        : teamId as String?;
    final cacheKey = effectiveTeam == null ? 'beats_all' : 'beats_$effectiveTeam';
    final response = await _fetchWithCache(cacheKey, () async {
      var q = client.from('beats').select();
      if (effectiveTeam != null) q = q.eq('team_id', effectiveTeam);
      return await q.order('beat_name').limit(1000);
    }, forceRefresh: forceRefresh);
    return response.map((e) => BeatModel.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  Future<List<BeatModel>> getBeatsForTeam(String teamId) async {
    final response = await _fetchWithCache('beats_$teamId', () async {
      return await client.from('beats').select().eq('team_id', teamId).order('beat_name').limit(200);
    });
    return response.map((e) => BeatModel.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  Future<List<CustomerModel>> getCustomers({bool forceRefresh = false}) async {
    final response = await _fetchWithCache('customers', () async {
      // Supabase PostgREST caps at 1000 rows per request — paginate to get all
      final all = <dynamic>[];
      const batchSize = 1000;
      int offset = 0;
      while (true) {
        final batch = await client
            .from('customers')
            .select('*, customer_team_profiles(id, customer_id, team_ja, team_ma, beat_id_ja, beat_name_ja, outstanding_ja, beat_id_ma, beat_name_ma, outstanding_ma, order_beat_id_ja, order_beat_name_ja, order_beat_id_ma, order_beat_name_ma)') // CHANGED: unified profile columns
            .order('name')
            .range(offset, offset + batchSize - 1);
        all.addAll(batch);
        if (batch.length < batchSize) break;
        offset += batchSize;
      }
      return all;
    }, forceRefresh: forceRefresh);
    return response.map((e) => CustomerModel.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  Future<CustomerModel?> getCustomerById(String id) async {
    try {
      final resp = await client.from('customers')
          .select('*, customer_team_profiles(id, customer_id, team_ja, team_ma, beat_id_ja, beat_name_ja, outstanding_ja, beat_id_ma, beat_name_ma, outstanding_ma, order_beat_id_ja, order_beat_name_ja, order_beat_id_ma, order_beat_name_ma)')
          .eq('id', id)
          .maybeSingle();
      if (resp == null) return null;
      return CustomerModel.fromJson(Map<String, dynamic>.from(resp));
    } catch (e) {
      debugPrint('getCustomerById error: $e');
      return null;
    }
  }

  Future<BeatModel?> getBeatById(String id) async {
    try {
      final resp = await client.from('beats').select().eq('id', id).eq('team_id', AuthService.currentTeam).maybeSingle();
      if (resp == null) return null;
      return BeatModel.fromJson(Map<String, dynamic>.from(resp));
    } catch (e) {
      debugPrint('getBeatById error: $e');
      return null;
    }
  }

  Future<ProductModel?> getProductById(String id) async {
    try {
      final resp = await client.from('products').select().eq('id', id).eq('team_id', AuthService.currentTeam).maybeSingle();
      if (resp == null) return null;
      return ProductModel.fromJson(Map<String, dynamic>.from(resp));
    } catch (e) {
      debugPrint('getProductById error: $e');
      return null;
    }
  }

  /// Returns categories from the product_categories table, ordered by sort_order.
  /// Cache-first (24 h TTL). Pass forceRefresh: true to bypass cache.
  Future<List<ProductCategoryModel>> getProductCategories({bool forceRefresh = false}) async {
    final teamKey = 'categories_${AuthService.currentTeam}';
    final tsKey = '${teamKey}_ts';
    final box = Hive.isBoxOpen('cache_${AuthService.currentTeam}')
        ? Hive.box('cache_${AuthService.currentTeam}')
        : await Hive.openBox('cache_${AuthService.currentTeam}');

    final cachedStr = box.get(teamKey) as String?;
    final tsMs = box.get(tsKey) as int?;
    final isStale = tsMs == null ||
        DateTime.now().millisecondsSinceEpoch - tsMs > 24 * 60 * 60 * 1000;

    Future<List<ProductCategoryModel>> doFetch() async {
      final data = await client
          .from('product_categories')
          .select()
          .eq('team_id', AuthService.currentTeam)
          .order('sort_order');
      await box.put(teamKey, jsonEncode(data));
      await box.put(tsKey, DateTime.now().millisecondsSinceEpoch);
      return (data as List)
          .map((e) => ProductCategoryModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }

    // Force refresh: skip cache entirely
    if (forceRefresh) return doFetch();

    // Stale: background refresh if we have a cache; sync fetch if we don't
    if (isStale) {
      if (cachedStr != null) {
        Future(() async { try { await doFetch(); } catch (_) {} });
      } else {
        return doFetch();
      }
    }

    // Return cache if available
    if (cachedStr != null) {
      return (jsonDecode(cachedStr) as List)
          .map((e) => ProductCategoryModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }

    return doFetch();
  }

  /// Fetches products for a single category, cached per category per team (30-min TTL).
  Future<List<ProductModel>> getProductsByCategory(String categoryId, {bool forceRefresh = false, String? teamId}) async {
    final team = teamId ?? AuthService.currentTeam;
    final response = await _fetchWithCache(
      'products_cat_${categoryId}_$team',
          () async {
        return await client
            .from('products')
            .select()
            .eq('category', categoryId)
            .eq('team_id', team)
            .order('name');
      },
      forceRefresh: forceRefresh,
    );
    return response
        .map((e) => ProductModel.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Full-text product search — always fresh, paginated (50 per page).
  ///
  /// When [allowedBrands] is non-empty the query is scoped to those categories
  /// **across all teams** (matching the category-chip browse behavior for
  /// brand_reps who have cross-team access). Otherwise it falls back to the
  /// current team's products — the original behavior for sales_rep.
  Future<List<ProductModel>> searchProducts(
    String query, {
    int page = 0,
    List<String>? allowedBrands,
  }) async {
    try {
      final tokens = query
          .trim()
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList();
      if (tokens.isEmpty) return [];

      var req = client.from('products').select();
      if (allowedBrands != null && allowedBrands.isNotEmpty) {
        req = req.inFilter('category', allowedBrands);
      } else {
        req = req.eq('team_id', AuthService.currentTeam);
      }
      for (final token in tokens) {
        req = req.ilike('name', '%$token%');
      }
      final response =
          await req.range(page * 50, (page + 1) * 50 - 1);
      return (response as List)
          .map((e) => ProductModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// Customer order history — cached per customer (60-min TTL) for offline browsing.
  Future<List<OrderModel>> getCustomerOrders(String customerId, {bool forceRefresh = false, int limit = 50, int offset = 0}) async {
    final response = await _fetchWithCache(
      'customer_orders_$customerId',
      () async => await client
          .from('orders')
          .select('*, order_items(*)')
          .eq('customer_id', customerId)
          .eq('team_id', AuthService.currentTeam)
          .order('order_date', ascending: false)
          .range(offset, offset + limit - 1),
      forceRefresh: forceRefresh,
      ttlMinutes: 60,
    );
    return response.map((e) => OrderModel.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  /// Recent orders for this team — cached for 15 min.
  /// Admin/super_admin: all orders. Sales/delivery rep: last 60 days only.
  Future<List<OrderModel>> getRecentOrders({bool forceRefresh = false}) async {
    final response = await _fetchWithCache(
      'recent_orders',
      () async {
        var query = client
            .from('orders')
            .select('*, order_items(*)')
            .eq('team_id', AuthService.currentTeam);
        // Admins get all data, reps get last 60 days
        if (!isAdmin) {
          final since = DateTime.now().subtract(const Duration(days: 60)).toIso8601String();
          query = query.gte('order_date', since);
        }
        return await query.order('order_date', ascending: false).limit(isAdmin ? 2000 : 1000);
      },
      forceRefresh: forceRefresh,
      ttlMinutes: 15,
    );
    return response.map((e) => OrderModel.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  Future<Map<String, dynamic>> getSalesAnalytics({
    bool myOnly = false,
    List<String>? allowedBrands,
    Object? teamId = _kTeamIdDefault,
  }) async {
    try {
      final String? effectiveTeam = identical(teamId, _kTeamIdDefault)
          ? AuthService.currentTeam
          : teamId as String?;
      final now = DateTime.now();
      final startOfMonth = DateTime(now.year, now.month, 1).toIso8601String();
      final endOfMonth = DateTime(now.year, now.month + 1, 0, 23, 59, 59).toIso8601String();
      final userId = client.auth.currentUser?.id;
      final bool brandScoped = allowedBrands != null && allowedBrands.isNotEmpty;

      // Cache key must distinguish brand scope + team scope so different
      // admin views don't share a cached payload.
      final brandKey = brandScoped
          ? 'b_${(List<String>.from(allowedBrands)..sort()).join("|").hashCode}'
          : 'all';
      final teamKey = effectiveTeam ?? 'ALL';
      final cacheKey = '${myOnly ? "analytics_my" : "analytics"}_${brandKey}_$teamKey';
      final response = await _fetchWithCache(cacheKey, () async {
        // Brand scope needs line items to compute per-brand totals.
        var q = client.from('orders')
            .select(brandScoped
                ? 'grand_total, beat_name, order_items(product_id, line_total, total_price)'
                : 'grand_total, beat_name')
            .gte('order_date', startOfMonth)
            .lte('order_date', endOfMonth);
        if (effectiveTeam != null) q = q.eq('team_id', effectiveTeam);
        if (myOnly && userId != null) q = q.eq('user_id', userId);
        return await q;
      });

      // For brand scope, build a product_id → category map once and
      // recompute each order's effective total from allowed-brand items.
      Map<String, String> categoryMap = {};
      if (brandScoped) {
        final productIds = (response as List)
            .expand((o) => ((o as Map)['order_items'] as List?) ?? [])
            .map((it) => (it as Map)['product_id'])
            .whereType<String>()
            .toSet()
            .toList();
        if (productIds.isNotEmpty) {
          final rows = await client.from('products')
              .select('id, category')
              .inFilter('id', productIds);
          for (final r in rows as List) {
            final id = (r as Map)['id'] as String?;
            final cat = r['category'] as String?;
            if (id != null && cat != null) categoryMap[id] = cat;
          }
        }
      }

      double totalSales = 0; Map<String, double> salesByBeat = {}; int totalOrders = 0;
      for (var order in response) {
        final String beat = (order as Map)['beat_name']?.toString() ?? 'Unknown';
        double amount;
        if (brandScoped) {
          final items = (order['order_items'] as List?) ?? [];
          double scopedTotal = 0;
          bool hasAllowed = false;
          for (final it in items) {
            final pid = (it as Map)['product_id'] as String?;
            final cat = pid != null ? categoryMap[pid] : null;
            if (cat != null && allowedBrands.contains(cat)) {
              hasAllowed = true;
              scopedTotal += ((it['line_total'] ?? it['total_price']) as num?)?.toDouble() ?? 0.0;
            }
          }
          if (!hasAllowed) continue;
          amount = scopedTotal;
        } else {
          amount = (order['grand_total'] as num?)?.toDouble() ?? 0.0;
        }
        totalOrders += 1;
        totalSales += amount;
        salesByBeat[beat] = (salesByBeat[beat] ?? 0) + amount;
      }
      return {'totalSales': totalSales, 'totalOrders': totalOrders, 'avgOrderValue': totalOrders > 0 ? totalSales / totalOrders : 0.0, 'salesByBeat': salesByBeat};
    } catch (e) {
      return {'totalSales': 0.0, 'totalOrders': 0, 'avgOrderValue': 0.0, 'salesByBeat': <String, double>{}};
    }
  }

  // ─── MUTATIONS ───

  Future<String> createOrder({
    required String orderId, required String? customerId, required String customerName,
    required String beat, required DateTime deliveryDate, required double subtotal,
    required double vat, required double grandTotal, required int itemCount,
    required int totalUnits, required String notes, required List<Map<String, dynamic>> items,
    bool isOutOfBeat = false,
  }) async {
    final userId = client.auth.currentUser?.id;

    // 1. Insert the main order
    await client.from('orders').upsert({
      'id': orderId,
      'user_id': userId,
      'customer_id': customerId,
      'customer_name': customerName,
      'beat_name': beat, // ✅ FIX: DB Column is 'beat_name', value is the variable 'beat'
      'order_date': DateTime.now().toIso8601String(),
      'delivery_date': deliveryDate.toIso8601String().substring(0, 10),
      'subtotal': subtotal,
      'vat': vat,
      'grand_total': grandTotal,
      'item_count': itemCount,
      'total_units': totalUnits,
      'status': 'Pending',
      'notes': notes.isEmpty ? null : notes,
      'team_id': AuthService.currentTeam, // Blueprint Filter
      'is_out_of_beat': isOutOfBeat,
    });

    // 2. Insert the line items
    if (items.isNotEmpty) {
      final itemsWithId = items.map((i) => {...i, 'user_id': userId}).toList();
      await client.from('order_items').delete().eq('order_id', orderId);
      await client.from('order_items').insert(itemsWithId);
    }

    return orderId;
  }

  Future<void> recordCollection({
    required String billNo, required String customerId, required String customerName,
    required double amountPaid, required double remainingBalance, String? paymentMethod, String? driveFileId,
  }) async {
    // Duplicate guard: same bill + customer + amount + same day = skip
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final existing = await client.from('collections')
        .select('id')
        .eq('bill_no', billNo)
        .eq('customer_id', customerId)
        .eq('amount_paid', amountPaid)
        .eq('collection_date', today)
        .eq('team_id', AuthService.currentTeam)
        .maybeSingle();
    if (existing != null) {
      debugPrint('⚠️ Duplicate collection skipped: $billNo / $customerId / $amountPaid');
      return;
    }

    final uid = client.auth.currentUser?.id;
    String repName = client.auth.currentUser?.email ?? 'Offline Rep';
    if (uid != null) {
      final ur = await client.from('app_users').select('full_name').eq('id', uid).maybeSingle();
      repName = ur?['full_name'] as String? ?? repName;
    }
    await client.from('collections').insert({
      'bill_no': billNo, 'customer_id': customerId, 'customer_name': customerName,
      'amount_paid': amountPaid, 'amount_collected': amountPaid,
      'balance_remaining': remainingBalance,
      'rep_email': client.auth.currentUser?.email ?? 'Offline Rep',
      'collected_by': repName,
      'team_id': AuthService.currentTeam,
      'collection_date': today,
      if (paymentMethod != null) 'payment_mode': paymentMethod,
      if (driveFileId != null) 'drive_file_id': driveFileId,
    });
  }

  /// Delete app collections older than 6 days.
  /// Called during sync — by then RECT data from billing software has the real records.
  Future<int> cleanupOldAppCollections() async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 6))
          .toIso8601String().substring(0, 10);
      final old = await client.from('collections')
          .select('id')
          .lt('collection_date', cutoff)
          .eq('team_id', AuthService.currentTeam);
      final ids = (old as List).map((r) => r['id'].toString()).toList();
      if (ids.isEmpty) return 0;
      for (int i = 0; i < ids.length; i += 50) {
        final chunk = ids.sublist(i, (i + 50).clamp(0, ids.length));
        await client.from('collections').delete().inFilter('id', chunk);
      }
      debugPrint('🗑️ Cleaned up ${ids.length} app collections older than 6 days');
      return ids.length;
    } catch (e) {
      debugPrint('⚠️ cleanupOldAppCollections error: $e');
      return 0;
    }
  }

  Future<List<dynamic>> getCollectionHistory(String customerId, {String? teamId}) async {
    try {
      return await client
          .from('collections')
          .select()
          .eq('customer_id', customerId)
          .eq('team_id', teamId ?? AuthService.currentTeam)
          .order('created_at', ascending: false);
    } catch (e) { return []; }
  }

  Future<void> logVisit({
    required String customerId,
    required String beatId,
    required String reason,
    String? notes,
    bool isOutOfBeat = false,
  }) async {
    final now = DateTime.now();
    // Plain date string — compatible with both `date` and `timestamptz` columns
    final visitDate = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    // Full ISO-8601 string — compatible with `time`, `timestamp`, AND `timestamptz` columns.
    // A bare "HH:MM:SS" string causes "invalid input syntax for type timestamp with time zone"
    // when the column type is timestamptz (Supabase default).
    final visitTime = now.toIso8601String();
    await client.from('visit_logs').insert({
      'customer_id': customerId,
      'beat_id': beatId,
      'reason': reason,
      'rep_email': client.auth.currentUser?.email ?? '',
      'user_id': client.auth.currentUser?.id,
      'visit_date': visitDate,
      'visit_time': visitTime,
      'notes': notes ?? '',
      'team_id': AuthService.currentTeam,
      'is_out_of_beat': isOutOfBeat,
    });
  }

  Future<List<VisitLogModel>> getVisitLogs({
    DateTime? startDate,
    DateTime? endDate,
    String? beatId,
    String? reason,
    int limit = 50,
    int offset = 0,
    bool forceRefresh = false,
    Object? teamId = _kTeamIdDefault,
  }) async {
    final String? effectiveTeam = identical(teamId, _kTeamIdDefault)
        ? AuthService.currentTeam
        : teamId as String?;
    try {
      Future<List<dynamic>> doFetch() async {
        var query = client
            .from('visit_logs')
            .select('*, customers(name), beats(beat_name)');
        if (effectiveTeam != null) {
          query = query.eq('team_id', effectiveTeam);
        }
        if (startDate != null) {
          query = query.gte('created_at', startDate.toIso8601String());
        }
        if (endDate != null) {
          final adjustedEnd = endDate.add(const Duration(days: 1));
          query = query.lt('created_at', adjustedEnd.toIso8601String());
        }
        if (beatId != null) query = query.eq('beat_id', beatId);
        if (reason != null) query = query.eq('reason', reason);
        return await query
            .order('created_at', ascending: false)
            .range(offset, offset + limit - 1);
      }

      List<dynamic> response;
      if (offset == 0) {
        final cacheKey = 'visits_${beatId ?? 'all'}_${reason ?? 'all'}_${startDate?.millisecondsSinceEpoch ?? 0}_${endDate?.millisecondsSinceEpoch ?? 0}';
        response = await _fetchWithCache(cacheKey, doFetch, ttlMinutes: 15, forceRefresh: forceRefresh);
      } else {
        response = await doFetch();
      }
      return response
          .map((e) => VisitLogModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      debugPrint('getVisitLogs error: $e');
      return [];
    }
  }

  // ─── COLLECTIONS (ENHANCED) ──────────────────────────────────────────────────

  /// Full-featured collection recording with the enhanced schema.
  /// Also updates the customer's outstanding balance in the same call.
  Future<CollectionModel?> createCollection({
    required String customerId,
    required String customerName,
    required double amountCollected,
    required double outstandingBefore,
    String paymentMode = 'Cash',
    String? chequeNumber,
    String? upiTransactionId,
    String? billNo,
    String? billPhotoUrl,
    String? driveFileId,
    String notes = '',
  }) async {
    final outstandingAfter = (outstandingBefore - amountCollected).clamp(0.0, double.infinity);
    final now = DateTime.now();
    final teamId = AuthService.currentTeam;

    // Resolve rep name for collected_by
    final userId = client.auth.currentUser?.id;
    String repName = client.auth.currentUser?.email ?? '';
    if (userId != null) {
      final userRow = await client.from('app_users').select('full_name').eq('id', userId).maybeSingle();
      repName = userRow?['full_name'] as String? ?? repName;
    }

    final payload = <String, dynamic>{
      'customer_id': customerId,
      'customer_name': customerName,
      'amount_paid': amountCollected,
      'amount_collected': amountCollected,
      'balance_remaining': outstandingAfter,
      'outstanding_before': outstandingBefore,
      'outstanding_after': outstandingAfter,
      'payment_mode': paymentMode,
      'notes': notes,
      'rep_email': client.auth.currentUser?.email ?? '',
      'collected_by': repName,
      'team_id': teamId,
      'collection_date': now.toIso8601String().substring(0, 10),
      if (billNo != null) 'bill_no': billNo,
      if (billPhotoUrl != null) 'bill_photo_url': billPhotoUrl,
      if (driveFileId != null) 'drive_file_id': driveFileId,
      if (chequeNumber != null) 'cheque_number': chequeNumber,
      if (upiTransactionId != null) 'upi_transaction_id': upiTransactionId,
    };

    try {
      final response = await client.from('collections').insert(payload).select().maybeSingle();
      if (response == null) throw Exception('Failed to insert collection');
      final collectionId = response['id'] as String;
      // Update customer's outstanding balance in the junction table
      try {
        // CHANGED: unified profile — update team-specific outstanding column
        final outCol = teamId == 'JA' ? 'outstanding_ja' : 'outstanding_ma';
        await client
            .from('customer_team_profiles')
            .update({outCol: outstandingAfter})
            .eq('customer_id', customerId);
      } catch (balanceError) {
        // Compensate: delete the collection we just inserted to keep data consistent
        debugPrint('createCollection: balance update failed, rolling back collection insert: $balanceError');
        try {
          await client.from('collections').delete().eq('id', collectionId);
        } catch (_) {}
        rethrow;
      }
      // Invalidate caches so UI reflects updated balance immediately
      await invalidateCache('customers');
      return CollectionModel.fromJson(Map<String, dynamic>.from(response));
    } catch (e) {
      debugPrint('createCollection error: $e');
      return null;
    }
  }

  /// Returns full CollectionModel list for a customer, filtered by team.
  Future<List<CollectionModel>> getCollections({
    String? customerId,
    DateTime? startDate,
    DateTime? endDate,
    String? paymentMode,
    String? collectedBy,
  }) async {
    try {
      var query = client
          .from('collections')
          .select()
          .eq('team_id', AuthService.currentTeam);
      if (customerId != null) query = query.eq('customer_id', customerId);
      if (paymentMode != null) query = query.eq('payment_mode', paymentMode);
      if (collectedBy != null) query = query.eq('collected_by', collectedBy);
      if (startDate != null) {
        query = query.gte('collection_date', startDate.toIso8601String().substring(0, 10));
      } else if (!isAdmin) {
        // Default to last 60 days for reps when no date range specified
        final cutoff = DateTime.now().subtract(const Duration(days: 60)).toIso8601String().substring(0, 10);
        query = query.gte('collection_date', cutoff);
      }
      if (endDate != null) query = query.lte('collection_date', endDate.toIso8601String().substring(0, 10));
      final response = await query.order('collection_date', ascending: false);
      return (response as List)
          .map((e) => CollectionModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      debugPrint('getCollections error: $e');
      return [];
    }
  }

  Future<bool> deleteCollection(String collectionId) async {
    try {
      // Fetch the collection first so we can restore the outstanding balance
      final collection = await client.from('collections')
          .select()
          .eq('id', collectionId)
          .eq('team_id', AuthService.currentTeam)
          .maybeSingle();
      if (collection == null) {
        debugPrint('deleteCollection: collection $collectionId not found');
        return false;
      }
      final customerId = collection['customer_id'] as String;
      final amountCollected = (collection['amount_collected'] as num?)?.toDouble()
          ?? (collection['amount_paid'] as num?)?.toDouble()
          ?? 0.0;
      final teamId = AuthService.currentTeam;

      await client.from('collections').delete()
          .eq('id', collectionId)
          .eq('team_id', teamId);

      // CHANGED: Restore customer's outstanding balance (unified profile)
      if (amountCollected > 0) {
        final outCol = teamId == 'JA' ? 'outstanding_ja' : 'outstanding_ma';
        final profile = await client.from('customer_team_profiles')
            .select(outCol)
            .eq('customer_id', customerId)
            .maybeSingle();
        final currentBalance = (profile?[outCol] as num?)?.toDouble() ?? 0.0;
        await client.from('customer_team_profiles')
            .update({outCol: currentBalance + amountCollected})
            .eq('customer_id', customerId);
      }
      // Invalidate caches so UI reflects restored balance immediately
      await invalidateCache('customers');
      return true;
    } catch (e) {
      debugPrint('deleteCollection error: $e');
      return false;
    }
  }


  /// Update a collection's amount, method, and bill number.
  Future<bool> updateCollection(String collectionId, {double? newAmount, String? newMethod, String? newBillNo}) async {
    try {
      final updates = <String, dynamic>{};
      if (newAmount != null) {
        updates['amount_paid'] = newAmount;
        updates['amount_collected'] = newAmount;
      }
      if (newMethod != null) updates['payment_mode'] = newMethod;
      if (newBillNo != null) updates['bill_no'] = newBillNo;
      if (updates.isEmpty) return true;

      await client.from('collections')
          .update(updates)
          .eq('id', collectionId)
          .eq('team_id', AuthService.currentTeam);
      return true;
    } catch (e) {
      debugPrint('updateCollection error: $e');
      return false;
    }
  }

  // ─── ADMIN & STREAM METHODS ───

  Stream<List<dynamic>> getOrdersStream() {
    return client.from('orders').stream(primaryKey: ['id'])
        .eq('team_id', AuthService.currentTeam)
        .order('order_date', ascending: false);
  }

  // ─── 📸 BILL PHOTO STORAGE ───

  /// Uploads bill photo bytes to Supabase Storage bucket 'bill-photos'.
  /// [fileName] is used as the storage name (e.g. bill number or order ID).
  /// Returns the public URL or null on failure.
  Future<String?> uploadBillPhoto(List<int> bytes, String orderId, {String? fileName}) async {
    try {
      final teamId = AuthService.currentTeam;
      final date = DateTime.now().toIso8601String().substring(0, 10);
      final safeName = (fileName ?? orderId).replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final path = '$teamId/${safeName}_$date.jpg';
      await client.storage.from('bill-photos').uploadBinary(
        path,
        Uint8List.fromList(bytes),
        fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
      );
      return client.storage.from('bill-photos').getPublicUrl(path);
    } catch (e) {
      debugPrint('uploadBillPhoto error: $e');
      return null;
    }
  }

  /// Renames a bill photo in Supabase Storage when admin updates the bill number.
  /// Copies to new path, deletes old, returns new public URL.
  Future<String?> renameBillPhoto(String oldUrl, String newBillNo) async {
    try {
      // Extract old path from URL
      final uri = Uri.parse(oldUrl);
      final segments = uri.pathSegments;
      final bucketIndex = segments.indexOf('bill-photos');
      if (bucketIndex < 0 || bucketIndex + 1 >= segments.length) return oldUrl;
      final oldPath = segments.sublist(bucketIndex + 1).join('/');

      // Download old file
      final bytes = await client.storage.from('bill-photos').download(oldPath);

      // Upload with new name
      final teamId = AuthService.currentTeam;
      final date = DateTime.now().toIso8601String().substring(0, 10);
      final safeName = newBillNo.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final newPath = '$teamId/${safeName}_$date.jpg';
      await client.storage.from('bill-photos').uploadBinary(
        newPath,
        bytes,
        fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
      );

      // Delete old file
      await client.storage.from('bill-photos').remove([oldPath]);

      return client.storage.from('bill-photos').getPublicUrl(newPath);
    } catch (e) {
      debugPrint('renameBillPhoto error: $e');
      return null; // Non-fatal — old URL still works
    }
  }

  /// Stage 1: Delivery rep saves OCR-extracted bill data as PRELIMINARY values.
  /// Does NOT overwrite final_bill_no (reserved for admin's local-software entry).
  Future<void> updateOrderDeliveryBill({
    required String orderId,
    required String billNo,
    double? billAmount,
    String? billPhotoUrl,
  }) async {
    await client.from('orders').update({
      'preliminary_bill_no': billNo,
      if (billAmount != null) 'preliminary_amount': billAmount,
      if (billPhotoUrl != null) 'bill_photo_url': billPhotoUrl,
      'verified_by_delivery': true,
      'status': 'Delivered',
    }).eq('id', orderId);
  }

  /// Stage 2: Admin enters FINAL bill data from local software.
  /// Called from AdminBillVerificationTab after comparing preliminary vs local values.
  Future<void> verifyOrderBill({
    required String orderId,
    required String finalBillNo,
    required double finalAmount,
  }) async {
    await client.from('orders').update({
      'final_bill_no': finalBillNo,
      'actual_billed_amount': finalAmount,
      'verified_by_office': true,
      'bill_verified': true,
      'status': 'Invoiced',
    }).eq('id', orderId).eq('team_id', AuthService.currentTeam);
  }

  // ─── 🚀 PHASE 4: BACKGROUND PROCESSING PIPELINE ───

  /// Phase 4: Complete background processing pipeline for delivery bill submission
  /// 1. Uploads directly to Google Drive (not Supabase Storage)
  /// 2. Sends image to Gemini OCR API for data extraction
  /// 3. Updates orders table with Drive URL and OCR-extracted data
  /// 4. Sets status to 'Pending Verification'
  /// 5. Logs any errors to app_error_logs table
  Future<bool> processDeliveryBillWithBackgroundPipeline({
    required String orderId,
    required String imagePath,
    Uint8List? imageBytes,
    String? extractedBillNo,
    String? extractedAmount,
  }) async {
    debugPrint('🚀 Pipeline: Starting for order $orderId');

    try {
      // Read bytes from file path (mobile) or use provided bytes (web)
      final bytes = imageBytes ?? await File(imagePath).readAsBytes();

      // Step 1: Run Gemini OCR FIRST (from local file, before upload)
      String? ocrBillNo = extractedBillNo;
      String? ocrAmount = extractedAmount;

      if (ocrBillNo == null && ocrAmount == null) {
        debugPrint('🤖 Step 1: Running Gemini OCR...');
        try {
          final ocrResult = await GeminiOcrService.extractInvoiceDataFromBytes(bytes);
          ocrBillNo = ocrResult.billNo;
          ocrAmount = ocrResult.amount;
          debugPrint('✅ OCR: bill=$ocrBillNo, amount=$ocrAmount');
        } catch (ocrError) {
          debugPrint('⚠️ OCR failed (non-fatal, admin can enter manually): $ocrError');
        }
      }

      // Step 2: Upload photo to Supabase Storage with bill number as filename
      debugPrint('📸 Step 2: Uploading to Supabase Storage...');
      final photoUrl = await uploadBillPhoto(bytes.toList(), orderId, fileName: ocrBillNo);
      if (photoUrl == null) {
        throw Exception('Failed to upload photo to Supabase Storage');
      }
      debugPrint('✅ Photo uploaded: $photoUrl');

      // Step 3: Save photo URL + OCR data to orders table
      debugPrint('💾 Step 3: Updating order in database...');
      await client.from('orders').update({
        'bill_photo_url': photoUrl,
        'billed_no': ocrBillNo,
        'final_bill_no': ocrBillNo,
        'invoice_amount': ocrAmount != null ? double.tryParse(ocrAmount) : null,
        'actual_billed_amount': ocrAmount != null ? double.tryParse(ocrAmount) : null,
        'verified_by_delivery': true,
        'status': 'Pending Verification',
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', orderId);

      debugPrint('✅ Order $orderId → Pending Verification');
      return true;

    } catch (e, stackTrace) {
      debugPrint('💥 Pipeline failed for $orderId: $e');
      debugPrint('Stack: $stackTrace');
      rethrow;
    }
  }


  /// Admin: clears the bill photo from an order at any time.
  /// Nullifies bill_photo_url in the orders table and attempts to delete
  /// the file from Supabase Storage if it's still hosted there.
  Future<void> clearBillPhoto(String orderId, String? currentPhotoUrl) async {
    // 1. Remove file from Supabase Storage (only if URL is still a Supabase URL)
    if (currentPhotoUrl != null && currentPhotoUrl.contains('supabase')) {
      try {
        final storagePath = currentPhotoUrl.split('/bill-photos/').last.split('?').first;
        await client.storage.from('bill-photos').remove([storagePath]);
      } catch (e) {
        debugPrint('clearBillPhoto: storage delete skipped ($e)');
      }
    }
    // Drive-hosted photos are intentionally kept in Drive — only the DB reference is cleared.

    // 2. Null out the URL in the orders table
    await client.from('orders').update({'bill_photo_url': null}).eq('id', orderId);
  }

  // ─── 👤 USER ADMIN (uses service role key via env for user creation) ───

  /// Reads service role key + URL from env.json at runtime (not compile-time).
  Future<Map<String, String>> _loadAdminEnv() async {
    final envString = await rootBundle.loadString('env.json');
    final envData = jsonDecode(envString) as Map<String, dynamic>;
    final serviceKey = (envData['SUPABASE_SERVICE_ROLE_KEY'] ?? '').toString();
    final supabaseUrl = (envData['SUPABASE_URL'] ?? '').toString();
    if (serviceKey.isEmpty) throw Exception('SUPABASE_SERVICE_ROLE_KEY not found in env.json');
    if (supabaseUrl.isEmpty) throw Exception('SUPABASE_URL not found in env.json');
    return {'serviceKey': serviceKey, 'supabaseUrl': supabaseUrl};
  }

  /// Creates a new auth user via Supabase Admin REST API, then inserts app_users row.
  /// Creates an Auth user + app_users row. Returns the new user's uid so the
  /// caller can set role-specific follow-ups (e.g. brand_access for brand_rep).
  Future<String> adminCreateUser({
    required String email,
    required String password,
    required String fullName,
    required String role,
    required String teamId,
    String upiId = '',
  }) async {
    final env = await _loadAdminEnv();
    final serviceKey = env['serviceKey']!;
    final supabaseUrl = env['supabaseUrl']!;
    final resp = await http.post(
      Uri.parse('$supabaseUrl/auth/v1/admin/users'),
      headers: {
        'apikey': serviceKey,
        'Authorization': 'Bearer $serviceKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'email': email,
        'password': password,
        'email_confirm': true,
      }),
    );
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      throw Exception(body['msg'] ?? body['message'] ?? 'Failed to create user');
    }
    final authUser = jsonDecode(resp.body) as Map<String, dynamic>;
    final uid = authUser['id'] as String;
    await client.from('app_users').insert({
      'id': uid,
      'email': email,
      'full_name': fullName,
      'role': role,
      'team_id': teamId,
      'upi_id': upiId,
      'is_active': true,
    });
    return uid;
  }

  /// Hard-deletes a user from Auth + app_users.
  Future<void> adminDeleteUser(String uid) async {
    try {
      final env = await _loadAdminEnv();
      await http.delete(
        Uri.parse('${env['supabaseUrl']}/auth/v1/admin/users/$uid'),
        headers: {
          'apikey': env['serviceKey']!,
          'Authorization': 'Bearer ${env['serviceKey']}',
        },
      );
    } catch (e) {
      debugPrint('Warning: could not delete auth user: $e');
    }
    await client.from('app_users').delete().eq('id', uid);
  }

  /// Sends a password reset email to the user.
  Future<void> sendPasswordResetEmail(String email) async {
    await client.auth.resetPasswordForEmail(email);
  }

  /// Update auth user's password and/or email via Admin API.
  /// Uses _resolveAppUserId to handle ID mismatch for early users.
  Future<void> adminSetPassword(String uid, String newPassword) async {
    final resolvedUid = await _resolveAuthUid(uid);
    final env = await _loadAdminEnv();
    final resp = await http.put(
      Uri.parse('${env['supabaseUrl']}/auth/v1/admin/users/$resolvedUid'),
      headers: {
        'apikey': env['serviceKey']!,
        'Authorization': 'Bearer ${env['serviceKey']}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'password': newPassword}),
    );
    if (resp.statusCode != 200) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      throw Exception(body['msg'] ?? body['message'] ?? 'Failed to update password');
    }
  }

  Future<void> adminSetEmail(String uid, String newEmail) async {
    final resolvedUid = await _resolveAuthUid(uid);
    final env = await _loadAdminEnv();
    final resp = await http.put(
      Uri.parse('${env['supabaseUrl']}/auth/v1/admin/users/$resolvedUid'),
      headers: {
        'apikey': env['serviceKey']!,
        'Authorization': 'Bearer ${env['serviceKey']}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'email': newEmail, 'email_confirm': true}),
    );
    if (resp.statusCode != 200) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      throw Exception(body['msg'] ?? body['message'] ?? 'Failed to update email');
    }
  }

  /// Resolve app_users.id to Auth UID (may differ for early users like Ranjeet)
  Future<String> _resolveAuthUid(String appUserId) async {
    try {
      // Try to find the user's email from app_users, then find auth UID
      final user = await client.from('app_users').select('email').eq('id', appUserId).maybeSingle();
      if (user == null) return appUserId;
      final email = user['email'] as String;
      // Use admin API to find auth user by email
      final env = await _loadAdminEnv();
      final resp = await http.get(
        Uri.parse('${env['supabaseUrl']}/auth/v1/admin/users?page=1&per_page=1000'),
        headers: {
          'apikey': env['serviceKey']!,
          'Authorization': 'Bearer ${env['serviceKey']}',
        },
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final users = data['users'] as List? ?? [];
        for (final u in users) {
          if ((u['email'] as String?)?.toLowerCase() == email.toLowerCase()) {
            return u['id'] as String;
          }
        }
      }
    } catch (e) {
      debugPrint('_resolveAuthUid error: $e');
    }
    return appUserId;
  }

  /// CSV outstanding balance bulk update.
  /// Each row: {customer_id, team, outstanding_amount}
  Future<Map<String, dynamic>> updateOutstandingFromCsv(List<Map<String, dynamic>> rows) async {
    int updated = 0;
    final List<String> errors = [];
    for (final row in rows) {
      try {
        final customerId = row['customer_id']?.toString().trim() ?? '';
        final team = row['team']?.toString().trim().toUpperCase() ?? '';
        final amountStr = row['outstanding_amount']?.toString().trim() ?? '';
        if (customerId.isEmpty || amountStr.isEmpty) {
          errors.add('Skipped empty row');
          continue;
        }
        final amount = double.tryParse(amountStr);
        if (amount == null) {
          errors.add('Invalid amount for $customerId: $amountStr');
          continue;
        }
        // CHANGED: unified profile — update team-specific outstanding column
        final effectiveTeam = team.isNotEmpty ? team : AuthService.currentTeam;
        final outCol = effectiveTeam == 'JA' ? 'outstanding_ja' : 'outstanding_ma';
        final result = await client
            .from('customer_team_profiles')
            .update({outCol: amount})
            .eq('customer_id', customerId)
            .select('customer_id');
        if ((result as List).isEmpty) {
          errors.add('Customer not found: $customerId');
        } else {
          updated++;
        }
      } catch (e) {
        errors.add('Row error: $e');
      }
    }
    return {'updated': updated, 'errors': errors};
  }

  Future<void> signOut() async {
    _resolvedAppUserId = null; // Clear cached user ID on logout
    await AuthService.instance.signOut();
  }

  Future<List<ProductCategoryModel>> getAllProductCategories() async => getProductCategories();

  // ─── CUSTOMER BILLS / RECEIPTS (from OPNBIL / RECT / RCTBIL) ───

  /// Get outstanding bills for a customer from customer_bills table (OPNBIL data).
  /// For reps: filters to last 2 months. For admin: all data.
  Future<List<Map<String, dynamic>>> getCustomerBills(String customerId, {bool repOnly = false, String? teamId}) async {
    var query = client.from('customer_bills').select()
        .eq('customer_id', customerId)
        .eq('team_id', teamId ?? AuthService.currentTeam);
    if (repOnly) {
      final twoMonthsAgo = DateTime.now().subtract(const Duration(days: 60)).toIso8601String().substring(0, 10);
      query = query.gte('bill_date', twoMonthsAgo);
    }
    final data = await query.order('bill_date', ascending: false);
    return List<Map<String, dynamic>>.from(data);
  }

  /// Get all bills for current team (for outstanding report).
  Future<List<Map<String, dynamic>>> getCustomerBillsForTeam({String? teamId}) async {
    final data = await client.from('customer_bills').select()
        .eq('team_id', teamId ?? AuthService.currentTeam)
        .order('bill_date', ascending: false);
    return List<Map<String, dynamic>>.from(data);
  }

  /// Get receipts for a customer from customer_receipts table (RECT data).
  Future<List<Map<String, dynamic>>> getCustomerReceipts(String customerId, {bool repOnly = false, String? teamId}) async {
    var query = client.from('customer_receipts').select()
        .eq('customer_id', customerId)
        .eq('team_id', teamId ?? AuthService.currentTeam);
    if (repOnly) {
      final twoMonthsAgo = DateTime.now().subtract(const Duration(days: 60)).toIso8601String().substring(0, 10);
      query = query.gte('receipt_date', twoMonthsAgo);
    }
    final data = await query.order('receipt_date', ascending: false);
    return List<Map<String, dynamic>>.from(data);
  }

  /// Get billed items for a customer from ITTR data (customer_billed_items table).
  Future<List<Map<String, dynamic>>> getCustomerBilledItems(String customerId, {bool repOnly = false, String? teamId}) async {
    var query = client.from('customer_billed_items').select()
        .eq('customer_id', customerId)
        .eq('team_id', teamId ?? AuthService.currentTeam);
    if (repOnly) {
      final twoMonthsAgo = DateTime.now().subtract(const Duration(days: 60)).toIso8601String().substring(0, 10);
      query = query.gte('bill_date', twoMonthsAgo);
    }
    final data = await query.order('bill_date', ascending: false);
    return List<Map<String, dynamic>>.from(data);
  }

  /// Get receipt bill breakdown (RCTBIL data) for receipts.
  Future<List<Map<String, dynamic>>> getReceiptBillDetails(String receiptNo, {String? teamId}) async {
    final team = teamId ?? AuthService.currentTeam;
    final data = await client.from('customer_receipt_bills').select()
        .eq('receipt_no', receiptNo)
        .eq('team_id', team)
        .order('bill_date', ascending: false);
    return List<Map<String, dynamic>>.from(data);
  }

  Future<void> addProduct(Map<String, dynamic> data) async {
    await client.from('products').insert({
      'id': 'PROD-${DateTime.now().millisecondsSinceEpoch}',
      // Safe defaults for required DB columns not in the add-product form
      'status': 'available',
      'sku': '',
      'brand': '',
      'pack_size': '',
      'image_url': '',
      'semantic_label': '',
      'team_id': AuthService.currentTeam,
      ...data, // data can override team_id if explicitly provided
    });
  }

  Future<void> updateProduct(String id, Map<String, dynamic> data) async {
    await client.from('products').update(data).eq('id', id);
  }

  Future<void> deleteProduct(String id) async {
    await client.from('products').delete().eq('id', id);
    await invalidateCache('products');
  }

  Future<void> deleteCustomer(String id) async {
    // Delete team profile first (FK dependency), then customer
    await client.from('customer_team_profiles').delete().eq('customer_id', id);
    await client.from('customers').delete().eq('id', id);
    await invalidateCache('customers');
  }

  Future<void> updateCustomerLastOrder(String customerId, double orderValue) async {
    try {
      await client.from('customers').update({
        'last_order_value': orderValue,
        'last_order_date': DateTime.now().toIso8601String(),
      }).eq('id', customerId);
    } catch (e) {
      debugPrint('⚠️ updateCustomerLastOrder failed: $e');
    }
  }


  // ─── 📦 ORDER MANAGEMENT ───

  /// Throws if the order is older than 3 days, unless isSuperAdmin is true.
  Future<void> _assertEditWindow(String orderId, {bool isSuperAdmin = false}) async {
    if (isSuperAdmin) return;
    final response = await client
        .from('orders')
        .select('order_date')
        .eq('id', orderId)
        .eq('team_id', AuthService.currentTeam)
        .maybeSingle();
    if (response == null) throw Exception('Order not found');
    final orderDate = DateTime.parse(response['order_date'] as String);
    if (DateTime.now().difference(orderDate).inDays.abs() > 3) {
      throw Exception('This order is older than 3 days and cannot be modified.');
    }
  }

  /// Valid order status transitions. Super admins bypass this check.
  /// Valid order status transitions. Must match the `order_status` PostgreSQL enum:
  /// Pending, Confirmed, Delivered, Cancelled, Invoiced, Paid, Returned,
  /// Partially Delivered, Pending Verification, Verified, Flagged.
  static const _validStatusTransitions = <String, List<String>>{
    'Pending': ['Confirmed', 'Delivered', 'Cancelled', 'Pending Verification'],
    'Confirmed': ['Delivered', 'Cancelled', 'Pending Verification'],
    'Delivered': ['Invoiced', 'Pending Verification', 'Returned'],
    'Pending Verification': ['Invoiced', 'Verified', 'Flagged', 'Delivered'],
    'Verified': ['Paid', 'Flagged'],
    'Invoiced': ['Paid', 'Flagged'],
    'Flagged': ['Pending Verification', 'Verified', 'Delivered'],
    'Paid': [],
    'Cancelled': [],
    'Returned': [],
    'Partially Delivered': ['Delivered', 'Cancelled'],
  };

  Future<void> updateOrderStatus(String orderId, String newStatus, {bool isSuperAdmin = false}) async {
    await _assertEditWindow(orderId, isSuperAdmin: isSuperAdmin);

    // Validate status transition unless super admin
    if (!isSuperAdmin) {
      final current = await client.from('orders').select('status').eq('id', orderId).eq('team_id', AuthService.currentTeam).maybeSingle();
      if (current == null) throw Exception('Order not found');
      final currentStatus = current['status'] as String? ?? 'Pending';
      final allowed = _validStatusTransitions[currentStatus] ?? [];
      if (!allowed.contains(newStatus)) {
        throw Exception('Cannot change order status from "$currentStatus" to "$newStatus".');
      }
    }

    await client.from('orders').update({'status': newStatus}).eq('id', orderId).eq('team_id', AuthService.currentTeam);
    await invalidateCache('recent_orders');
  }

  Future<void> deleteOrder(String orderId, {bool isSuperAdmin = false}) async {
    await _assertEditWindow(orderId, isSuperAdmin: isSuperAdmin);
    await client.from('orders').delete().eq('id', orderId).eq('team_id', AuthService.currentTeam);
    await invalidateCache('recent_orders');
  }

  Future<List<Map<String, dynamic>>> getOrdersByDate(String dateString, {List<String>? teamIds}) async {
    try {
      final userId = client.auth.currentUser?.id;
      final nextDay = DateTime.parse(dateString).add(const Duration(days: 1));
      final nextDayString = nextDay.toIso8601String().substring(0, 10);

      var query = client
          .from('orders')
          .select('*, order_items(*)');

      // Support multi-team fetch for shared-beat reps
      if (teamIds != null && teamIds.length > 1) {
        query = query.inFilter('team_id', teamIds);
      } else {
        query = query.eq('team_id', AuthService.currentTeam);
      }

      query = query
          .gte('order_date', dateString)
          .lt('order_date', nextDayString);

      if (userId != null) {
        query = query.eq('user_id', userId);
      }

      final response = await query;
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint("🚨 Error fetching orders by date: $e");
      return [];
    }
  }

  // CHANGED: optional teamId filter — null means all teams (unified)
  Future<List<OrderModel>> getOrdersByDateRange({
    DateTime? startDate,
    DateTime? endDate,
    String? teamId,
    int limit = 50,
    int offset = 0,
    bool forceRefresh = false,
  }) async {
    try {
      Future<List<dynamic>> doFetch() async {
        var query = client.from('orders').select('*, order_items(*)');
        if (teamId != null) query = query.eq('team_id', teamId);
        if (startDate != null) query = query.gte('order_date', startDate.toIso8601String());
        if (endDate != null) {
          final adjustedEnd = endDate.add(const Duration(days: 1));
          query = query.lt('order_date', adjustedEnd.toIso8601String());
        }
        return await query
            .order('order_date', ascending: false)
            .range(offset, offset + limit - 1);
      }

      List<dynamic> response;
      if (offset == 0) {
        final cacheKey = 'orders_${teamId ?? 'all'}_${startDate?.millisecondsSinceEpoch ?? 0}_${endDate?.millisecondsSinceEpoch ?? 0}';
        response = await _fetchWithCache(cacheKey, doFetch, ttlMinutes: 15, forceRefresh: forceRefresh);
      } else {
        response = await doFetch();
      }
      return response.map((e) => OrderModel.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (e) {
      debugPrint("Error fetching orders by date range: $e");
      return [];
    }
  }

  // ─── 🏷️ PRODUCT CATEGORIES & UNITS ───

  Future<void> createProductCategory(String name, int sortOrder) async {
    await client.from('product_categories').insert({
      'name': name,
      'sort_order': sortOrder,
      'is_active': true,
      'team_id': AuthService.currentTeam
    });
  }

  Future<void> updateProductCategory(String id, String name, int sortOrder, bool isActive) async {
    await client.from('product_categories').update({
      'name': name,
      'sort_order': sortOrder,
      'is_active': isActive,
    }).eq('id', id);
  }

  Future<void> deleteProductCategory(String id) async {
    // Resolve name + team before deletion so we can purge matching
    // user_brand_access rows. Without this cleanup, brand access rows
    // become orphaned and inflate rep-level brand counts forever.
    final cat = await client.from('product_categories')
        .select('name, team_id')
        .eq('id', id)
        .maybeSingle();
    await client.from('product_categories').delete().eq('id', id);
    if (cat != null) {
      final name = cat['name'] as String?;
      final teamId = cat['team_id'] as String?;
      if (name != null && name.isNotEmpty) {
        var q = client.from('user_brand_access').delete().eq('brand', name);
        if (teamId != null && teamId.isNotEmpty) {
          q = q.eq('team_id', teamId);
        }
        await q;
      }
    }
  }

  // ─── 🏷️ PRODUCT SUBCATEGORIES ───

  Future<List<ProductSubcategoryModel>> getSubcategories(String categoryId, {bool forceRefresh = false}) async {
    final teamKey = 'subcats_${AuthService.currentTeam}_$categoryId';
    final tsKey = '${teamKey}_ts';
    final box = Hive.isBoxOpen('cache_${AuthService.currentTeam}')
        ? Hive.box('cache_${AuthService.currentTeam}')
        : await Hive.openBox('cache_${AuthService.currentTeam}');

    final cachedStr = box.get(teamKey) as String?;
    final tsMs = box.get(tsKey) as int?;
    final isStale = tsMs == null ||
        DateTime.now().millisecondsSinceEpoch - tsMs > 24 * 60 * 60 * 1000;

    Future<List<ProductSubcategoryModel>> doFetch() async {
      final data = await client
          .from('product_subcategories')
          .select()
          .eq('category_id', categoryId)
          .eq('team_id', AuthService.currentTeam)
          .order('sort_order');
      await box.put(teamKey, jsonEncode(data));
      await box.put(tsKey, DateTime.now().millisecondsSinceEpoch);
      return (data as List)
          .map((e) => ProductSubcategoryModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }

    if (forceRefresh) return doFetch();
    if (isStale) {
      if (cachedStr != null) {
        Future(() async { try { await doFetch(); } catch (_) {} });
      } else {
        return doFetch();
      }
    }
    if (cachedStr != null) {
      return (jsonDecode(cachedStr) as List)
          .map((e) => ProductSubcategoryModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return doFetch();
  }

  Future<List<ProductSubcategoryModel>> getAllSubcategoriesForTeam() async {
    try {
      final data = await client
          .from('product_subcategories')
          .select()
          .eq('team_id', AuthService.currentTeam)
          .order('sort_order');
      return (data as List)
          .map((e) => ProductSubcategoryModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> createProductSubcategory(String name, String categoryId, int sortOrder) async {
    await client.from('product_subcategories').insert({
      'name': name, 'category_id': categoryId,
      'sort_order': sortOrder, 'team_id': AuthService.currentTeam,
    });
    _invalidateSubcategoryCache(categoryId);
  }

  Future<void> updateProductSubcategory(String id, String name, String categoryId, int sortOrder) async {
    await client.from('product_subcategories').update({
      'name': name, 'sort_order': sortOrder,
    }).eq('id', id);
    _invalidateSubcategoryCache(categoryId);
  }

  Future<void> deleteProductSubcategory(String id, String categoryId) async {
    await client.from('product_subcategories').delete().eq('id', id);
    _invalidateSubcategoryCache(categoryId);
  }

  void _invalidateSubcategoryCache(String categoryId) {
    if (Hive.isBoxOpen('cache_${AuthService.currentTeam}')) {
      final box = Hive.box('cache_${AuthService.currentTeam}');
      box.delete('subcats_${AuthService.currentTeam}_$categoryId');
    }
  }

  // ─── 👥 USERS & ADMIN CONTROLS ───

  Future<List<AppUserModel>> getAppUsers({bool forceRefresh = false, bool allTeams = false}) async {
    try {
      final cacheKey = allTeams ? 'app_users_all' : 'app_users';
      final response = await _fetchWithCache(cacheKey, () async {
        var query = client.from('app_users').select();
        if (!allTeams) query = query.eq('team_id', AuthService.currentTeam);
        return await query.order('full_name');
      }, forceRefresh: forceRefresh, ttlMinutes: 30);
      return response.map((e) => AppUserModel.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (e) {
      debugPrint("Error fetching users: $e");
      return [];
    }
  }

  /// Resolves a user_id (which may be auth UID) to full_name.
  /// Tries direct app_users.id match first, then falls back to checking
  /// auth admin API for early users whose auth UID differs from app_users.id.
  Future<String?> getUserFullName(String userId) async {
    try {
      // Direct match by app_users.id
      final direct = await client.from('app_users').select('full_name').eq('id', userId).maybeSingle();
      if (direct != null) return direct['full_name'] as String?;
      // Fallback for early users: find auth user email, then match app_users
      final env = await _loadAdminEnv();
      if (env['serviceKey'] == null) return null;
      final resp = await http.get(
        Uri.parse('${env['supabaseUrl']}/auth/v1/admin/users?page=1&per_page=1000'),
        headers: {
          'apikey': env['serviceKey']!,
          'Authorization': 'Bearer ${env['serviceKey']}',
        },
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final authUsers = data['users'] as List? ?? [];
        for (final au in authUsers) {
          if (au['id'] == userId) {
            final email = (au['email'] as String?)?.toLowerCase();
            if (email != null) {
              final byEmail = await client.from('app_users').select('full_name').eq('email', email).maybeSingle();
              return byEmail?['full_name'] as String?;
            }
            break;
          }
        }
      }
    } catch (e) {
      debugPrint('getUserFullName error for $userId: $e');
    }
    return null;
  }

  Future<void> createAppUser({required String email, required String password, required String fullName, String role = 'sales_rep'}) async {
    // Note: To fully create an auth user requires Supabase Admin API.
    // This inserts the profile record into the database table for tracking.
    await client.from('app_users').insert({
      'email': email,
      'full_name': fullName,
      'role': role,
      'team_id': AuthService.currentTeam
    });
  }

  Future<void> updateAppUser({required String id, String? email, String? password, String? fullName, String? role, bool? isActive}) async {
    final Map<String, dynamic> updates = {};
    if (email != null && email.isNotEmpty) updates['email'] = email;
    if (fullName != null && fullName.isNotEmpty) updates['full_name'] = fullName;
    if (role != null) updates['role'] = role;
    if (isActive != null) updates['is_active'] = isActive;

    if (updates.isNotEmpty) {
      await client.from('app_users').update(updates).eq('id', id);
    }
  }

  Future<String?> getUserRole() async {
    final user = client.auth.currentUser;
    if (user == null) return null;
    try {
      final response = await client
          .from('app_users')
          .select('role')
          .eq('id', user.id)
          .maybeSingle();
      return response?['role'] as String?;
    } catch (e) {
      debugPrint('Error fetching user role: $e');
      return null;
    }
  }

  Future<AppUserModel?> getCurrentUser() async {
    final user = client.auth.currentUser;
    if (user == null) return null;
    try {
      // Query by email for reliability — early users may have mismatched IDs
      final email = user.email;
      final response = await client
          .from('app_users')
          .select()
          .eq(email != null ? 'email' : 'id', email ?? user.id)
          .maybeSingle();
      if (response == null) return null;
      return AppUserModel.fromJson(Map<String, dynamic>.from(response));
    } catch (e) {
      debugPrint('Error fetching current user: $e');
      return null;
    }
  }

  // ─── 🏪 CUSTOMERS ───

  Future<void> createCustomer({required String name, required String phone, required String address, required String type, String? beatId, String? beat, String deliveryRoute = 'Unassigned'}) async {
    final customerId = 'CUST-${DateTime.now().millisecondsSinceEpoch}';
    // 1. Insert universal identity data
    await client.from('customers').insert({
      'id': customerId,
      'name': name, 'phone': phone, 'address': address, 'type': type,
      'delivery_route': deliveryRoute,
      'last_order_value': 0,
    });
    // 2. CHANGED: Create unified profile row with current team's beat data
    final isJa = AuthService.currentTeam == 'JA';
    await client.from('customer_team_profiles').upsert({
      'customer_id': customerId,
      'team_ja': isJa,
      'team_ma': !isJa,
      'beat_id_ja': isJa ? beatId : null,
      'beat_name_ja': isJa ? (beat ?? '') : '',
      'outstanding_ja': 0,
      'beat_id_ma': !isJa ? beatId : null,
      'beat_name_ma': !isJa ? (beat ?? '') : '',
      'outstanding_ma': 0,
    }, onConflict: 'customer_id');

    // 3. Invalidate the Hive cache so the new customer appears immediately
    //    on the next getCustomers() call (without waiting for the 30-min TTL).
    try {
      final box = Hive.isBoxOpen('cache_${AuthService.currentTeam}')
          ? Hive.box('cache_${AuthService.currentTeam}')
          : await Hive.openBox('cache_${AuthService.currentTeam}');
      await box.delete('customers_${AuthService.currentTeam}');
      await box.delete('customers_${AuthService.currentTeam}_ts');
    } catch (_) {}
  }

  Future<void> updateCustomer({required String id, required String name, required String phone, required String address, required String type, String? beatId, String? beat, String deliveryRoute = 'Unassigned'}) async {
    // 1. Update universal identity data
    await client.from('customers').update({
      'name': name, 'phone': phone, 'address': address, 'type': type,
      'delivery_route': deliveryRoute,
    }).eq('id', id);
    // 2. CHANGED: Update beat data for current team only, preserve other team's data
    final isJa = AuthService.currentTeam == 'JA';
    final updates = <String, dynamic>{
      'customer_id': id,
      if (isJa) 'team_ja': true,
      if (isJa) 'beat_id_ja': beatId,
      if (isJa) 'beat_name_ja': beat ?? '',
      if (!isJa) 'team_ma': true,
      if (!isJa) 'beat_id_ma': beatId,
      if (!isJa) 'beat_name_ma': beat ?? '',
    };
    await client.from('customer_team_profiles').upsert(updates, onConflict: 'customer_id');
  }

  // ─── 🗺️ BEATS & ROUTING ───

  Future<void> upsertBeat({String? id, required String beatName, required String beatCode, required String area, required String route, required List<String> weekdays}) async {
    final payload = {
      'beat_name': beatName, 'beat_code': beatCode, 'area': area,
      'route': route, 'weekdays': weekdays, 'team_id': AuthService.currentTeam
    };
    if (id != null && id.isNotEmpty) {
      await client.from('beats').update(payload).eq('id', id);
    } else {
      await client.from('beats').insert({
        'id': 'BEAT-${DateTime.now().millisecondsSinceEpoch}',
        ...payload,
      });
    }
  }

  Future<void> setUserBeats({required String userId, required List<String> beatIds}) async {
    // 1. Wipe old assignments
    await client.from('user_beats').delete().eq('user_id', userId);

    // 2. Insert new assignments
    if (beatIds.isNotEmpty) {
      final inserts = beatIds.map((bId) => {'user_id': userId, 'beat_id': bId}).toList();
      await client.from('user_beats').insert(inserts);
    }
  }

  Future<List<BeatModel>> getUserBeats(String userId, {bool allTeams = false}) async {
    try {
      // Resolve app_users.id — may differ from auth UID for early users
      final resolvedId = await _resolveAppUserId(userId);
      final response = await client
          .from('user_beats')
          .select('weekdays, beats (*)')
          .eq('user_id', resolvedId);
      final List<dynamic> data = response as List<dynamic>;

      // Return all assigned beats (cross-team included) or filter by current team
      final beats = data
          .where((item) =>
      item['beats'] != null &&
          (allTeams || (item['beats'] as Map)['team_id'] == AuthService.currentTeam))
          .map((item) {
        final beat = BeatModel.fromJson(Map<String, dynamic>.from(item['beats'] as Map));
        // Override weekdays with per-user schedule if set
        final userWeekdays = item['weekdays'];
        if (userWeekdays is List && userWeekdays.isNotEmpty) {
          return beat.copyWith(weekdays: List<String>.from(userWeekdays));
        }
        return beat;
      }).toList();

      if (beats.isEmpty) {
        debugPrint('[getUserBeats] no assigned beats for $userId');
      }
      return beats;
    } catch (e) {
      debugPrint('[getUserBeats] error: $e');
      return [];
    }
  }

  Future<void> updateUserBeatWeekdays(String userId, String beatId, List<String> weekdays) async {
    await client.from('user_beats').update({'weekdays': weekdays})
        .eq('user_id', userId).eq('beat_id', beatId);
  }

  // ─── 📊 DASHBOARD METRICS ───

  Future<List<Map<String, dynamic>>> getActiveDeliveries({bool includeOld = false}) async {
    try {
      // Delivery rep is shared across both teams — fetch orders from all teams.
      // Join customers to restore delivery_route and phone access in the
      // delivery dashboard UI (order['customers']['phone'] / ['delivery_route']).
      // Default: only show orders whose delivery_date is today or within the next
      // 3 days, so stale forgotten orders don't pollute the route list.
      var query = client
          .from('orders')
          .select('*, customers(phone, delivery_route, address)')
          .eq('status', 'Pending')
          .inFilter('team_id', ['JA', 'MA']);
      if (!includeOld) {
        // Include orders with delivery_date in the last 14 days (so Friday
        // orders still appear on Monday) through 3 days ahead. Orders older
        // than 14 days are either stuck or forgotten — admin uses includeOld.
        final minIso = DateTime.now().subtract(const Duration(days: 14)).toIso8601String().substring(0, 10);
        final maxIso = DateTime.now().add(const Duration(days: 3)).toIso8601String().substring(0, 10);
        query = query.gte('delivery_date', minIso).lte('delivery_date', maxIso);
      }
      final response = await query.order('order_date', ascending: false);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint('getActiveDeliveries error: $e');
      return [];
    }
  }

  Future<double> getDailyCollectionTotal() async {
    try {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final response = await client
          .from('collections')
          .select('amount_paid')
          .eq('team_id', AuthService.currentTeam)
          .gte('created_at', '$today 00:00:00');

      double total = 0;
      for (var row in response) {
        total += ((row as Map)['amount_paid'] as num?)?.toDouble() ?? 0.0;
      }
      return total;
    } catch (e) {
      return 0.0;
    }
  }

  /// Returns a map of beatId → count of distinct customers visited today.
  Future<Map<String, int>> getVisitedCountsTodayByBeat() async {
    try {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final response = await client
          .from('visit_logs')
          .select('beat_id, customer_id')
          .eq('team_id', AuthService.currentTeam)
          .eq('visit_date', today);
      final Map<String, Set<String>> beatCustomers = {};
      for (final row in response as List) {
        final beatId = row['beat_id'] as String?;
        final customerId = row['customer_id'] as String?;
        if (beatId == null || customerId == null) continue;
        beatCustomers.putIfAbsent(beatId, () => {}).add(customerId);
      }
      return {for (final e in beatCustomers.entries) e.key: e.value.length};
    } catch (e) {
      return {};
    }
  }

  /// Returns a map of beatId → count of collections done today
  /// (derived from customers' beat assignments).
  Future<Map<String, int>> getCollectionCountsTodayByBeat(List<CustomerModel> customers) async {
    try {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      // Build customer_id → beat_id mapping from cached customers
      final Map<String, String> customerBeat = {};
      for (final c in customers) {
        final beatId = c.beatIdForTeam(AuthService.currentTeam);
        if (beatId != null) customerBeat[c.id] = beatId;
      }
      final response = await client
          .from('collections')
          .select('customer_id')
          .eq('team_id', AuthService.currentTeam)
          .gte('collection_date', today)
          .lte('collection_date', today);
      final Map<String, int> counts = {};
      for (final row in response as List) {
        final cid = row['customer_id'] as String?;
        if (cid == null) continue;
        final beatId = customerBeat[cid];
        if (beatId != null) counts[beatId] = (counts[beatId] ?? 0) + 1;
      }
      return counts;
    } catch (e) {
      return {};
    }
  }

  // ─── 🏃 BEAT ASSIGNMENTS (Beat-Centric) ───

  // CHANGED: unified profile — use team-specific beat column
  Future<Map<String, int>> getCustomerCountsByBeat() async {
    try {
      final Map<String, int> counts = {};
      // Count for both teams so admin sees correct counts for all beats
      for (final team in ['JA', 'MA']) {
        final beatCol = team == 'JA' ? 'beat_id_ja' : 'beat_id_ma';
        final teamCol = team == 'JA' ? 'team_ja' : 'team_ma';
        final response = await client
            .from('customer_team_profiles')
            .select(beatCol)
            .eq(teamCol, true)
            .not(beatCol, 'is', null);
        for (final row in response as List) {
          final beatId = row[beatCol] as String?;
          if (beatId != null) counts[beatId] = (counts[beatId] ?? 0) + 1;
        }
      }
      return counts;
    } catch (e) {
      return {};
    }
  }

  Future<List<AppUserModel>> getSalesReps() async {
    try {
      final response = await client
          .from('app_users')
          .select()
          .eq('team_id', AuthService.currentTeam)
          .or('role.eq.sales_rep,role.eq.brand_rep')
          .eq('is_active', true)
          .order('full_name');
      return response.map((e) => AppUserModel.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> updateUserHeroImage(String userId, String imageUrl) async {
    try {
      await client
          .from('app_users')
          .update({'hero_image_url': imageUrl})
          .eq('id', userId);
      debugPrint('✅ Updated hero image for user $userId');
    } catch (e) {
      debugPrint('❌ Failed to update hero image: $e');
      rethrow;
    }
  }

  /// Uploads a hero selfie to Supabase Storage and updates the user's hero_image_url.
  /// Returns the public URL or null on failure.
  Future<String?> uploadHeroAvatarToStorage(String userId, List<int> bytes) async {
    try {
      final teamId = AuthService.currentTeam;
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = 'avatars/$teamId/${userId}_$ts.jpg';
      await client.storage.from('bill-photos').uploadBinary(
        path,
        Uint8List.fromList(bytes),
        fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
      );
      final url = client.storage.from('bill-photos').getPublicUrl(path);
      await updateUserHeroImage(userId, url);
      debugPrint('✅ Hero avatar uploaded to Supabase: $url');
      return url;
    } catch (e) {
      debugPrint('❌ uploadHeroAvatarToStorage error: $e');
      return null;
    }
  }

  Future<Map<String, List<AppUserModel>>> getBeatAssignments({bool allTeams = false}) async {
    try {
      final users = await getAppUsers(allTeams: allTeams);
      if (users.isEmpty) return {};
      final userMap = {for (final u in users) u.id: u};
      final userIds = users.map((u) => u.id).toList();
      final ubResp = await client
          .from('user_beats')
          .select('user_id, beat_id')
          .inFilter('user_id', userIds);
      final Map<String, List<AppUserModel>> map = {};
      for (final row in ubResp as List) {
        final beatId = row['beat_id'] as String;
        final userId = row['user_id'] as String;
        if (userMap.containsKey(userId)) {
          map.putIfAbsent(beatId, () => []).add(userMap[userId]!);
        }
      }
      return map;
    } catch (e) {
      return {};
    }
  }

  /// Returns per-user weekday overrides: {beatId_userId: weekdays}
  Future<Map<String, List<String>>> getUserBeatWeekdays() async {
    try {
      final resp = await client.from('user_beats').select('user_id, beat_id, weekdays');
      final Map<String, List<String>> map = {};
      for (final row in resp as List) {
        final weekdays = row['weekdays'];
        if (weekdays is List && weekdays.isNotEmpty) {
          final key = '${row['beat_id']}_${row['user_id']}';
          map[key] = List<String>.from(weekdays);
        }
      }
      return map;
    } catch (e) {
      return {};
    }
  }

  Future<void> addUserToBeat(String userId, String beatId, {List<String>? weekdays}) async {
    final data = <String, dynamic>{'user_id': userId, 'beat_id': beatId};
    if (weekdays != null && weekdays.isNotEmpty) data['weekdays'] = weekdays;
    await client.from('user_beats').upsert(data, onConflict: 'user_id,beat_id');
  }

  Future<void> removeUserFromBeat(String userId, String beatId) async {
    await client.from('user_beats').delete().eq('user_id', userId).eq('beat_id', beatId);
  }

  // ─── 💰 MULTI-BILL SETTLEMENT ───

  /// Single allocation inside a settle event.
  /// `billNo` is the bill printed on the collection row (rep-typed or derived
  /// from order id). `orderId` is optional — when present, the order's status
  /// flips to 'Paid' once the allocation covers its full grand_total.
  /// `orderOutstanding` is the remaining amount currently owed on that bill;
  /// used to decide whether the allocation is partial or clears the bill.
  ///
  /// Why: the old `settleMultipleOrders` assumed every settle cleared every
  /// selected bill and zeroed the team's outstanding. Reps actually split
  /// ₹10k across two bills, or pay ₹400 against a ₹500 bill. The new shape
  /// lets the caller describe exactly where each rupee goes.
  ///
  /// How to apply: wrap each bill the rep is paying into a `BillAllocation`
  /// and pass them together so the whole settle is one event with one
  /// cheque photo / one rep-entered timestamp.

  /// Settles one or more bills with per-bill allocations. Writes one
  /// collection row per allocation, marks an order `Paid` only when its
  /// allocation covers the full bill, and decrements the team's outstanding
  /// by the TOTAL paid (never zeroes it out of the blue).
  ///
  /// Rolls back inserted collection rows if the downstream update fails.
  Future<void> settleOrderBills({
    required List<BillAllocation> allocations,
    required String customerId,
    required String customerName,
    required String paymentMethod,
    String? chequeNo,
    String? chequeBank,
    DateTime? chequeDate,
    String? chequePhotoUrl,
    String? driveFileId,
    String? notes,
  }) async {
    if (allocations.isEmpty) return;

    final uid = client.auth.currentUser?.id;
    String rName = client.auth.currentUser?.email ?? 'Offline Rep';
    if (uid != null) {
      final ur = await client
          .from('app_users')
          .select('full_name')
          .eq('id', uid)
          .maybeSingle();
      rName = ur?['full_name'] as String? ?? rName;
    }

    final today = DateTime.now().toIso8601String().substring(0, 10);
    final team = AuthService.currentTeam;
    final repEmail = client.auth.currentUser?.email ?? 'Offline Rep';
    final chequeDateStr =
        chequeDate?.toIso8601String().substring(0, 10);

    final insertedBillKeys = <String>[];

    try {
      for (final a in allocations) {
        final remaining =
            (a.orderOutstanding - a.amount).clamp(0, double.infinity).toDouble();
        await client.from('collections').insert({
          'bill_no': a.billNo,
          'customer_id': customerId,
          'customer_name': customerName,
          'amount_paid': a.amount,
          'amount_collected': a.amount,
          'balance_remaining': remaining,
          'rep_email': repEmail,
          'collected_by': rName,
          'team_id': team,
          'payment_mode': paymentMethod,
          'collection_date': today,
          if (chequeNo != null && chequeNo.isNotEmpty) 'cheque_number': chequeNo,
          if (chequeBank != null && chequeBank.isNotEmpty) 'cheque_bank': chequeBank,
          if (chequeDateStr != null) 'cheque_date': chequeDateStr,
          if (chequePhotoUrl != null && chequePhotoUrl.isNotEmpty)
            'cheque_photo_url': chequePhotoUrl,
          if (driveFileId != null && driveFileId.isNotEmpty)
            'drive_file_id': driveFileId,
          if (notes != null && notes.isNotEmpty) 'notes': notes,
        });
        insertedBillKeys.add(a.billNo);
      }

      // Flip orders to Paid only when their allocation covers the full bill.
      final paidOrderIds = allocations
          .where((a) => a.orderId != null && a.amount + 0.009 >= a.orderOutstanding)
          .map((a) => a.orderId!)
          .toList();
      if (paidOrderIds.isNotEmpty) {
        await client
            .from('orders')
            .update({'status': 'Paid'})
            .inFilter('id', paidOrderIds);
      }

      // Decrement — don't overwrite. Protects against two reps settling
      // concurrently on the same customer.
      final totalPaid = allocations.fold<double>(0, (s, a) => s + a.amount);
      final outCol = team == 'JA' ? 'outstanding_ja' : 'outstanding_ma';
      final profile = await client
          .from('customer_team_profiles')
          .select(outCol)
          .eq('customer_id', customerId)
          .eq('team_id', team)
          .maybeSingle();
      final current = (profile?[outCol] as num?)?.toDouble() ?? 0;
      final next = (current - totalPaid).clamp(0, double.infinity).toDouble();
      await client
          .from('customer_team_profiles')
          .update({outCol: next})
          .eq('customer_id', customerId)
          .eq('team_id', team);
    } catch (e) {
      // Best-effort rollback of the collection rows we just wrote.
      for (final billNo in insertedBillKeys) {
        try {
          await client
              .from('collections')
              .delete()
              .eq('bill_no', billNo)
              .eq('customer_id', customerId)
              .eq('collection_date', today);
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Deprecated — retained so stale callers keep compiling. Builds an
  /// allocation list that mirrors the old behaviour (split the total
  /// evenly over the orders) and delegates to [settleOrderBills].
  @Deprecated('Use settleOrderBills with per-bill allocations.')
  Future<void> settleMultipleOrders({
    required List<String> orderIds,
    required String customerId,
    required String customerName,
    required String paymentMethod,
    required double totalAmount,
    String? driveFileId,
  }) async {
    if (orderIds.isEmpty) return;
    final per = totalAmount / orderIds.length;
    final allocations = orderIds
        .map((id) => BillAllocation(
              billNo: id.split('-').last.toUpperCase(),
              orderId: id,
              amount: per,
              orderOutstanding: per,
            ))
        .toList();
    await settleOrderBills(
      allocations: allocations,
      customerId: customerId,
      customerName: customerName,
      paymentMethod: paymentMethod,
      driveFileId: driveFileId,
    );
  }

  // ─── BRAND ACCESS CONTROL ──────────────────────────────────────────────────

  /// Returns list of enabled brand names for a user.
  /// Sales_rep with no records → auto-populate all team categories (open
  /// access is the intended default).
  /// Brand_rep with no records → return [] (fail safe — admin must explicitly
  /// enable at least one brand in admin_brand_access_tab before the rep can
  /// see anything). Prevents an unconfigured brand_rep from silently being
  /// granted every team brand.
  /// Always fetches from network (no cache) — this is a security control
  /// that must reflect admin changes immediately on the salesman's device.
  Future<List<String>> getUserBrandAccess(String userId) async {
    try {
      // Resolve auth UID → app_users.id. For early users (e.g. Ranjeet) the
      // two differ, and the admin sheet keys brand access off app_users.id
      // while the rep's device passes auth.uid. Without this resolution the
      // lookup returns empty, the auto-assign path then FK-fails, and the
      // rep silently ends up with zero brand access (no cross-team fetch).
      userId = await _resolveAppUserId(userId);

      // Fetch ALL enabled brands across all teams for this user
      final response = await client.from('user_brand_access')
          .select('brand')
          .eq('user_id', userId)
          .eq('is_enabled', true);
      final brands = (response as List).map((e) => e['brand'] as String).toList();

      // Defensive filter: drop brand names that no longer exist in an active
      // product_categories row. Heals orphans left over from before the
      // deleteProductCategory cascade was added so stale rows stop granting
      // ghost access / inflating admin counts.
      if (brands.isNotEmpty) {
        final catResp = await client.from('product_categories')
            .select('name')
            .eq('is_active', true)
            .inFilter('name', brands);
        final validNames = (catResp as List)
            .map((e) => e['name'] as String)
            .toSet();
        final filtered = brands.where((b) => validNames.contains(b)).toList();
        debugPrint('🔍 BRAND_ACCESS user=$userId raw=$brands valid=$filtered');
        // Admin explicitly configured this user — respect the result even if
        // every enabled brand turned out to be an orphan (return []).
        return filtered;
      }

      // Check if ANY records exist (including disabled ones)
      final anyRecords = await client.from('user_brand_access')
          .select('brand')
          .eq('user_id', userId)
          .limit(1);
      if ((anyRecords as List).isNotEmpty) {
        // Admin configured this user but all brands disabled — respect that
        return [];
      }

      // No records at all — decide based on role.
      final userRow = await client.from('app_users')
          .select('team_id, role')
          .eq('id', userId)
          .maybeSingle();
      final role = userRow?['role'] as String? ?? '';
      final teamId = userRow?['team_id'] as String? ?? AuthService.currentTeam;

      // Brand_rep must be explicitly configured. Return [] so the products
      // screen lands on its "brand access denied" state and forces admin to
      // open admin_brand_access_tab and toggle at least one brand on.
      if (role == 'brand_rep') return [];

      // Sales_rep / other: first login with no config — auto-assign all team
      // categories so they have open access by default.
      final teamCats = await client.from('product_categories')
          .select('name')
          .eq('team_id', teamId)
          .eq('is_active', true);
      final catNames = (teamCats as List).map((e) => e['name'] as String).toList();
      for (final brand in catNames) {
        await client.from('user_brand_access').upsert(
          {'user_id': userId, 'team_id': teamId, 'brand': brand, 'is_enabled': true},
          onConflict: 'user_id,team_id,brand',
        );
      }
      await invalidateCache('brand_access_$userId');
      return catNames;
    } catch (e) {
      debugPrint('getUserBrandAccess error: $e');
      return []; // fallback: no restriction (show all)
    }
  }

  /// Upsert a brand access record for a user, then invalidate cache.
  Future<void> setUserBrandAccess(String userId, String brand, bool enabled, {String? teamId}) async {
    final team = teamId ?? AuthService.currentTeam;
    await client.from('user_brand_access').upsert(
      {
        'user_id': userId,
        'team_id': team,
        'brand': brand,
        'is_enabled': enabled,
      },
      onConflict: 'user_id,team_id,brand',
    );
    await invalidateCache('brand_access_$userId');
  }

  /// Delete all brand access records for a user (reset to open access).
  Future<void> resetUserBrandAccess(String userId) async {
    await client.from('user_brand_access')
        .delete()
        .eq('user_id', userId)
        .eq('team_id', AuthService.currentTeam);
    await invalidateCache('brand_access_$userId');
  }

  /// Returns IDs of customers in the current team who have purchased any
  /// product in [brandCategories] — either through an in-app order OR
  /// through the external billing software (ITTR-synced customer_billed_items).
  /// Used by the customer list to pin a brand_rep's repeat customers to the top.
  ///
  /// Returns only IDs (not full rows) to keep egress minimal — the caller
  /// already has the full customer list and just needs to partition it.
  Future<Set<String>> getCustomerIdsWithBrandHistory(List<String> brandCategories) async {
    if (brandCategories.isEmpty) return {};
    final team = AuthService.currentTeam;
    final resultIds = <String>{};
    try {
      // Fetch products in allowed brands. Collect both IDs (for in-app order
      // joins) and names/billing_names (for ITTR item_name string matching).
      final productsResp = await client
          .from('products')
          .select('id, name, billing_name')
          .inFilter('category', brandCategories)
          .eq('team_id', team);
      final productIds = <String>[];
      final productNames = <String>{};
      for (final p in (productsResp as List)) {
        final id = p['id'] as String?;
        if (id != null) productIds.add(id);
        final bname = p['billing_name'] as String?;
        if (bname != null && bname.trim().isNotEmpty) productNames.add(bname);
        final name = p['name'] as String?;
        if (name != null && name.trim().isNotEmpty) productNames.add(name);
      }

      // Path 1: in-app orders → order_items filtered to our product_ids.
      // Both inFilters are chunked by 100 to stay under PostgREST URL caps.
      if (productIds.isNotEmpty) {
        final allOrderIds = <String>{};
        for (int i = 0; i < productIds.length; i += 100) {
          final chunk = productIds.sublist(i, (i + 100).clamp(0, productIds.length));
          final orderItemsResp = await client
              .from('order_items')
              .select('order_id')
              .inFilter('product_id', chunk);
          allOrderIds.addAll(
            (orderItemsResp as List).map((o) => o['order_id'] as String),
          );
        }
        if (allOrderIds.isNotEmpty) {
          final orderIds = allOrderIds.toList();
          for (int i = 0; i < orderIds.length; i += 100) {
            final chunk = orderIds.sublist(i, (i + 100).clamp(0, orderIds.length));
            final ordersResp = await client
                .from('orders')
                .select('customer_id')
                .inFilter('id', chunk)
                .eq('team_id', team);
            resultIds.addAll((ordersResp as List)
                .map((o) => o['customer_id'] as String?)
                .whereType<String>());
          }
        }
      }

      // Path 2: ITTR-synced billed items where item_name matches any of
      // our allowed-brand products. Bills may come in before any in-app
      // order, so this catches offline-channel customers too. Chunk by 100
      // so the inFilter URL stays well under PostgREST's ~8KB cap even if
      // a brand_rep has a huge product roster.
      if (productNames.isNotEmpty) {
        final namesList = productNames.toList();
        for (int i = 0; i < namesList.length; i += 100) {
          final chunk = namesList.sublist(i, (i + 100).clamp(0, namesList.length));
          final billedResp = await client
              .from('customer_billed_items')
              .select('customer_id')
              .inFilter('item_name', chunk)
              .eq('team_id', team)
              .not('customer_id', 'is', null);
          resultIds.addAll((billedResp as List)
              .map((o) => o['customer_id'] as String?)
              .whereType<String>());
        }
      }
    } catch (e) {
      debugPrint('getCustomerIdsWithBrandHistory error: $e');
    }
    return resultIds;
  }

  // ─── STOCK VISIBILITY CONTROL ────────────────────────────────────────────────

  /// Returns whether stock levels should be shown for a user.
  /// Returns true if no record exists (default = show stock).
  /// Always fetches from network (no cache) — security control must be real-time.
  Future<bool> getUserShowStock(String userId) async {
    try {
      final response = await client.from('user_settings')
          .select('show_stock')
          .eq('user_id', userId);
      if ((response as List).isEmpty) return true; // no record = show stock (default)
      return response.first['show_stock'] as bool? ?? true;
    } catch (e) {
      debugPrint('getUserShowStock error: $e');
      return true; // fallback: show stock
    }
  }

  /// Upsert the show_stock setting for a user, then invalidate cache.
  Future<void> setUserShowStock(String userId, bool showStock) async {
    await client.from('user_settings').upsert(
      {
        'user_id': userId,
        'show_stock': showStock,
      },
      onConflict: 'user_id',
    );
    await invalidateCache('show_stock_$userId');
  }

  /// Returns all distinct category/brand names for the current team.
  Future<List<String>> getAllBrandsForTeam() async {
    final response = await client.from('product_categories')
        .select('name')
        .eq('team_id', AuthService.currentTeam)
        .eq('is_active', true)
        .order('sort_order');
    return (response as List).map((e) => e['name'] as String).toList();
  }
}