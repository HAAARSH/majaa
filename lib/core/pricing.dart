// CSDS (Customer Discount Schemes) pricing cascade.
//
// Verified from Y206 ITTR06 (58,596 real invoice lines):
//   taxable = ORIGRATE × qty × (1 − D1/100) × (1 − D2/100) × (1 − D3/100) × (1 − D4/100) × (1 − D5/100)
// CSDS rules only carry DISCPER (D1), DISCPER3 (D3), DISCPER5 (D5) and
// SCHEMEPER (free-goods %). D2 and D4 are invoice-level rolling discounts
// (trade allowance, other-amount) applied at bill-level in DUA — not per
// customer-brand rule. Included as optional overrides only.
//
// Feature-flagged OFF by default (see [CsdsPricing.enabled]). Flip per team
// when ready to ship Tier 4 pricing in production.

import 'package:flutter/foundation.dart';
import '../services/supabase_service.dart';
import '../services/auth_service.dart';

/// Result of applying a CSDS cascade to one order line.
@immutable
class CsdsPriceBreakdown {
  /// Per-unit rate before any discount.
  final double baseRate;

  /// The customer-specific discount rule applied (null if no rule matched).
  final CsdsRule? rule;

  /// Ordered qty (paid).
  final int paidQty;

  /// Free qty shipped on top (from SCHEMEPER), rounded to nearest int.
  final int freeQty;

  /// Taxable amount = baseRate × paidQty × (1 − D1) × (1 − D3) × (1 − D5).
  final double taxable;

  /// Effective per-unit rate after all discounts (taxable / paidQty).
  final double netRate;

  /// Tax amount on taxable (VATPER + SATPER + CESSPER from ITEM, or
  /// vat_per_override from CSDS rule if present).
  final double tax;

  /// Final line amount = taxable + tax.
  final double lineTotal;

  const CsdsPriceBreakdown({
    required this.baseRate,
    required this.rule,
    required this.paidQty,
    required this.freeQty,
    required this.taxable,
    required this.netRate,
    required this.tax,
    required this.lineTotal,
  });

  /// Human-readable breakdown for a rep-facing UI.
  String describeTo() {
    if (rule == null || (rule!.discPer == 0 && rule!.discPer3 == 0 && rule!.discPer5 == 0 && rule!.schemePer == 0)) {
      return 'Rate ${baseRate.toStringAsFixed(2)} × $paidQty = ${taxable.toStringAsFixed(2)}';
    }
    final parts = <String>['Rate ${baseRate.toStringAsFixed(2)}', '× $paidQty'];
    if (rule!.discPer > 0) parts.add('−${rule!.discPer.toStringAsFixed(1)}%');
    if (rule!.discPer3 > 0) parts.add('−${rule!.discPer3.toStringAsFixed(1)}%');
    if (rule!.discPer5 > 0) parts.add('−${rule!.discPer5.toStringAsFixed(1)}%');
    var line = '${parts.join(' ')} = ${taxable.toStringAsFixed(2)}';
    if (freeQty > 0) line = '$line  + $freeQty FREE';
    return line;
  }
}

/// A single CSDS rule row from Supabase.
@immutable
class CsdsRule {
  final String customerId;
  final String teamId;
  final String company;
  final String itemGroup; // '' = company-wide
  final double schemePer;
  final double discPer;
  final double discPer3;
  final double discPer5;
  final double? vatPerOverride;

  const CsdsRule({
    required this.customerId,
    required this.teamId,
    required this.company,
    required this.itemGroup,
    required this.schemePer,
    required this.discPer,
    required this.discPer3,
    required this.discPer5,
    this.vatPerOverride,
  });

  factory CsdsRule.fromJson(Map<String, dynamic> j) => CsdsRule(
        customerId: j['customer_id'] as String,
        teamId: j['team_id'] as String,
        company: (j['company'] as String?) ?? '',
        itemGroup: (j['item_group'] as String?) ?? '',
        schemePer: (j['scheme_per'] as num?)?.toDouble() ?? 0,
        discPer: (j['disc_per'] as num?)?.toDouble() ?? 0,
        discPer3: (j['disc_per_3'] as num?)?.toDouble() ?? 0,
        discPer5: (j['disc_per_5'] as num?)?.toDouble() ?? 0,
        vatPerOverride: (j['vat_per_override'] as num?)?.toDouble(),
      );
}

class CsdsPricing {
  CsdsPricing._();

