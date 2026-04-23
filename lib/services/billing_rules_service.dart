// Reads centralized business rules from the `billing_rules` table.
//
// Replaces three legacy patterns:
//   1. SharedPreferences ('csds_enabled_JA' / 'csds_enabled_MA') — was
//      device-local, so two admins could disagree on whether CSDS is on.
//   2. Hardcoded ternaries in admin_orders_tab.dart (Pharmacy → JA, etc.).
//   3. Hardcoded role check in admin_orders_tab.dart (brand_rep merge).
//
// Cache: short TTL (5 min) + explicit invalidate() after a write. For an
// in-flight export the caller should snapshot rules ONCE at the start
// (use snapshotForExport) and pass the snapshot through, instead of
// hitting the service again mid-build.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// How orders are grouped into invoices on a CSV export.
enum MergingStrategy {
  /// JA today: brand_rep merges per customer, sales_rep stays per-order.
  splitByRepRole,

  /// All orders for the same customer collapse into one invoice regardless
  /// of which rep booked them.
  mergeAllByCustomer,

  /// One invoice per order. No merging at all.
  noMerge;

  static MergingStrategy fromString(String? s) {
    switch (s) {
      case 'merge_all_by_customer':
        return MergingStrategy.mergeAllByCustomer;
      case 'no_merge':
        return MergingStrategy.noMerge;
      case 'split_by_rep_role':
      default:
        return MergingStrategy.splitByRepRole;
    }
  }
}

/// Frozen snapshot of every rule needed for one export run. Pass this
/// through the export pipeline so a mid-build cache expiry can't shift
/// behaviour halfway through CSV generation.
@immutable
class BillingRulesSnapshot {
  final MergingStrategy mergingForJa;
  final MergingStrategy mergingForMa;
  final Map<String, String> organicIndiaDefaults; // lowercased keys
  final String organicIndiaFallback;
  /// Per-team customer IDs that must NEVER merge at export.
  final Set<String> noMergeCustomerIdsJa;
  final Set<String> noMergeCustomerIdsMa;
  /// Per-team auto-block threshold in days. 0 = disabled.
  final int autoBlockOverdueDaysJa;
  final int autoBlockOverdueDaysMa;
  /// Per-team auto-block outstanding rupee threshold. 0 = disabled.
  final double autoBlockOutstandingJa;
  final double autoBlockOutstandingMa;

  const BillingRulesSnapshot({
    required this.mergingForJa,
    required this.mergingForMa,
    required this.organicIndiaDefaults,
    required this.organicIndiaFallback,
    this.noMergeCustomerIdsJa = const {},
    this.noMergeCustomerIdsMa = const {},
    this.autoBlockOverdueDaysJa = 0,
    this.autoBlockOverdueDaysMa = 0,
    this.autoBlockOutstandingJa = 0,
    this.autoBlockOutstandingMa = 0,
  });

  MergingStrategy mergingFor(String teamId) =>
      teamId == 'JA' ? mergingForJa : mergingForMa;

  /// Default Organic India billing team for a customer type.
  /// Lookup is case-insensitive — matches the `c.type.toLowerCase()`
  /// convention from the legacy hardcoded code.
  String organicIndiaDefaultFor(String? customerType) {
    final key = (customerType ?? '').toLowerCase().trim();
    return organicIndiaDefaults[key] ?? organicIndiaFallback;
  }

  Set<String> noMergeCustomerIdsFor(String teamId) =>
      teamId == 'JA' ? noMergeCustomerIdsJa : noMergeCustomerIdsMa;

  int autoBlockOverdueDaysFor(String teamId) =>
      teamId == 'JA' ? autoBlockOverdueDaysJa : autoBlockOverdueDaysMa;

  double autoBlockOutstandingFor(String teamId) =>
      teamId == 'JA' ? autoBlockOutstandingJa : autoBlockOutstandingMa;
}

class BillingRulesService {
  BillingRulesService._() {
    _subscribeToAuthChanges();
  }
  static final BillingRulesService instance = BillingRulesService._();

  static const Duration _cacheTtl = Duration(minutes: 5);

  Map<String, dynamic>? _cache;
  DateTime? _loadedAt;
  // Stored only to keep the subscription alive for the app's lifetime;
  // the singleton is never disposed in the live app. Tests that care
  // can reach it via a debug hook if one is added later.
  // ignore: unused_field
  StreamSubscription<AuthState>? _authSub;

