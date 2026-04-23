// Pure-math smoke tests for CsdsPricing cascade. No Supabase, no network —
// only the cascade + rule-pick logic so CI can run these in seconds.
//
// Golden numbers sourced from Y206 ITTR06 real invoice lines — these are
// the same values the multiplicative cascade formula was back-solved from.

import 'package:flutter_test/flutter_test.dart';
import 'package:fmcgorders/core/pricing.dart';

void main() {
  // Tiny tolerance for floating-point comparisons.
  const eps = 0.005;

  group('computeBreakdown — no rule', () {
    test('zero rule → base rate × qty, no discount', () {
      final b = CsdsPricing.computeBreakdown(
        baseRate: 100.0,
        qty: 10,
        taxPercent: 18,
        rule: null,
      );
      expect(b.taxable, closeTo(1000.0, eps));
      expect(b.netRate, closeTo(100.0, eps));
      expect(b.tax, closeTo(180.0, eps));
      expect(b.lineTotal, closeTo(1180.0, eps));
      expect(b.freeQty, 0);
      expect(b.paidQty, 10);
    });

    test('zero qty → zero taxable, zero tax', () {
      final b = CsdsPricing.computeBreakdown(
        baseRate: 100.0,
        qty: 0,
        taxPercent: 18,
        rule: null,
      );
      expect(b.taxable, 0);
      expect(b.tax, 0);
      expect(b.lineTotal, 0);
    });

    test('zero base rate → zero taxable', () {
      final b = CsdsPricing.computeBreakdown(
        baseRate: 0.0,
        qty: 10,
        taxPercent: 18,
        rule: null,
      );
      expect(b.taxable, 0);
      expect(b.lineTotal, 0);
    });
  });

  group('computeBreakdown — single-discount rule', () {
    test('D1 only: 846.61 × 40 × (1−25%) = 25,398.30', () {
      // Y206 real line: taxable with only D1 flag applied.
      final rule = _rule(discPer: 25);
      final b = CsdsPricing.computeBreakdown(
        baseRate: 846.61,
        qty: 40,
        taxPercent: 18,
        rule: rule,
      );
      expect(b.taxable, closeTo(25398.30, 0.05));
      expect(b.netRate, closeTo(634.9575, 0.01));
    });

    test('D3 only: 200 × 5 × (1−10%) = 900', () {
      final rule = _rule(discPer3: 10);
      final b = CsdsPricing.computeBreakdown(
        baseRate: 200.0,
        qty: 5,
        taxPercent: 0,
        rule: rule,
      );
      expect(b.taxable, closeTo(900.0, eps));
      expect(b.tax, 0);
      expect(b.lineTotal, closeTo(900.0, eps));
    });

    test('D5 only: 100 × 10 × (1−50%) = 500', () {
      final rule = _rule(discPer5: 50);
      final b = CsdsPricing.computeBreakdown(
        baseRate: 100.0,
        qty: 10,
        taxPercent: 0,
        rule: rule,
      );
      expect(b.taxable, closeTo(500.0, eps));
    });
  });

  group('computeBreakdown — stacked cascade', () {
    test('D1 × D3 × D5 is MULTIPLICATIVE, not additive', () {
      // 1000 × (1−10) × (1−10) × (1−10) = 1000 × 0.9 × 0.9 × 0.9 = 729
      // (Additive would give 1000 × 0.7 = 700 — wrong.)
      final rule = _rule(discPer: 10, discPer3: 10, discPer5: 10);
      final b = CsdsPricing.computeBreakdown(
        baseRate: 1000.0,
        qty: 1,
        taxPercent: 0,
        rule: rule,
      );
      expect(b.taxable, closeTo(729.0, eps));
      expect(b.taxable, isNot(closeTo(700.0, 1.0)));
    });

    test('D1=25, D3=50: 846.61 × 40 × 0.75 × 0.5 = 12,699.15 (Y206 gold)', () {
      // Cross-reference value from the code comment: "Rate 846.61 × 40 −25% −50% = 12699.15"
      final rule = _rule(discPer: 25, discPer5: 50);
      final b = CsdsPricing.computeBreakdown(
        baseRate: 846.61,
        qty: 40,
        taxPercent: 18,
        rule: rule,
      );
      expect(b.taxable, closeTo(12699.15, 0.05));
    });
  });

  group('computeBreakdown — scheme (free goods)', () {
    test('SCHEMEPER=20%: 10 paid → 2 free', () {
      final rule = _rule(schemePer: 20);
      final b = CsdsPricing.computeBreakdown(
        baseRate: 100.0,
        qty: 10,
        taxPercent: 0,
        rule: rule,
      );
      expect(b.paidQty, 10);
      expect(b.freeQty, 2);
      // Scheme does NOT reduce taxable — free goods are shipped separately.
      expect(b.taxable, closeTo(1000.0, eps));
    });

    test('SCHEMEPER rounds to nearest int (12 × 10% = 1.2 → 1 free)', () {
      final rule = _rule(schemePer: 10);
      final b = CsdsPricing.computeBreakdown(
        baseRate: 50.0,
        qty: 12,
        taxPercent: 0,
        rule: rule,
      );
      expect(b.freeQty, 1);
    });

    test('SCHEMEPER 8% × 13 → 1 free (not 0, not 2)', () {
      final rule = _rule(schemePer: 8);
      final b = CsdsPricing.computeBreakdown(
        baseRate: 50.0,
        qty: 13,
        taxPercent: 0,
        rule: rule,
      );
      expect(b.freeQty, 1);
    });
  });

  group('computeBreakdown — tax override', () {
    test('vat_per_override replaces taxPercent arg', () {
      final rule = _rule(vatPerOverride: 5);
      final b = CsdsPricing.computeBreakdown(
        baseRate: 100.0,
        qty: 10,
        taxPercent: 18, // should be overridden
        rule: rule,
      );
      expect(b.tax, closeTo(50.0, eps)); // 1000 × 5% = 50, not 180
    });

    test('null override → taxPercent argument is used', () {
      final rule = _rule(discPer: 10); // no vat override
      final b = CsdsPricing.computeBreakdown(
        baseRate: 100.0,
        qty: 10,
        taxPercent: 18,
        rule: rule,
      );
      expect(b.tax, closeTo(162.0, eps)); // 900 × 18% = 162
    });
  });

  group('pickRule — specificity order', () {
    final customer = 'CUST-1';
    final companyWide = CsdsRule(
      customerId: customer,
      teamId: 'JA',
      company: 'GOYAL',
      itemGroup: '',
      schemePer: 0,
      discPer: 10,
      discPer3: 0,
      discPer5: 0,
    );
    final itemGroupSpecific = CsdsRule(
      customerId: customer,
      teamId: 'JA',
      company: 'GOYAL',
      itemGroup: 'LAFZ',
      schemePer: 0,
      discPer: 0, // ← the "zero-override" case
      discPer3: 0,
      discPer5: 0,
    );
    final otherCustomer = CsdsRule(
      customerId: 'CUST-2',
      teamId: 'JA',
      company: 'GOYAL',
      itemGroup: '',
      schemePer: 0,
      discPer: 50,
      discPer3: 0,
      discPer5: 0,
    );
    final rules = [companyWide, itemGroupSpecific, otherCustomer];

    test('item-group-specific rule wins over company-wide', () {
      final picked = CsdsPricing.pickRule(
        rules,
        customerId: customer,
        company: 'GOYAL',
        itemGroup: 'LAFZ',
      );
      expect(picked, isNotNull);
      expect(picked!.itemGroup, 'LAFZ');
      expect(picked.discPer, 0);
    });

    test('company-wide applies when no item-group match', () {
      final picked = CsdsPricing.pickRule(
        rules,
        customerId: customer,
        company: 'GOYAL',
        itemGroup: 'COLOR',
      );
      expect(picked?.itemGroup, '');
      expect(picked?.discPer, 10);
    });

    test('customer scope is respected', () {
      final picked = CsdsPricing.pickRule(
        rules,
        customerId: 'CUST-2',
        company: 'GOYAL',
        itemGroup: '',
      );
      expect(picked?.discPer, 50);
    });

    test('no rule matches → null', () {
      final picked = CsdsPricing.pickRule(
        rules,
        customerId: customer,
        company: 'UNKNOWN',
        itemGroup: '',
      );
      expect(picked, isNull);
    });

    test('case-insensitive company + itemGroup match', () {
      final picked = CsdsPricing.pickRule(
        rules,
        customerId: customer,
        company: 'goyal',
        itemGroup: 'lafz',
      );
      expect(picked?.itemGroup, 'LAFZ');
    });
  });

  group('zero-override integration', () {
    // This reproduces the bug the sync-time fix addresses: an explicit
    // item-group zero row must not fall through to a company-wide rule.
    test('zero item-group rule overrides company-wide discount', () {
      final rules = [
        CsdsRule(
          customerId: 'C1',
          teamId: 'JA',
          company: 'GOYAL',
          itemGroup: '',
          schemePer: 0,
          discPer: 10,
          discPer3: 0,
          discPer5: 0,
        ),
        CsdsRule(
          customerId: 'C1',
          teamId: 'JA',
          company: 'GOYAL',
          itemGroup: 'LAFZ',
          schemePer: 0,
          discPer: 0,
          discPer3: 0,
          discPer5: 0,
        ),
      ];
      final lafzRule = CsdsPricing.pickRule(
        rules,
        customerId: 'C1',
        company: 'GOYAL',
        itemGroup: 'LAFZ',
      );
      final lafzBreakdown = CsdsPricing.computeBreakdown(
        baseRate: 100,
        qty: 10,
        taxPercent: 0,
        rule: lafzRule,
      );
      // LAFZ must NOT get the 10% company-wide discount.
      expect(lafzBreakdown.taxable, closeTo(1000, eps));

      final otherRule = CsdsPricing.pickRule(
        rules,
        customerId: 'C1',
        company: 'GOYAL',
        itemGroup: 'COLOR',
      );
      final otherBreakdown = CsdsPricing.computeBreakdown(
        baseRate: 100,
        qty: 10,
        taxPercent: 0,
        rule: otherRule,
      );
      // Non-LAFZ should still get the 10% company-wide.
      expect(otherBreakdown.taxable, closeTo(900, eps));
    });
  });
}

CsdsRule _rule({
  String customerId = 'C1',
  String teamId = 'JA',
  String company = 'GOYAL',
  String itemGroup = '',
  double schemePer = 0,
  double discPer = 0,
  double discPer3 = 0,
  double discPer5 = 0,
  double? vatPerOverride,
}) =>
    CsdsRule(
      customerId: customerId,
      teamId: teamId,
      company: company,
      itemGroup: itemGroup,
      schemePer: schemePer,
      discPer: discPer,
      discPer3: discPer3,
      discPer5: discPer5,
      vatPerOverride: vatPerOverride,
    );
