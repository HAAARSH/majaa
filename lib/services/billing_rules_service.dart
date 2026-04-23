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

  const BillingRulesSnapshot({
    required this.mergingForJa,
    required this.mergingForMa,
    required this.organicIndiaDefaults,
    required this.organicIndiaFallback,
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
    return BillingRulesSnapshot(
      mergingForJa: mergingForJa,
      mergingForMa: mergingForMa,
      organicIndiaDefaults: oiMap,
      organicIndiaFallback: fallback,
    );
  }

  /// Force the next read to refetch. Call after a rule write from the UI.
  void invalidate() {
    _cache = null;
    _loadedAt = null;
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