  /// Subscribe to Supabase auth so a pre-login empty cache (from RLS
  /// denying the warm-up read before the user signs in) is discarded
  /// the moment the user authenticates. Without this, the first 5 min
  /// of post-login reads return hardcoded defaults even though the DB
  /// has admin-edited values. See the audit note in
  /// `project_billing_rules_audit_2026_04_23.md`.
  void _subscribeToAuthChanges() {
    try {
      _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((e) {
        switch (e.event) {
          case AuthChangeEvent.signedIn:
          case AuthChangeEvent.signedOut:
          case AuthChangeEvent.userUpdated:
          case AuthChangeEvent.initialSession:
            // initialSession fires on cold-start when a persisted
            // session is restored — ensures any empty pre-login cache
            // is discarded before the first post-auth accessor call.
            invalidate();
            break;
          default:
            break;
        }
      });
    } catch (err) {
      // If Supabase isn't initialized yet (tests, etc.), skip. Tests
      // that exercise this service should call invalidate() manually.
      debugPrint('[BillingRules] auth subscribe failed: $err');
    }
  }

  // ── Typed accessors ────────────────────────────────────────────────────

  /// Per-team CSDS toggle. Replaces SharedPreferences['csds_enabled_$team'].
  Future<bool> isCsdsEnabled(String teamId) async {
    final v = await _get(
      ruleKey: 'pricing_csds_enabled',
      scopeType: 'team',
      scopeId: teamId,
      defaultValue: false,
    );
    return v is bool ? v : false;
  }

  /// Per-team merging strategy. Replaces the hardcoded brand_rep/sales_rep
  /// split in admin_orders_tab.dart `_buildCsv`.
  Future<MergingStrategy> getMergingStrategy(String teamId) async {
    final v = await _get(
      ruleKey: 'export_merging_strategy',
      scopeType: 'team',
      scopeId: teamId,
      defaultValue: 'split_by_rep_role',
    );
    return MergingStrategy.fromString(v as String?);
  }

  /// Default Organic India billing team for a given customer type.
  /// Replaces `c.type.toLowerCase() == 'pharmacy' ? 'JA' : 'MA'`.
  /// Case-insensitive — pass raw `customer.type`.
  Future<String> getOrganicIndiaDefaultForCustomerType(String? customerType) async {
    final v = await _get(
      ruleKey: 'organic_india_default_by_customer_type',
      scopeType: 'global',
      scopeId: null,
      defaultValue: <String, dynamic>{
        'pharmacy': 'JA',
        '_default': 'MA',
      },
    );
    if (v is! Map) return 'MA';
    final key = (customerType ?? '').toLowerCase().trim();
    return (v[key] ?? v['_default'] ?? 'MA') as String;
  }

  /// Snapshot every rule the export path cares about in one DB read so the
  /// in-flight CSV build is immune to mid-build cache expiry.
  Future<BillingRulesSnapshot> snapshotForExport() async {
    await _ensureLoaded();
    final mergingForJa = MergingStrategy.fromString(
      _readSync('export_merging_strategy', 'team', 'JA') as String?,
    );
    final mergingForMa = MergingStrategy.fromString(
      _readSync('export_merging_strategy', 'team', 'MA') as String?,
    );
    final oiRaw = _readSync(
      'organic_india_default_by_customer_type',
      'global',
      null,
    );
    final oiMap = <String, String>{};
    String fallback = 'MA';
    if (oiRaw is Map) {
      oiRaw.forEach((k, v) {
        if (k is String && v is String) {
          if (k == '_default') {
            fallback = v;
          } else {
            oiMap[k.toLowerCase()] = v;
          }
        }
      });
    }
    // Customer-category rules (Phase B of Rules Tab customer work).
    Set<String> readIdSet(String teamId) {
      final raw = _readSync('no_merge_customer_ids', 'team', teamId);
      if (raw is List) {
        return raw.map((e) => e.toString()).toSet();
      }
      return const <String>{};
    }
    int readInt(String key, String teamId, int fallback) {
      final v = _readSync(key, 'team', teamId);
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
      return fallback;
    }
    double readDouble(String key, String teamId, double fallback) {
      final v = _readSync(key, 'team', teamId);
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? fallback;
      return fallback;
    }

    return BillingRulesSnapshot(
      mergingForJa: mergingForJa,
      mergingForMa: mergingForMa,
      organicIndiaDefaults: oiMap,
      organicIndiaFallback: fallback,
      noMergeCustomerIdsJa: readIdSet('JA'),
      noMergeCustomerIdsMa: readIdSet('MA'),
      autoBlockOverdueDaysJa: readInt('auto_block_overdue_days', 'JA', 0),
      autoBlockOverdueDaysMa: readInt('auto_block_overdue_days', 'MA', 0),
      autoBlockOutstandingJa: readDouble('auto_block_outstanding', 'JA', 0),
      autoBlockOutstandingMa: readDouble('auto_block_outstanding', 'MA', 0),
    );
  }

