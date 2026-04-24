import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sizer/sizer.dart';

import '../../../core/pricing.dart';
import '../../../core/search_utils.dart';
import '../../../services/billing_rules_service.dart';
import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/empty_state_widget.dart';

/// Centralized rules tab. Reads from `billing_rules`, writes via direct
/// UPSERT (the trigger logs every change to `billing_rules_audit_log`).
/// Super-admin can edit; everyone else gets read-only cards.
///
/// Reason text is optional v1. After save the most recent audit row for
/// the touched (rule_key, scope_type, scope_id) gets `change_reason`
/// patched in. Race condition window is small (single admin per rule)
/// and acceptable for now; mandatory-reason via RPC is a follow-up.
class AdminRulesTab extends StatefulWidget {
  final bool isSuperAdmin;
  const AdminRulesTab({super.key, this.isSuperAdmin = false});

  @override
  State<AdminRulesTab> createState() => _AdminRulesTabState();
}

class _AdminRulesTabState extends State<AdminRulesTab>
    with SingleTickerProviderStateMixin {
  final _client = SupabaseService.instance.client;
  late TabController _tabs;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rules = [];

  static const _categories = ['export', 'routing', 'pricing', 'customer'];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _categories.length, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _client
          .from('billing_rules')
          .select()
          .order('category')
          .order('rule_key')
          .order('scope_id');
      if (!mounted) return;
      setState(() {
        _rules = (rows as List)
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _saveRule({
    required Map<String, dynamic> rule,
    required dynamic newValue,
    String? reason,
  }) async {
    try {
      await _client.from('billing_rules').update({
        'value': newValue,
        'last_edited_at': DateTime.now().toIso8601String(),
      }).eq('id', rule['id']);

      // Best-effort: stamp the reason onto the audit row the trigger just
      // wrote. Targeted by (rule_id, change_type='update', NULL reason),
      // most recent. Race against concurrent edits is acceptable v1.
      if (reason != null && reason.trim().isNotEmpty) {
        try {
          await _client
              .from('billing_rules_audit_log')
              .update({'change_reason': reason.trim()})
              .eq('rule_id', rule['id'])
              .filter('change_reason', 'is', null)
              .order('changed_at', ascending: false)
              .limit(1);
        } catch (_) {/* non-fatal */}
      }

      BillingRulesService.instance.invalidate();
      if (!mounted) return;
      Fluttertoast.showToast(
        msg: 'Rule updated. Takes effect on next operation.',
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      Fluttertoast.showToast(
        msg: 'Save failed (super_admin required): $e',
        toastLength: Toast.LENGTH_LONG,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _buildError();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text('Business Rules',
                    style: GoogleFonts.manrope(
                        fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              TextButton.icon(
                onPressed: _showAuditLog,
                icon: const Icon(Icons.history_rounded, size: 16),
                label: Text('Audit log',
                    style: GoogleFonts.manrope(
                        fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
        // Migration-applied sanity banner. BillingRulesService._reload()
        // silently swallows DB errors and returns an empty cache, so a
        // missing migration would let the Rules Tab open normally — but
        // every save below would no-op at the RLS/table level. This
        // banner turns that silent failure into an obvious one.
        if (_rules.isEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade300),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 20, color: Colors.red.shade800),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Rules table is empty',
                          style: GoogleFonts.manrope(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: Colors.red.shade900)),
                      const SizedBox(height: 4),
                      Text(
                        'Migrations 20260423000003_billing_rules.sql and '
                        '20260423000004_billing_rules_seed.sql have not '
                        'been applied to this Supabase database. Edits '
                        'made here will not persist.\n\n'
                        'Ask the developer to run them in Supabase SQL '
                        'Editor (in order), then pull-to-refresh this tab.',
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          color: Colors.red.shade900,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        TabBar(
          controller: _tabs,
          isScrollable: true,
          labelStyle:
              GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700),
          tabs: _categories
              .map((c) => Tab(text: c[0].toUpperCase() + c.substring(1)))
              .toList(),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: _categories.map(_buildCategoryView).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 48),
          const SizedBox(height: 8),
          Text('Failed to load rules',
              style: GoogleFonts.manrope(
                  fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(_error ?? '',
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(
                    fontSize: 11, color: AppTheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryView(String category) {
    final inCategory = _rules.where((r) => r['category'] == category).toList();
    if (inCategory.isEmpty) {
      return ListView(children: const [
        SizedBox(height: 80),
        EmptyStateWidget(
          title: 'No rules yet',
          description: 'Rules in this category will appear here.',
          icon: Icons.rule_rounded,
        ),
      ]);
    }
    // Pricing category gets a contextual header — migrated from the old
    // admin_pricing_tab.dart (now removed). Shows the CSDS kill-switch
    // banner when kForcedOff is true AND a short "what are these" blurb.
    final headers = <Widget>[];
    if (category == 'pricing') {
      headers.add(_buildPricingHeader());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: headers.length + inCategory.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => i < headers.length
            ? headers[i]
            : _buildRuleCard(inCategory[i - headers.length]),
      ),
    );
  }

  /// Header for the Pricing category — CSDS explanation + kForcedOff
  /// warning banner. Ported from admin_pricing_tab.dart so admins don't
  /// lose this context when Pricing tab was removed in favour of this
  /// centralised Rules Tab.
  Widget _buildPricingHeader() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.discount_rounded, size: 18, color: AppTheme.primary),
            const SizedBox(width: 8),
            Text('Customer-Specific Discounts (CSDS)',
                style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 13)),
          ]),
          const SizedBox(height: 6),
          Text(
            "When ON, orders apply each customer's DUA-synced discount cascade "
            "(D1→D3→D5) plus scheme free-goods. Leave OFF until rep-price "
            "parity with DUA is verified on a test order.",
            style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant, height: 1.35),
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
                    'The switches below have no effect until the constant '
                    'is flipped in lib/core/pricing.dart and '
                    'majaa_desktop/lib/core/pricing.dart.',
                    style: GoogleFonts.manrope(
                        fontSize: 11, fontWeight: FontWeight.w600, color: Colors.red.shade900),
                  ),
                ),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRuleCard(Map<String, dynamic> rule) {
    final ruleKey = rule['rule_key'] as String;
    final scopeType = rule['scope_type'] as String;
    final scopeId = rule['scope_id'] as String?;
    final value = rule['value'];
    final description = rule['description'] as String? ?? '';
    final lastEditedAt = DateTime.tryParse(rule['last_edited_at']?.toString() ?? '');
    final lastEditedBy = rule['last_edited_by_user_id']?.toString();

    final scopeLabel = scopeId == null ? 'global' : '$scopeType: $scopeId';
    final title = _humanRuleKey(ruleKey);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconFor(rule['category'] as String),
                  size: 18, color: AppTheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('$title  ·  $scopeLabel',
                    style: GoogleFonts.manrope(
                        fontSize: 13, fontWeight: FontWeight.w800)),
              ),
              if (widget.isSuperAdmin)
                TextButton.icon(
                  onPressed: () => _editRule(rule),
                  icon: const Icon(Icons.edit_rounded, size: 14),
                  label: Text('Edit',
                      style: GoogleFonts.manrope(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(_formatValue(value),
              style: GoogleFonts.manrope(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primary)),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(description,
                style: GoogleFonts.manrope(
                    fontSize: 11,
                    color: AppTheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic)),
          ],
          // Expandable "Learn more" panel — pulls hardcoded copy keyed
          // by rule_key from _help. Collapsed by default; a small hint
          // on the tappable tile keeps it low-noise.
          if (_help.containsKey(ruleKey)) ...[
            const SizedBox(height: 6),
            Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
                listTileTheme: const ListTileThemeData(dense: true),
              ),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 6),
                leading: const Icon(Icons.info_outline_rounded, size: 16),
                title: Text('Learn more',
                    style: GoogleFonts.manrope(
                        fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                children: [_buildHelpPanel(_help[ruleKey]!)],
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            lastEditedAt != null
                ? 'Last edited ${_relativeTime(lastEditedAt)}'
                  '${lastEditedBy != null ? ' by an admin' : ' (seed)'}'
                : 'Never edited',
            style: GoogleFonts.manrope(
                fontSize: 10,
                color: AppTheme.onSurfaceVariant,
                fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpPanel(_RuleHelp help) {
    TextStyle head() => GoogleFonts.manrope(
        fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.4,
        color: AppTheme.primary);
    TextStyle body() => GoogleFonts.manrope(
        fontSize: 11, color: AppTheme.onSurface, height: 1.4);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('WHAT IT DOES', style: head()),
          const SizedBox(height: 2),
          Text(help.what, style: body()),
          const SizedBox(height: 8),
          Text('WHERE IT\'S USED', style: head()),
          const SizedBox(height: 2),
          Text(help.where, style: body()),
          const SizedBox(height: 8),
          Text('EXAMPLE', style: head()),
          const SizedBox(height: 2),
          Text(help.example, style: body()),
        ],
      ),
    );
  }

  IconData _iconFor(String category) {
    switch (category) {
      case 'export':
        return Icons.upload_file_rounded;
      case 'routing':
        return Icons.alt_route_rounded;
      case 'pricing':
        return Icons.discount_rounded;
      case 'customer':
        return Icons.person_outline_rounded;
      default:
        return Icons.rule_rounded;
    }
  }

  String _humanRuleKey(String key) {
    return key
        .split('_')
        .map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  String _formatValue(dynamic value) {
    if (value is bool) return value ? 'ON' : 'OFF';
    if (value is String) return _humanRuleKey(value);
    if (value is Map) {
      return value.entries.map((e) => '${e.key} → ${e.value}').join(', ');
    }
    if (value is List) {
      return value.isEmpty ? '(empty — rule disabled)' : '${value.length} item(s)';
    }
    if (value is num) {
      return value == 0 ? '0  (disabled)' : value.toString();
    }
    return value?.toString() ?? '—';
  }

  /// Per-rule help copy. Shown inside the expandable "Learn more" panel
  /// on every rule card. Hardcoded here (not in the DB) so we can evolve
  /// the docs without a migration.
  static const Map<String, _RuleHelp> _help = {
    'export_merging_strategy': _RuleHelp(
      what: 'How orders are grouped into invoices when you export the CSV.',
      where: 'Export button on the Orders tab. Applied per team, so JA and MA can use different strategies.',
      example: 'split_by_rep_role = brand_rep orders merge per customer; sales_rep orders stay one-per-order.\n'
          'merge_all_by_customer = EVERY order for a customer collapses into one invoice.\n'
          'no_merge = every order is its own invoice regardless of rep.',
    ),
    'pricing_csds_enabled': _RuleHelp(
      what: 'Switch to apply the DUA customer-specific discount cascade (D1 → D3 → D5) + scheme free-goods on order save.',
      where: 'Every order-creation path (rep and admin). Read once at order-start, cached for that session.',
      example: 'Off → rep sees MRP × qty. On → rep sees MRP × qty minus each discount layer, plus any free goods the scheme adds.',
    ),
    'organic_india_default_by_customer_type': _RuleHelp(
      what: 'Default billing team for Organic India items based on the customer''s type (Pharmacy, General Trade, etc.).',
      where: 'Organic India picker dialog during CSV export. Admin can still override per customer row.',
      example: '{"pharmacy": "JA", "_default": "MA"} — pharmacies default to JA, everyone else MA.',
    ),
    'stock_zero_grace_days': _RuleHelp(
      what: 'Days a product stays billable by reps after stock first hits zero.',
      where: 'Rep product list + detail screen. Admin products tab shows "in grace" vs "out" counts.',
      example: '2 → 2-day grace (default). 0 → reps locked immediately on zero. 5 → week-long cushion.',
    ),
    'no_merge_customer_ids': _RuleHelp(
      what: 'Customer IDs that must NEVER merge into a combined brand_rep invoice at export. Their orders stay one-invoice-per-order.',
      where: 'Export CSV build on the Orders tab. Applied per team.',
      example: '["cust-001", "cust-042"] — those two customers always get one invoice per order even if mergingStrategy says "merge_all".',
    ),
    'auto_block_overdue_days': _RuleHelp(
      what: 'Auto-block new orders when a customer''s oldest unpaid bill is older than N days.',
      where: 'Order creation (rep flow and admin Manual tab). Block is checked at save-click.',
      example: '30 → customer with a 31-day-old unpaid bill is blocked with reason "oldest unpaid bill exceeds 30-day threshold". 0 = disabled.',
    ),
    'auto_block_outstanding': _RuleHelp(
      what: 'Auto-block new orders when a customer''s outstanding balance exceeds this rupee amount.',
      where: 'Order creation (rep flow and admin Manual tab). Block is checked at save-click.',
      example: '50000 → customer with ₹51,200 outstanding is blocked. 0 = disabled.',
    ),
  };

  String _relativeTime(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${(diff.inDays / 30).floor()}mo ago';
  }

  // ── Edit dialogs ──────────────────────────────────────────────────────

  Future<void> _editRule(Map<String, dynamic> rule) async {
    final value = rule['value'];
    if (value is bool) {
      await _editBool(rule);
    } else if (value is String && rule['rule_key'] == 'export_merging_strategy') {
      await _editMergingStrategy(rule);
    } else if (value is Map) {
      await _editMap(rule);
    } else if (value is num) {
      await _editNumber(rule);
    } else if (value is List) {
      await _editStringList(rule);
    } else {
      Fluttertoast.showToast(
        msg: 'Editing this rule type is not supported in the UI yet.',
        toastLength: Toast.LENGTH_LONG,
      );
    }
  }

  /// Number editor. Used by auto_block_overdue_days (int) and
  /// auto_block_outstanding (any num). Writes back as a JSON number.
  Future<void> _editNumber(Map<String, dynamic> rule) async {
    final current = (rule['value'] as num).toString();
    final valueCtrl = TextEditingController(text: current);
    final reasonCtrl = TextEditingController();
    final result = await showDialog<num>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit ${_humanRuleKey(rule['rule_key'] as String)}',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (rule['description'] != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(rule['description'] as String,
                    style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
              ),
            TextField(
              controller: valueCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Value (0 disables the rule)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: reasonCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Reason (optional, stored in audit log)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final parsed = num.tryParse(valueCtrl.text.trim());
              if (parsed == null) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Not a number')),
                );
                return;
              }
              if (parsed < 0) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Value must be ≥ 0')),
                );
                return;
              }
              Navigator.pop(ctx, parsed);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final json = result is int ? result : (result == result.toInt() ? result.toInt() : result);
    await _saveRule(
        rule: rule, newValue: json, reason: reasonCtrl.text);
  }

  /// Editor for a JSON string list — today used only for
  /// no_merge_customer_ids. Full-screen-ish Dialog: scrollable chip wrap
  /// for current selections on top, tokenized search + full paginated
  /// roster below with tap-to-toggle.
  Future<void> _editStringList(Map<String, dynamic> rule) async {
    final current = List<String>.from(
        (rule['value'] as List).map((e) => e.toString()));
    final scopeTeam = rule['scope_id']?.toString();
    final reasonCtrl = TextEditingController();
    final pickerCtrl = TextEditingController();

    List<CustomerModel> roster;
    try {
      final all = await SupabaseService.instance.getCustomers();
      roster = scopeTeam == null
          ? all.toList()
          : all.where((c) => c.belongsToTeam(scopeTeam)).toList();
      roster.sort((a, b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } catch (e) {
      roster = const [];
    }
    if (!mounted) return;

    String nameFor(String id) {
      final hit = roster.firstWhere(
        (c) => c.id == id,
        orElse: () => const CustomerModel(
            id: '', name: '', address: '', phone: '',
            type: '', lastOrderValue: 0),
      );
      return hit.name.isEmpty ? id : hit.name;
    }

    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final query = pickerCtrl.text.trim();
          final matches = query.isEmpty
              ? roster
              : roster
                  .where((c) => tokenMatch(query, [c.name, c.phone, c.id]))
                  .toList();

          void toggle(String id) {
            setS(() {
              if (current.contains(id)) {
                current.remove(id);
              } else {
                current.add(id);
              }
            });
          }

          return Dialog(
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 600, maxHeight: 80.h),
              child: SizedBox(
                width: 90.w,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Edit ${_humanRuleKey(rule['rule_key'] as String)}'
                        '${scopeTeam != null ? " · $scopeTeam" : ""}',
                        style: GoogleFonts.manrope(
                            fontSize: 14, fontWeight: FontWeight.w800),
                      ),
                      if (rule['description'] != null) ...[
                        const SizedBox(height: 6),
                        Text(rule['description'] as String,
                            style: GoogleFonts.manrope(
                                fontSize: 11,
                                color: AppTheme.onSurfaceVariant)),
                      ],
                      const SizedBox(height: 12),
                      Text('Current list (${current.length}):',
                          style: GoogleFonts.manrope(
                              fontSize: 11, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      if (current.isEmpty)
                        Text('(empty — no customers excluded from merge)',
                            style: GoogleFonts.manrope(
                                fontSize: 11,
                                color: AppTheme.onSurfaceVariant,
                                fontStyle: FontStyle.italic))
                      else
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 96),
                          child: SingleChildScrollView(
                            child: Wrap(spacing: 6, runSpacing: 6, children: [
                              for (final id in current)
                                InputChip(
                                  label: Text(
                                    nameFor(id),
                                    style:
                                        GoogleFonts.manrope(fontSize: 11),
                                  ),
                                  onDeleted: () =>
                                      setS(() => current.remove(id)),
                                ),
                            ]),
                          ),
                        ),
                      const Divider(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: Text('Tap to add or remove',
                                style: GoogleFonts.manrope(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700)),
                          ),
                          Text(
                            'Showing ${matches.length} of ${roster.length} · ${current.length} selected',
                            style: GoogleFonts.manrope(
                                fontSize: 10,
                                color: AppTheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: pickerCtrl,
                        onChanged: (_) => setS(() {}),
                        decoration: InputDecoration(
                          hintText: 'Search name / phone / id',
                          prefixIcon:
                              const Icon(Icons.search_rounded, size: 16),
                          suffixIcon: query.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close_rounded,
                                      size: 16),
                                  onPressed: () {
                                    pickerCtrl.clear();
                                    setS(() {});
                                  },
                                ),
                          isDense: true,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Expanded(
                        child: roster.isEmpty
                            ? Center(
                                child: Text(
                                  scopeTeam == null
                                      ? 'No customers found.'
                                      : 'No customers on team $scopeTeam.',
                                  style: GoogleFonts.manrope(
                                      fontSize: 11,
                                      color: AppTheme.onSurfaceVariant),
                                ),
                              )
                            : matches.isEmpty
                                ? Center(
                                    child: Text('No matches for "$query"',
                                        style: GoogleFonts.manrope(
                                            fontSize: 11,
                                            color:
                                                AppTheme.onSurfaceVariant)),
                                  )
                                : Scrollbar(
                                    child: ListView.builder(
                                      itemCount: matches.length,
                                      itemBuilder: (_, i) {
                                        final c = matches[i];
                                        final selected =
                                            current.contains(c.id);
                                        return ListTile(
                                          dense: true,
                                          title: Text(c.name,
                                              style: GoogleFonts.manrope(
                                                  fontSize: 12)),
                                          subtitle: Text(
                                              '${c.phone}  ·  ${c.id}',
                                              style: GoogleFonts.manrope(
                                                  fontSize: 10,
                                                  color: AppTheme
                                                      .onSurfaceVariant)),
                                          trailing: Icon(
                                            selected
                                                ? Icons.check_circle
                                                : Icons.add_circle_outline,
                                            color: selected
                                                ? Colors.green
                                                : null,
                                            size: 20,
                                          ),
                                          onTap: () => toggle(c.id),
                                        );
                                      },
                                    ),
                                  ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: reasonCtrl,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText:
                              'Reason (optional, stored in audit log)',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Cancel')),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, current),
                            child: const Text('Save'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    if (result == null) return;
    await _saveRule(rule: rule, newValue: result, reason: reasonCtrl.text);
  }

  Future<void> _editBool(Map<String, dynamic> rule) async {
    bool current = rule['value'] as bool;
    final reasonCtrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(_humanRuleKey(rule['rule_key'] as String),
              style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: current,
                onChanged: (v) => setS(() => current = v),
                title: Text(current ? 'ON' : 'OFF',
                    style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: reasonCtrl,
                decoration: InputDecoration(
                  labelText: 'Reason (optional)',
                  hintText: 'Why are you changing this?',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
                maxLines: 2,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, current),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result == null || result == rule['value']) return;
    await _saveRule(rule: rule, newValue: result, reason: reasonCtrl.text);
  }

  Future<void> _editMergingStrategy(Map<String, dynamic> rule) async {
    String current = rule['value'] as String;
    final reasonCtrl = TextEditingController();
    final options = const [
      ('split_by_rep_role', 'Split by rep role',
          'brand_rep merges per customer; sales_rep stays one-invoice-per-order.'),
      ('merge_all_by_customer', 'Merge all by customer',
          'Every order for a customer collapses into one invoice regardless of rep.'),
      ('no_merge', 'No merge',
          'One invoice per order. No merging at all.'),
    ];
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
              'Merging strategy — ${rule['scope_id'] ?? rule['scope_type']}',
              style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...options.map((o) => RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: o.$1,
                      groupValue: current,
                      onChanged: (v) {
                        if (v != null) setS(() => current = v);
                      },
                      title: Text(o.$2,
                          style: GoogleFonts.manrope(
                              fontSize: 13, fontWeight: FontWeight.w700)),
                      subtitle: Text(o.$3,
                          style: GoogleFonts.manrope(
                              fontSize: 11, color: AppTheme.onSurfaceVariant)),
                    )),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Row(children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 16, color: Colors.orange.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Affects the next CSV export. In-flight builds are not affected.',
                        style: GoogleFonts.manrope(
                            fontSize: 11, color: Colors.orange.shade900),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: reasonCtrl,
                  decoration: InputDecoration(
                    labelText: 'Reason (optional)',
                    border:
                        OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, current),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result == null || result == rule['value']) return;
    await _saveRule(rule: rule, newValue: result, reason: reasonCtrl.text);
  }

  Future<void> _editMap(Map<String, dynamic> rule) async {
    final original = Map<String, String>.from(
      (rule['value'] as Map).map((k, v) => MapEntry(k.toString(), v.toString())),
    );
    final edited = Map<String, String>.from(original);
    final reasonCtrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(_humanRuleKey(rule['rule_key'] as String),
              style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...edited.keys.map((k) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          Expanded(
                            flex: 2,
                            child: Text(k,
                                style: GoogleFonts.manrope(
                                    fontSize: 12, fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: DropdownButton<String>(
                              isExpanded: true,
                              value: edited[k],
                              items: const [
                                DropdownMenuItem(value: 'JA', child: Text('JA')),
                                DropdownMenuItem(value: 'MA', child: Text('MA')),
                              ],
                              onChanged: (v) {
                                if (v != null) setS(() => edited[k] = v);
                              },
                            ),
                          ),
                        ]),
                      )),
                  const SizedBox(height: 12),
                  TextField(
                    controller: reasonCtrl,
                    decoration: InputDecoration(
                      labelText: 'Reason (optional)',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    maxLines: 2,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result != true) return;
    if (_mapsEqual(edited, original)) return;
    await _saveRule(rule: rule, newValue: edited, reason: reasonCtrl.text);
  }

  bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (a[k] != b[k]) return false;
    }
    return true;
  }

  // ── Audit log drawer ───────────────────────────────────────────────────

  Future<void> _showAuditLog() async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scroll) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: _AuditLogView(scroll: scroll),
        ),
      ),
    );
  }
}

class _AuditLogView extends StatefulWidget {
  final ScrollController scroll;
  const _AuditLogView({required this.scroll});

  @override
  State<_AuditLogView> createState() => _AuditLogViewState();
}

class _AuditLogViewState extends State<_AuditLogView> {
  final _client = SupabaseService.instance.client;
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _client
          .from('billing_rules_audit_log')
          .select()
          .order('changed_at', ascending: false)
          .limit(50);
      if (!mounted) return;
      setState(() {
        _rows = (rows as List)
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(children: [
            const Icon(Icons.history_rounded, size: 18, color: AppTheme.primary),
            const SizedBox(width: 8),
            Text('Audit log (last 50)',
                style: GoogleFonts.manrope(
                    fontSize: 15, fontWeight: FontWeight.w800)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(_error!,
                            style: GoogleFonts.manrope(
                                fontSize: 12, color: Colors.red)),
                      ),
                    )
                  : _rows.isEmpty
                      ? const Center(child: Text('No changes yet'))
                      : ListView.separated(
                          controller: widget.scroll,
                          padding: const EdgeInsets.all(12),
                          itemCount: _rows.length,
                          separatorBuilder: (_, __) => const Divider(height: 12),
                          itemBuilder: (_, i) => _buildRow(_rows[i]),
                        ),
        ),
      ],
    );
  }

  Widget _buildRow(Map<String, dynamic> r) {
    final ruleKey = r['rule_key']?.toString() ?? '';
    final scopeType = r['scope_type']?.toString() ?? '';
    final scopeId = r['scope_id']?.toString();
    final changeType = r['change_type']?.toString() ?? '';
    final by = r['changed_by_name']?.toString() ?? '(system)';
    final when = DateTime.tryParse(r['changed_at']?.toString() ?? '');
    final reason = r['change_reason']?.toString();
    final oldV = r['old_value']?.toString() ?? '—';
    final newV = r['new_value']?.toString() ?? '—';

    final scopeLabel = scopeId == null ? 'global' : '$scopeType: $scopeId';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _typeColor(changeType).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(changeType.toUpperCase(),
                style: GoogleFonts.manrope(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: _typeColor(changeType))),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text('$ruleKey  ·  $scopeLabel',
                style: GoogleFonts.manrope(
                    fontSize: 12, fontWeight: FontWeight.w700)),
          ),
          if (when != null)
            Text(_relative(when),
                style: GoogleFonts.manrope(
                    fontSize: 10, color: AppTheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 4),
        Text('by $by',
            style: GoogleFonts.manrope(
                fontSize: 10, color: AppTheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text('$oldV → $newV',
            style: GoogleFonts.manrope(
                fontSize: 11, color: AppTheme.onSurface)),
        if (reason != null && reason.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text('"$reason"',
              style: GoogleFonts.manrope(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: AppTheme.onSurfaceVariant)),
        ],
      ],
    );
  }

  Color _typeColor(String t) {
    switch (t) {
      case 'create':
        return Colors.green.shade700;
      case 'update':
        return Colors.blue.shade700;
      case 'enable':
        return Colors.green.shade700;
      case 'disable':
        return Colors.orange.shade700;
      case 'delete':
        return Colors.red.shade700;
      default:
        return Colors.grey.shade700;
    }
  }

  String _relative(DateTime when) {
    final d = DateTime.now().difference(when);
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}

/// Immutable hardcoded help copy for a single rule_key. Rendered inside
/// the expandable panel on each rule card in the Rules Tab.
class _RuleHelp {
  final String what;
  final String where;
  final String example;
  const _RuleHelp({required this.what, required this.where, required this.example});
}
