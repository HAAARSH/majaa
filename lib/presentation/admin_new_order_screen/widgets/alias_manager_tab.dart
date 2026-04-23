import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/auth_service.dart';
import '../../../services/smart_import_service.dart';
import '../../../theme/app_theme.dart';

/// Third sub-tab under the admin "New Order" section: alias manager.
///
/// Shows every mapping the Smart Import pipeline has learned. Admin can
/// search and delete stale / wrong mappings here. Edit is not supported
/// in this first cut — if a mapping is wrong, delete it and the next
/// import will re-learn. Bulk CSV import/export deferred to Phase 6.
class AliasManagerTab extends StatefulWidget {
  const AliasManagerTab({super.key});

  @override
  State<AliasManagerTab> createState() => _AliasManagerTabState();
}

enum _View { products, customers }

class _AliasManagerTabState extends State<AliasManagerTab> {
  _View _view = _View.products;
  String _team = AuthService.currentTeam;
  final TextEditingController _searchCtl = TextEditingController();

  bool _loading = false;
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final search = _searchCtl.text;
    try {
      final rows = _view == _View.products
          ? await SmartImportService.instance.listProductAliases(
              teamId: _team, search: search)
          : await SmartImportService.instance.listCustomerAliases(
              teamId: _team, search: search);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Load failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    final alias = row['alias_text'] as String? ?? '—';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete alias?'),
        content: Text(
          'Remove the mapping "$alias" → ${_view == _View.products ? "product" : "customer"}?\n\n'
          'Next import with this alias will re-learn from admin input.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      if (_view == _View.products) {
        await SmartImportService.instance.deleteProductAlias(id);
      } else {
        await SmartImportService.instance.deleteCustomerAlias(id);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted "$alias"'), backgroundColor: Colors.green),
      );
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildHeader(),
        const Divider(height: 1),
        Expanded(child: _buildList()),
      ],
    );
  }

  Widget _buildHeader() {
    return Container(
      color: AppTheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            for (final t in ['JA', 'MA'])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(t, style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
                  selected: _team == t,
                  onSelected: (_) {
                    setState(() => _team = t);
                    _reload();
                  },
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: SegmentedButton<_View>(
                segments: const [
                  ButtonSegment<_View>(
                    value: _View.products,
                    label: Text('Product aliases'),
                    icon: Icon(Icons.inventory_2_rounded, size: 16),
                  ),
                  ButtonSegment<_View>(
                    value: _View.customers,
                    label: Text('Customer aliases'),
                    icon: Icon(Icons.person_rounded, size: 16),
                  ),
                ],
                selected: {_view},
                showSelectedIcon: false,
                onSelectionChanged: (s) {
                  setState(() => _view = s.first);
                  _reload();
                },
              ),
            ),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _searchCtl,
            decoration: InputDecoration(
              hintText: 'Search aliases',
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              suffixIcon: _searchCtl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        _searchCtl.clear();
                        _reload();
                      },
                    ),
            ),
            onSubmitted: (_) => _reload(),
            onChanged: (_) => setState(() {/* suffix-icon rebuild */}),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _searchCtl.text.trim().isEmpty
                ? 'No aliases yet for team $_team. They appear as admin saves Smart Import orders.'
                : 'No matches for "${_searchCtl.text.trim()}".',
            textAlign: TextAlign.center,
            style: GoogleFonts.manrope(fontSize: 12, color: Colors.black45),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: _rows.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (_, i) => _view == _View.products
            ? _productRow(_rows[i])
            : _customerRow(_rows[i]),
      ),
    );
  }

  Widget _productRow(Map<String, dynamic> row) {
    final alias = row['alias_text'] as String? ?? '';
    final product = (row['products'] as Map?) ?? {};
    final prodName = product['name'] as String? ?? '(missing product)';
    final sku = product['sku'] as String? ?? '';
    final customer = (row['customers'] as Map?);
    final custName = customer?['name'] as String?;
    final isGlobal = row['customer_id'] == null;
    final conf = (row['confidence_score'] as num?)?.toInt() ?? 0;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text('"$alias"',
                    style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.shade100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('×$conf',
                    style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.blueGrey.shade900)),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red.shade700),
                tooltip: 'Delete alias',
                onPressed: () => _confirmDelete(row),
              ),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.arrow_forward_rounded, size: 14, color: Colors.black45),
              const SizedBox(width: 6),
              Expanded(
                child: Text('$prodName${sku.isEmpty ? "" : " · $sku"}',
                    style: GoogleFonts.manrope(fontSize: 12, color: Colors.black87)),
              ),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isGlobal ? Colors.purple.shade100 : Colors.amber.shade100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isGlobal ? 'GLOBAL' : 'CUSTOMER: ${custName ?? "(unknown)"}',
                  style: GoogleFonts.manrope(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: isGlobal ? Colors.purple.shade900 : Colors.amber.shade900,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(_relTime(row['last_used_at']),
                  style: GoogleFonts.manrope(fontSize: 10, color: Colors.black45)),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _customerRow(Map<String, dynamic> row) {
    final alias = row['alias_text'] as String? ?? '';
    final customer = (row['customers'] as Map?) ?? {};
    final custName = customer['name'] as String? ?? '(missing customer)';
    final phone = customer['phone'] as String? ?? '';
    final conf = (row['confidence_score'] as num?)?.toInt() ?? 0;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text('"$alias"',
                    style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.shade100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('×$conf',
                    style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.blueGrey.shade900)),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red.shade700),
                tooltip: 'Delete alias',
                onPressed: () => _confirmDelete(row),
              ),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.arrow_forward_rounded, size: 14, color: Colors.black45),
              const SizedBox(width: 6),
              Expanded(
                child: Text('$custName${phone.isEmpty ? "" : " · $phone"}',
                    style: GoogleFonts.manrope(fontSize: 12, color: Colors.black87)),
              ),
            ]),
            const SizedBox(height: 4),
            Text(_relTime(row['last_used_at']),
                style: GoogleFonts.manrope(fontSize: 10, color: Colors.black45)),
          ],
        ),
      ),
    );
  }

  String _relTime(dynamic isoTs) {
    if (isoTs == null) return 'never used';
    DateTime? ts;
    try {
      ts = DateTime.parse(isoTs.toString()).toLocal();
    } catch (_) {
      return 'last used: $isoTs';
    }
    final d = DateTime.now().difference(ts);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 30) return '${d.inDays}d ago';
    return '${(d.inDays / 30).round()}mo ago';
  }
}