  // ── Customer block check ─────────────────────────────────────────────

  /// Returns block status for a customer on a team. Combines the manual
  /// `order_blocked_*` flag on `customer_team_profiles` with the auto-
  /// block thresholds from billing_rules. Manual reason wins when both
  /// trigger (explicit > derived). Cached 60s per (customer, team).
  ///
  /// Caller pattern:
  ///   final r = await BillingRulesService.instance.isCustomerBlocked(id, 'JA');
  ///   if (r.blocked) showDialog(...r.reason);
  Future<({bool blocked, String? reason, String source})> isCustomerBlocked(
    String customerId,
    String teamId,
  ) async {
    final cacheKey = '$customerId|$teamId';
    final cached = _blockCache[cacheKey];
    if (cached != null &&
        DateTime.now().difference(cached.loadedAt) < _blockCacheTtl) {
      return (blocked: cached.blocked, reason: cached.reason, source: cached.source);
    }

    // 1. Manual block on profile row (wins if set).
    try {
      final teamBlockCol = teamId == 'JA' ? 'order_blocked_ja' : 'order_blocked_ma';
      final teamReasonCol = teamId == 'JA' ? 'order_block_reason_ja' : 'order_block_reason_ma';
      final row = await SupabaseService.instance.client
          .from('customer_team_profiles')
          .select('$teamBlockCol, $teamReasonCol, outstanding_ja, outstanding_ma')
          .eq('customer_id', customerId)
          .maybeSingle();
      final manual = (row?[teamBlockCol] as bool?) ?? false;
      final manualReason = row?[teamReasonCol] as String?;
      if (manual) {
        final res = (
          blocked: true,
          reason: (manualReason == null || manualReason.isEmpty)
              ? 'Blocked by admin'
              : 'Blocked by admin: $manualReason',
          source: 'manual',
        );
        _blockCache[cacheKey] = _BlockCacheEntry(
          blocked: res.blocked, reason: res.reason, source: res.source,
          loadedAt: DateTime.now());
        return res;
      }

      // 2. Auto-block by outstanding amount.
      await _ensureLoaded();
      final outThreshold = (teamId == 'JA'
          ? _readSync('auto_block_outstanding', 'team', 'JA')
          : _readSync('auto_block_outstanding', 'team', 'MA'));
      final outThresholdD = outThreshold is num ? outThreshold.toDouble() : 0.0;
      if (outThresholdD > 0) {
        final outCol = teamId == 'JA' ? 'outstanding_ja' : 'outstanding_ma';
        final outVal = (row?[outCol] as num?)?.toDouble() ?? 0.0;
        if (outVal > outThresholdD) {
          final res = (
            blocked: true,
            reason: 'Outstanding ₹${outVal.toStringAsFixed(0)} '
                'exceeds threshold ₹${outThresholdD.toStringAsFixed(0)}',
            source: 'auto_outstanding',
          );
          _blockCache[cacheKey] = _BlockCacheEntry(
            blocked: res.blocked, reason: res.reason, source: res.source,
            loadedAt: DateTime.now());
          return res;
        }
      }

      // 3. Auto-block by oldest overdue days.
      final daysThreshold = (teamId == 'JA'
          ? _readSync('auto_block_overdue_days', 'team', 'JA')
          : _readSync('auto_block_overdue_days', 'team', 'MA'));
      final daysThresholdI = daysThreshold is num
          ? daysThreshold.toInt()
          : (daysThreshold is String ? int.tryParse(daysThreshold) ?? 0 : 0);
      if (daysThresholdI > 0) {
        // Look for an unpaid bill whose bill_date is older than threshold.
        final cutoff = DateTime.now()
            .subtract(Duration(days: daysThresholdI))
            .toIso8601String()
            .substring(0, 10);
        final oldestBill = await SupabaseService.instance.client
            .from('customer_bills')
            .select('bill_date, invoice_no')
            .eq('customer_id', customerId)
            .eq('team_id', teamId)
            .eq('cleared', false)
            .lte('bill_date', cutoff)
            .order('bill_date', ascending: true)
            .limit(1)
            .maybeSingle();
        if (oldestBill != null) {
          final billDate = oldestBill['bill_date']?.toString();
          final inv = oldestBill['invoice_no']?.toString();
          final res = (
            blocked: true,
            reason: 'Oldest unpaid bill ($inv on $billDate) exceeds '
                '$daysThresholdI-day threshold',
            source: 'auto_overdue',
          );
          _blockCache[cacheKey] = _BlockCacheEntry(
            blocked: res.blocked, reason: res.reason, source: res.source,
            loadedAt: DateTime.now());
          return res;
        }
      }
    } catch (e) {
      debugPrint('[BillingRules] isCustomerBlocked lookup failed: $e');
      // Fail-open so a transient DB hiccup doesn't lock out legitimate
      // orders. Admin's manual flag is authoritative for critical blocks.
    }

    final res = (blocked: false, reason: null as String?, source: 'ok');
    _blockCache[cacheKey] = _BlockCacheEntry(
      blocked: res.blocked, reason: res.reason, source: res.source,
      loadedAt: DateTime.now());
    return res;
  }

