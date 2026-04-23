import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:google_fonts/google_fonts.dart';

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
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: inCategory.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _buildRuleCard(inCategory[i]),
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
                    fontSize: 11, color: AppTheme.onSurfaceVariant)),
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
    return value?.toString() ?? '—';
  }

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
    } else {
      Fluttertoast.showToast(
        msg: 'Editing this rule type is not supported in the UI yet.',
        toastLength: Toast.LENGTH_LONG,
      );
    }
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
