import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/pricing.dart';
import '../../../core/search_utils.dart';
import '../../../services/auth_service.dart';
import '../../../services/offline_service.dart';
import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';

/// Manual sub-tab of the admin "New Order" section.
///
/// Admin selects team → beat → customer → attributed rep → adds products
/// with optional per-line price override → saves. The resulting order is
/// stamped `source = 'office'` and attributed to the picked rep's user_id
/// (NOT the admin's id) so downstream analytics / export-merging treats it
/// exactly like a rep-created order.
class ManualOrderTab extends StatefulWidget {
  final bool isSuperAdmin;
  const ManualOrderTab({super.key, required this.isSuperAdmin});

  @override
  State<ManualOrderTab> createState() => _ManualOrderTabState();
}

class _ManualOrderTabState extends State<ManualOrderTab> {
  // ── Form state ──────────────────────────────────────────────────────────
  String _team = 'JA';
  List<BeatModel> _beats = [];
  BeatModel? _selectedBeat;
  List<CustomerModel> _customers = [];
  CustomerModel? _selectedCustomer;
  List<AppUserModel> _reps = [];
  AppUserModel? _selectedRep;
  List<ProductModel> _products = [];
  DateTime _deliveryDate = DateTime.now().add(const Duration(days: 1));
  final TextEditingController _notesCtl = TextEditingController();
  final TextEditingController _customerSearchCtl = TextEditingController();
  final TextEditingController _productSearchCtl = TextEditingController();

  // ── Cart ─────────────────────────────────────────────────────────────────
  final List<_CartLine> _lines = [];