  /// Master on/off switch. When false, [priceFor] returns a breakdown with
  /// no discount applied (just baseRate × qty). Flip to true per-team after
  /// smoke-testing. Default false — safer for production.
  static bool enabled = false;

  /// In-memory cache of rules keyed by team. Populated on first load; refresh
  /// after each Drive sync by calling [invalidateCache].
  static final Map<String, List<CsdsRule>> _rulesByTeam = {};

  /// Clear cached rules (call after `syncCustomerDiscountSchemesFromDrive`).
  static void invalidateCache() {
    _rulesByTeam.clear();
  }

  /// Load rules for a team (cached).
  static Future<List<CsdsRule>> _rulesFor(String teamId) async {
    if (_rulesByTeam.containsKey(teamId)) return _rulesByTeam[teamId]!;
    final rows = await SupabaseService.instance.client
        .from('customer_discount_schemes')
        .select()
        .eq('team_id', teamId);
    final list = (rows as List)
        .map((r) => CsdsRule.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();
    _rulesByTeam[teamId] = list;
    return list;
  }

  /// Pick the most-specific rule for (customer, company, item_group).
  /// Match priority: exact itemGroup → company-wide (itemGroup='') → none.
  static CsdsRule? _pickRule(
    List<CsdsRule> rules, {
    required String customerId,
    required String company,
    required String itemGroup,
  }) {
    final companyU = company.toUpperCase();
    final itemGroupU = itemGroup.toUpperCase();
    CsdsRule? best;
    int bestSpecificity = -1;
    for (final r in rules) {
      if (r.customerId != customerId) continue;
      if (r.company.toUpperCase() != companyU) continue;
      final rGroupU = r.itemGroup.toUpperCase();
      int s;
      if (rGroupU == itemGroupU) {
        s = 2; // exact item-group match
      } else if (rGroupU.isEmpty) {
        s = 1; // company-wide
      } else {
        continue; // different item-group, not a match
      }
      if (s > bestSpecificity) {
        bestSpecificity = s;
        best = r;
      }
    }
    return best;
  }

  /// Compute final price for one order line.
  ///
  /// [baseRate] = pre-discount per-unit rate (from `products.unit_price` or
  /// ITMRP.RATE).
  /// [taxPercent] = VATPER + SATPER + CESSPER (from ITEM07). Pass 0 to skip
  /// tax computation.
  /// [customerId] = Supabase customers.id.
  /// [company] / [itemGroup] = from ITEM07 / products.company and
  /// products.item_group (future column — for now pass empty string to
  /// match company-wide rules only).
  static Future<CsdsPriceBreakdown> priceFor({
    required double baseRate,
    required int qty,
    required double taxPercent,
    required String customerId,
    required String company,
    String itemGroup = '',
    String? teamId,
  }) async {
    final t = teamId ?? AuthService.currentTeam;
    // Feature flag — bypass cascade entirely.
    if (!enabled || qty <= 0 || baseRate <= 0) {
      final taxable = baseRate * qty;
      final tax = taxable * taxPercent / 100.0;
      return CsdsPriceBreakdown(
        baseRate: baseRate,
        rule: null,
        paidQty: qty,
        freeQty: 0,
        taxable: taxable,
        netRate: baseRate,
        tax: tax,
        lineTotal: taxable + tax,
      );
    }
    final rules = await _rulesFor(t);
    final rule = _pickRule(
      rules,
      customerId: customerId,
      company: company,
      itemGroup: itemGroup,
    );
    final d1 = rule?.discPer ?? 0;
    final d3 = rule?.discPer3 ?? 0;
    final d5 = rule?.discPer5 ?? 0;
    final sch = rule?.schemePer ?? 0;
    // Multiplicative cascade (verified against Y206 ITTR real lines).
    final taxable = baseRate *
        qty *
        (1 - d1 / 100.0) *
        (1 - d3 / 100.0) *
        (1 - d5 / 100.0);
    final netRate = qty > 0 ? taxable / qty : baseRate;
    final vat = rule?.vatPerOverride ?? taxPercent;
    final tax = taxable * vat / 100.0;
    final freeQty = (qty * sch / 100.0).round();
    return CsdsPriceBreakdown(
      baseRate: baseRate,
      rule: rule,
      paidQty: qty,
      freeQty: freeQty,
      taxable: taxable,
      netRate: netRate,
      tax: tax,
      lineTotal: taxable + tax,
    );
  }
}