  /// Drop cached block decisions (e.g. after admin toggles a block).
  void invalidateBlockCache([String? customerId]) {
    if (customerId == null) {
      _blockCache.clear();
    } else {
      _blockCache.removeWhere((k, _) => k.startsWith('$customerId|'));
    }
  }

  static const Duration _blockCacheTtl = Duration(seconds: 60);
  final Map<String, _BlockCacheEntry> _blockCache = {};

  /// Force the next read to refetch. Call after a rule write from the UI.
  void invalidate() {
    _cache = null;
    _loadedAt = null;
    // When a rule changes, auto-block thresholds may shift — wipe the
    // per-customer block cache too.
    _blockCache.clear();
  }

  /// Synchronous snapshot of the stock-zero-grace rule.
  ///
  /// Called on every product-card render so it MUST be sync. Returns
  /// the cached value when available, else the hardcoded default of 2.
  /// The cache is warmed on the first product-list fetch via
  /// [ensureWarmed]; callers that render products early should await
  /// that once at app start so the first frame uses the real rule.
  ///
  /// Returning 0 is a legit admin choice (kill the grace window), so
  /// callers must NOT treat 0 as "not loaded".
  int get stockZeroGraceDays {
    // Not loaded yet → safe default. Matches the hardcoded fallback
    // used in ProductModel.isInStockGrace before this wiring.
    if (_cache == null) return 2;
    final raw = _readSync('stock_zero_grace_days', 'global', null);
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 2;
    return 2;
  }

  /// Prime the cache so the very first product-list render uses the
  /// rule, not the default. Safe to call redundantly; the internal
  /// TTL handles stampede.
  Future<void> ensureWarmed() async => _ensureLoaded();

  // ── Internals ─────────────────────────────────────────────────────────

  Future<dynamic> _get({
    required String ruleKey,
    required String scopeType,
    String? scopeId,
    required dynamic defaultValue,
  }) async {
    await _ensureLoaded();
    final v = _readSync(ruleKey, scopeType, scopeId);
    return v ?? defaultValue;
  }

  dynamic _readSync(String ruleKey, String scopeType, String? scopeId) {
    final key = '$ruleKey|$scopeType|${scopeId ?? ''}';
    return _cache?[key];
  }

  Future<void> _ensureLoaded() async {
    if (_cache != null &&
        _loadedAt != null &&
        DateTime.now().difference(_loadedAt!) < _cacheTtl) {
      return;
    }
    await _reload();
  }

  Future<void> _reload() async {
    try {
      final rows = await SupabaseService.instance.client
          .from('billing_rules')
          .select('rule_key, scope_type, scope_id, value, enabled');
      final map = <String, dynamic>{};
      for (final row in (rows as List)) {
        if (row['enabled'] == false) continue;
        final key = '${row['rule_key']}|${row['scope_type']}|${row['scope_id'] ?? ''}';
        map[key] = row['value'];
      }
      _cache = map;
      _loadedAt = DateTime.now();
    } catch (e) {
      // If the table doesn't exist yet (Phase 1 migration not applied) or
      // RLS blocks the read, fall back to an empty cache. Every accessor
      // has a default that matches the pre-migration hardcoded behaviour,
      // so the app keeps working unchanged.
      debugPrint('BillingRulesService reload failed: $e');
      _cache = {};
      _loadedAt = DateTime.now();
    }
  }
}

/// Internal: cached outcome of a customer-block check. See
/// [BillingRulesService.isCustomerBlocked]. 60s TTL matches the admin's
/// expected "flip block → rep is locked within a minute" behaviour.
class _BlockCacheEntry {
  final bool blocked;
  final String? reason;
  final String source;
  final DateTime loadedAt;
  _BlockCacheEntry({
    required this.blocked,
    required this.reason,
    required this.source,
    required this.loadedAt,
  });
}