  // ── UI state ─────────────────────────────────────────────────────────────
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadForTeam(_team);
  }

  @override
  void dispose() {
    _notesCtl.dispose();
    _customerSearchCtl.dispose();
    _productSearchCtl.dispose();
    super.dispose();
  }

  Future<void> _loadForTeam(String team) async {
    setState(() => _loading = true);
    try {
      final svc = SupabaseService.instance;
      // Parallel fetches to keep the UI snappy when switching teams.
      final results = await Future.wait([
        svc.getBeatsForTeam(team),
        svc.getCustomers(),
        svc.getSalesRepsForTeam(team),
        svc.getProducts(teamId: team),
      ]);
      if (!mounted) return;
      setState(() {
        _beats = results[0] as List<BeatModel>;
        _customers = (results[1] as List<CustomerModel>)
            .where((c) => c.belongsToTeam(team))
            .toList();
        _reps = results[2] as List<AppUserModel>;
        _products = results[3] as List<ProductModel>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _onTeamChanged(String team) {
    if (team == _team) return;
    setState(() {
      _team = team;
      _selectedBeat = null;
      _selectedCustomer = null;
      _selectedRep = null;
      _customerSearchCtl.clear();
      _productSearchCtl.clear();
      _lines.clear();
    });
    _loadForTeam(team);
  }

  // ── Computed totals ──────────────────────────────────────────────────────
  double get _subtotal => _lines.fold(0, (a, l) => a + l.lineTotal);
  double get _gstTotal => _lines.fold(0, (a, l) => a + l.gstAmount);
  double get _grandTotal => _subtotal + _gstTotal;
  int get _totalUnits => _lines.fold(0, (a, l) => a + l.qty);

  bool get _canSave =>
      !_submitting &&
      _selectedCustomer != null &&
      _selectedRep != null &&
      _lines.isNotEmpty &&
      _lines.every((l) => l.qty > 0);

  // ── Save ────────────────────────────────────────────────────────────────
  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _submitting = true);

    // Re-scope AuthService.currentTeam to the picked team so createOrder
    // stamps the correct team_id. Restore on exit.
    final originalTeam = AuthService.currentTeam;
    AuthService.currentTeam = _team;

    final orderId = _generateOrderId();
    final itemsJson = _lines.map((l) => l.toJson(orderId)).toList();
    final resolvedBeatName = _selectedCustomer!.resolvedOrderBeatNameForTeam(
      _team,
      repBeat: _selectedBeat?.beatName ?? '',
    );

    try {
      await SupabaseService.instance.createOrder(
        orderId: orderId,
        customerId: _selectedCustomer!.id,
        customerName: _selectedCustomer!.name,
        beat: resolvedBeatName,
        deliveryDate: _deliveryDate,
        subtotal: _subtotal,
        vat: _gstTotal,
        grandTotal: _grandTotal,
        itemCount: _lines.length,
        totalUnits: _totalUnits,
        notes: _notesCtl.text,
        items: itemsJson,
        isOutOfBeat: false,
        overrideUserId: _selectedRep!.id,
        source: 'office',
      );
      if (!mounted) return;
      _showSuccessDialog(orderId, offline: false);
      _resetForm();
    } catch (e) {
      // Offline fallback — queue for later sync. OfflineService stamps
      // team_id on the envelope so replay after a team-switch skips safely.
      try {
        await OfflineService.instance.queueOperation('order', {
          'order_id': orderId,
          'customer_id': _selectedCustomer!.id,
          'customer_name': _selectedCustomer!.name,
          'beat': resolvedBeatName,
          'is_out_of_beat': false,
          'delivery_date': _deliveryDate.toIso8601String(),
          'subtotal': _subtotal,
          'vat': _gstTotal,
          'grand_total': _grandTotal,
          'item_count': _lines.length,
          'total_units': _totalUnits,
          'notes': _notesCtl.text,
          'items': itemsJson,
          'override_user_id': _selectedRep!.id,
          'source': 'office',
        });
        if (!mounted) return;
        _showSuccessDialog(orderId, offline: true);
        _resetForm();
      } catch (e2) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e2'), backgroundColor: Colors.red),
        );
      }
    } finally {
      AuthService.currentTeam = originalTeam;
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _generateOrderId() {
    final ts = DateTime.now();
    final y = ts.year.toString().substring(2);
    final m = ts.month.toString().padLeft(2, '0');
    final d = ts.day.toString().padLeft(2, '0');
    final h = ts.hour.toString().padLeft(2, '0');
    final mm = ts.minute.toString().padLeft(2, '0');
    final s = ts.second.toString().padLeft(2, '0');
    return 'OFC-$_team-$y$m$d$h$mm$s';
  }

  void _showSuccessDialog(String orderId, {required bool offline}) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(children: [
          Icon(offline ? Icons.cloud_off_rounded : Icons.check_circle_rounded,
              color: offline ? Colors.orange : Colors.green),
          const SizedBox(width: 8),
          Text(offline ? 'Queued offline' : 'Order saved'),
        ]),
        content: Text(
          offline
              ? 'Order $orderId was queued — it will sync when you come back online.'
              : 'Order $orderId saved to $_team. Attributed to ${_selectedRep?.fullName ?? "—"}.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  void _resetForm() {
    setState(() {
      _selectedCustomer = null;
      _customerSearchCtl.clear();
      _productSearchCtl.clear();
      _lines.clear();
      _notesCtl.clear();
      _deliveryDate = DateTime.now().add(const Duration(days: 1));
    });
  }

  // ── Build ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTeamPicker(),
          const SizedBox(height: 12),
          _buildBeatPicker(),
          const SizedBox(height: 12),
          _buildCustomerPicker(),
          const SizedBox(height: 12),
          _buildRepPicker(),
          const SizedBox(height: 12),
          _buildDeliveryDate(),
          const SizedBox(height: 12),
          _buildNotes(),
          const SizedBox(height: 20),
          _buildProductSection(),
          const SizedBox(height: 20),
          _buildCartSection(),
          const SizedBox(height: 20),
          _buildTotalsPanel(),
          const SizedBox(height: 12),
          _buildLowStockSummary(),
          const SizedBox(height: 16),
          _buildSaveButton(),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.black54, letterSpacing: 0.4)),
      );

  Widget _buildTeamPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('TEAM'),
        Row(children: [
          for (final t in ['JA', 'MA'])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _TeamChoice(
                label: t == 'JA' ? 'Jagannath' : 'Madhav',
                color: t == 'JA'
                    ? const Color(0xFF1D4ED8)
                    : const Color(0xFFC2410C),
                selected: _team == t,
                onTap: () => _onTeamChanged(t),
              ),
            ),
        ]),
      ],
    );
  }

  Widget _buildBeatPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('BEAT (optional)'),
        DropdownButtonFormField<BeatModel?>(
          initialValue: _selectedBeat,
          isExpanded: true,
          decoration: _fieldDecoration(hint: 'Pick a beat'),
          items: [
            const DropdownMenuItem<BeatModel?>(value: null, child: Text('— None (office order) —')),
            for (final b in _beats)
              DropdownMenuItem<BeatModel?>(value: b, child: Text(b.beatName)),
          ],
          onChanged: (b) => setState(() => _selectedBeat = b),
        ),
      ],
    );
  }

  Widget _buildCustomerPicker() {
    final query = _customerSearchCtl.text.trim();
    final matches = query.isEmpty
        ? <CustomerModel>[]
        : _customers.where((c) => tokenMatch(query, [c.name, c.phone])).take(12).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('CUSTOMER'),
        if (_selectedCustomer != null)
          _selectedCustomerCard()
        else
          TextField(
            controller: _customerSearchCtl,
            onChanged: (_) => setState(() {}),
            decoration: _fieldDecoration(
              hint: 'Search by name or phone',
              prefixIcon: Icons.search_rounded,
            ),
          ),
        if (matches.isNotEmpty && _selectedCustomer == null)
          Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.black12),
              borderRadius: BorderRadius.circular(10),
              color: Colors.white,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: matches.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final c = matches[i];
                return ListTile(
                  dense: true,
                  title: Text(c.name, style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600)),
                  subtitle: Text(c.phone.isEmpty ? '—' : c.phone, style: GoogleFonts.manrope(fontSize: 11)),
                  onTap: () {
                    setState(() {
                      _selectedCustomer = c;
                      _customerSearchCtl.clear();
                    });
                    // Customer drives CSDS rule lookup — recompute every line.
                    _recomputeAllLines();
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _selectedCustomerCard() {
    final c = _selectedCustomer!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Icon(Icons.person_rounded, color: AppTheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.name, style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800)),
              Text(c.phone.isEmpty ? '—' : c.phone, style: GoogleFonts.manrope(fontSize: 11, color: Colors.black54)),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded, size: 20),
          tooltip: 'Change customer',
          onPressed: () => setState(() => _selectedCustomer = null),
        ),
      ]),
    );
  }

  Widget _buildRepPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('ATTRIBUTE TO REP'),
        DropdownButtonFormField<AppUserModel>(
          initialValue: _selectedRep,
          isExpanded: true,
          decoration: _fieldDecoration(hint: 'Pick a rep (brand_rep highlighted)'),
          items: [
            for (final r in _reps)
              DropdownMenuItem<AppUserModel>(
                value: r,
                child: Row(children: [
                  if (r.role == 'brand_rep')
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.purple.shade100,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('BRAND',
                          style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.purple.shade700)),
                    ),
                  Expanded(child: Text(r.fullName, overflow: TextOverflow.ellipsis)),
                ]),
              ),
          ],
          onChanged: (r) => setState(() => _selectedRep = r),
        ),
      ],
    );
  }

  Widget _buildDeliveryDate() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('DELIVERY DATE'),
        InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _deliveryDate,
              firstDate: DateTime.now().subtract(const Duration(days: 7)),
              lastDate: DateTime.now().add(const Duration(days: 60)),
            );
            if (picked != null) setState(() => _deliveryDate = picked);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.black26),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              const Icon(Icons.event_rounded, size: 18, color: Colors.black54),
              const SizedBox(width: 10),
              Text('${_deliveryDate.day}/${_deliveryDate.month}/${_deliveryDate.year}',
                  style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _buildNotes() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('NOTES (optional)'),
        TextField(
          controller: _notesCtl,
          maxLines: 2,
          decoration: _fieldDecoration(hint: 'Any admin notes on this order'),
        ),
      ],
    );
  }

  Widget _buildProductSection() {
    final query = _productSearchCtl.text.trim();
    final matches = query.isEmpty
        ? <ProductModel>[]
        : _products.where((p) => tokenMatch(query, [p.name, p.sku, p.category])).take(12).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('ADD PRODUCTS'),
        TextField(
          controller: _productSearchCtl,
          onChanged: (_) => setState(() {}),
          decoration: _fieldDecoration(
            hint: 'Search products by name / SKU / brand',
            prefixIcon: Icons.search_rounded,
          ),
        ),
        if (matches.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.black12),
              borderRadius: BorderRadius.circular(10),
              color: Colors.white,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: matches.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final p = matches[i];
                final alreadyInCart = _lines.any((l) => l.product.id == p.id);
                return ListTile(
                  dense: true,
                  title: Text(p.name, style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600)),
                  subtitle: Text('${p.sku} · ${p.category} · ₹${p.unitPrice.toStringAsFixed(2)}',
                      style: GoogleFonts.manrope(fontSize: 11)),
                  trailing: alreadyInCart
                      ? const Icon(Icons.check_rounded, color: Colors.green)
                      : const Icon(Icons.add_circle_outline_rounded),
                  onTap: alreadyInCart ? null : () => _addProduct(p),
                );
              },
            ),
          ),
      ],
    );
  }

  void _addProduct(ProductModel p) {
    final line = _CartLine(product: p, qty: 1, overridePrice: null);
    setState(() {
      _lines.add(line);
      _productSearchCtl.clear();
    });
    _recomputeLine(line);
  }

  /// Recompute CSDS breakdown for a single line. Safe no-op when CSDS is
  /// disabled (kForcedOff OR !enabled) — priceFor returns a no-rule
  /// breakdown with netRate == baseRate.
  Future<void> _recomputeLine(_CartLine line) async {
    // If no customer, skip: CSDS rules are customer-keyed. Clear any stale
    // breakdown so UI falls back to catalog rate cleanly.
    if (_selectedCustomer == null) {
      if (mounted) setState(() => line.breakdown = null);
      return;
    }
    try {
      final brand = line.product.category.isNotEmpty
          ? line.product.category
          : (line.product.company ?? '');
      final breakdown = await CsdsPricing.priceFor(
        baseRate: line.product.unitPrice,
        qty: line.qty,
        taxPercent: line.product.gstRate * 100,
        customerId: _selectedCustomer!.id,
        company: brand,
        itemGroup: line.product.itemGroup ?? '',
        teamId: _team,
      );
      if (!mounted) return;
      setState(() => line.breakdown = breakdown);
    } catch (e) {
      // CSDS lookup failed — fall through to catalog pricing. Don't block save.
      debugPrint('[ManualOrderTab] CSDS recompute failed for ${line.product.id}: $e');
    }
  }

  Future<void> _recomputeAllLines() async {
    for (final l in _lines) {
      await _recomputeLine(l);
    }
  }

  Widget _buildCartSection() {
    if (_lines.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.black12, style: BorderStyle.solid),
        ),
        child: Text('No line items yet. Search above to add products.',
            style: GoogleFonts.manrope(fontSize: 12, color: Colors.black45)),
      );
    }
    return Column(
      children: [
        _sectionLabel('CART (${_lines.length} line${_lines.length == 1 ? '' : 's'})'),
        for (int i = 0; i < _lines.length; i++) _buildLineEditor(i, _lines[i]),
      ],
    );
  }

  Widget _buildLineEditor(int index, _CartLine line) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(line.product.name,
                    style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: 'Remove line',
                onPressed: () => setState(() => _lines.removeAt(index)),
              ),
            ]),
            // Badge row — only shows if any flag is active.
            if (line.isPriceOverridden || line.hasScheme || line.hasRule || line.isLowStock)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (line.isLowStock)
                      _lineBadge(
                        'LOW STOCK (${line.product.stockQty} available)',
                        Colors.red.shade100, Colors.red.shade900,
                      ),
                    if (line.isPriceOverridden)
                      _lineBadge('OVERRIDDEN', Colors.orange.shade100, Colors.orange.shade900),
                    if (line.hasScheme)
                      _lineBadge('+${line.freeQty} FREE',
                          Colors.green.shade100, Colors.green.shade900),
                    if (line.hasRule && !line.isPriceOverridden)
                      _lineBadge('CSDS', Colors.blue.shade100, Colors.blue.shade900),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: TextFormField(
                  initialValue: line.qty.toString(),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: _fieldDecoration(label: 'Qty'),
                  onChanged: (v) {
                    setState(() => line.qty = int.tryParse(v) ?? 0);
                    // Qty affects scheme free_qty thresholds in CSDS.
                    _recomputeLine(line);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  initialValue: (line.overridePrice ?? line.product.unitPrice).toStringAsFixed(2),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _fieldDecoration(label: 'Unit ₹'),
                  onChanged: (v) => setState(() {
                    final parsed = double.tryParse(v);
                    line.overridePrice = (parsed == null || parsed == line.product.unitPrice)
                        ? null
                        : parsed;
                  }),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('₹${(line.lineTotal + line.gstAmount).toStringAsFixed(2)}',
                      textAlign: TextAlign.right,
                      style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w800)),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _buildTotalsPanel() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          _totalsRow('Subtotal', _subtotal),
          _totalsRow('GST', _gstTotal),
          const Divider(),
          _totalsRow('Grand Total', _grandTotal, bold: true),
          _totalsRow('Units', _totalUnits.toDouble(), isCount: true),
        ],
      ),
    );
  }

  Widget _totalsRow(String label, double value, {bool bold = false, bool isCount = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: GoogleFonts.manrope(
                fontSize: bold ? 14 : 12,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                color: Colors.black.withValues(alpha: bold ? 1.0 : 0.7),
              )),
          Text(isCount ? value.toInt().toString() : '₹${value.toStringAsFixed(2)}',
              style: GoogleFonts.manrope(
                fontSize: bold ? 14 : 12,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
              )),
        ],
      ),
    );
  }

  Widget _buildLowStockSummary() {
    final lowLines = _lines.where((l) => l.isLowStock).toList();
    if (lowLines.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.shade300),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: Colors.red.shade800),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${lowLines.length} line${lowLines.length == 1 ? '' : 's'} exceed available stock',
                  style: GoogleFonts.manrope(
                      fontSize: 12, fontWeight: FontWeight.w800, color: Colors.red.shade900),
                ),
                const SizedBox(height: 2),
                Text(
                  'You can still save — the office may fulfil on short stock. '
                  'Reduce the qty on low-stock lines if you want to hold the order.',
                  style: GoogleFonts.manrope(fontSize: 11, color: Colors.red.shade900, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveButton() {
    return FilledButton.icon(
      onPressed: _canSave ? _save : null,
      icon: _submitting
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.save_rounded),
      label: Text(_submitting ? 'Saving…' : 'Save Order',
          style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800)),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        backgroundColor: AppTheme.primary,
      ),
    );
  }

  Widget _lineBadge(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
        child: Text(text,
            style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: fg)),
      );

  InputDecoration _fieldDecoration({String? hint, String? label, IconData? prefixIcon}) {
    return InputDecoration(
      hintText: hint,
      labelText: label,
      prefixIcon: prefixIcon != null ? Icon(prefixIcon, size: 18) : null,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Internal: in-memory cart line. Mirrors the payload order_creation_screen
// builds — so the server-side schema expectations are identical.
//
// Priority for unit_price: overridePrice > CSDS netRate > catalog unitPrice.
// When CSDS is OFF (kForcedOff==true OR !enabled OR no customer) the
// breakdown falls back to catalog rate with no discount — same as the rep
// flow. Admin can still override per-line.
// ─────────────────────────────────────────────────────────────────────────
class _CartLine {
  final ProductModel product;
  int qty;
  double? overridePrice;          // NULL = use CSDS netRate or catalog
  CsdsPriceBreakdown? breakdown;  // async-populated; null until computed

  _CartLine({required this.product, required this.qty, this.overridePrice});

  /// Effective per-unit rate. Override wins; otherwise CSDS netRate;
  /// otherwise catalog unit price.
  double get unitPrice {
    if (overridePrice != null) return overridePrice!;
    if (breakdown != null) return breakdown!.netRate;
    return product.unitPrice;
  }

  double get lineTotal => unitPrice * qty;

  /// Use CSDS tax if breakdown present AND admin didn't override price
  /// (tax is on the discounted taxable). If price is overridden, tax on
  /// override × qty × gstRate.
  double get gstAmount {
    if (overridePrice == null && breakdown != null) return breakdown!.tax;
    return lineTotal * product.gstRate;
  }

  /// Free qty from matched CSDS scheme rule (0 if no rule or CSDS off).
  int get freeQty => breakdown?.freeQty ?? 0;

  bool get hasScheme => freeQty > 0;
  bool get hasRule => breakdown?.rule != null;
  bool get isPriceOverridden =>
      overridePrice != null && overridePrice! != product.unitPrice;
  bool get isLowStock => qty > product.stockQty;

  Map<String, dynamic> toJson(String orderId) {
    final m = <String, dynamic>{
      'order_id': orderId,
      'product_id': product.id,
      'product_name': product.name,
      'sku': product.sku,
      'quantity': qty,
      'unit_price': unitPrice,
      'mrp': product.mrp,
      'line_total': lineTotal,
      'gst_rate': product.gstRate,
    };
    // Mirror order_creation_screen's CSDS metadata — only write when the
    // CSDS rule actually contributed (i.e. admin didn't force a different
    // price via override). Same rule the analytics/export pipeline reads.
    if (overridePrice == null && breakdown?.rule != null) {
      final r = breakdown!.rule!;
      m['csds_disc_per'] = r.discPer;
      m['csds_disc_per_3'] = r.discPer3;
      m['csds_disc_per_5'] = r.discPer5;
    }
    if (overridePrice == null && freeQty > 0) {
      m['free_qty'] = freeQty;
    }
    return m;
  }
}

class _TeamChoice extends StatelessWidget {
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _TeamChoice({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? color : color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? color : color.withValues(alpha: 0.40),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.manrope(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : color,
          ),
        ),
      ),
    );
  }
}
