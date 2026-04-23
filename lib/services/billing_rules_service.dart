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

import 'package:flutter/foundation.dart';
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
  BillingRulesService._();
  static final BillingRulesService instance = BillingRulesService._();

  static const Duration _cacheTtl = Duration(minutes: 5);

  Map<String, dynamic>? _cache;
  DateTime? _loadedAt;

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
