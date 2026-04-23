import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/pricing.dart';
import '../../../theme/app_theme.dart';

/// Catalog → Pricing sub-tab. Per-team CSDS (customer discount schemes)
/// feature-flag toggle. Moved here from Settings → Pricing on 2026-04-22
/// so pricing behaviour lives beside Products in the catalog section.
///
/// When `CsdsPricing.kForcedOff` is true the switches are disabled + a
/// banner explains why. Flip the constant in `lib/core/pricing.dart` to
/// resume per-team control.
class AdminPricingTab extends StatefulWidget {
  const AdminPricingTab({super.key});

  @override
  State<AdminPricingTab> createState() => _AdminPricingTabState();
}

class _AdminPricingTabState extends State<AdminPricingTab> {
  bool _ja = false;
  bool _ma = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _ja = prefs.getBool('csds_enabled_JA') ?? false;
      _ma = prefs.getBool('csds_enabled_MA') ?? false;
      _loading = false;
    });
  }

  Future<void> _set(String team, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('csds_enabled_$team', value);
    if (!mounted) return;
    setState(() {
      if (team == 'JA') _ja = value;
      if (team == 'MA') _ma = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Pricing',
            style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.onSurface)),
        const SizedBox(height: 6),
        Text(
          'Controls how order line totals are calculated.',
          style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        _buildCsdsCard(),
      ],
    );
  }

  Widget _buildCsdsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.discount_rounded, size: 18, color: AppTheme.primary),
            const SizedBox(width: 8),
            Text('Customer Discount Schemes (CSDS)',
                style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 14)),
          ]),
          const SizedBox(height: 8),
          Text(
            "When ON, orders apply each customer's DUA-synced discount cascade (D1→D3→D5) + scheme free-goods. Leave OFF until rep-price parity with DUA is verified.",
            style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
          ),
          if (CsdsPricing.kForcedOff) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(children: [
                Icon(Icons.lock_rounded, size: 16, color: Colors.red.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'CSDS is hard-disabled in code (kForcedOff = true). '
                    'Per-team switches below are disabled and have no effect. '
                    'Flip the constant in lib/core/pricing.dart when ready to resume.',
                    style: GoogleFonts.manrope(
                        fontSize: 11, fontWeight: FontWeight.w600, color: Colors.red.shade900),
                  ),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('JA (Jagannath) — apply CSDS',
                  style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: Text(
                CsdsPricing.kForcedOff
                    ? 'Kill-switch ON — ignored'
                    : (_ja ? 'ON — cascade applied on order' : 'OFF — base rate × qty only'),
                style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
              ),
              value: CsdsPricing.kForcedOff ? false : _ja,
              onChanged: CsdsPricing.kForcedOff ? null : (v) => _set('JA', v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('MA (Madhav) — apply CSDS',
                  style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: Text(
                CsdsPricing.kForcedOff
                    ? 'Kill-switch ON — ignored'
                    : (_ma ? 'ON — cascade applied on order' : 'OFF — base rate × qty only'),
                style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
              ),
              value: CsdsPricing.kForcedOff ? false : _ma,
              onChanged: CsdsPricing.kForcedOff ? null : (v) => _set('MA', v),
            ),
          ],
        ],
      ),
    );
  }
}
