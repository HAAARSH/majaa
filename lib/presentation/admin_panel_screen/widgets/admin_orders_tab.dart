import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/empty_state_widget.dart';
import '../admin_panel_screen.dart' show adminOrdersNavIntent;

// Conditional import for web download
import 'admin_orders_download_stub.dart'
    if (dart.library.html) 'admin_orders_download_web.dart';

class AdminOrdersTab extends StatefulWidget {
  const AdminOrdersTab({super.key});

  @override
  State<AdminOrdersTab> createState() => _AdminOrdersTabState();
}

class _AdminOrdersTabState extends State<AdminOrdersTab> {
  final _service = SupabaseService.instance;

  List<OrderModel> _orders = [];
  List<OrderModel> _filteredOrders = [];
  bool _loading = false;
  String? _error;
  bool _isSuperAdmin = false;

  DateTime? _startDate;
  DateTime? _endDate;
  bool _hasFiltered = false;
  bool _generatingPdf = false;
  String _selectedStatus = 'Pending';
  // Team filter
  String _selectedTeamFilter = 'JA';
  // Beat filter — set by dashboard drill-through (tap a beat on Dashboard
  // → Orders tab lands here filtered to that beat). null means no beat filter.
  String? _beatFilter;

  // Pagination
  static const _pageSize = 50;
  bool _loadingMore = false;
  bool _hasMore = true;

  // Statuses that ONLY admins can set
  static const _adminOnlyStatuses = {'Cancelled', 'Returned', 'Partially Delivered'};
  // All statuses for display filter
  static const _allStatuses = ['All', 'Pending', 'Confirmed', 'Delivered', 'Invoiced', 'Paid', 'Cancelled', 'Returned', 'Partially Delivered'];

  @override
  void initState() {
    super.initState();
    _loadRole();
    // Apply any pending drill-through intent INLINE (not via setState — we're
    // still in initState; Flutter forbids setState before first build).
    // The one _loadOrders() call at the bottom then fetches with the applied
    // filters, so we don't double-fetch.
    final pending = adminOrdersNavIntent.value;
    if (pending != null) {
      if (pending.startDate != null) _startDate = pending.startDate;
      if (pending.endDate != null) _endDate = pending.endDate;
      if (pending.teamId != null) _selectedTeamFilter = pending.teamId!;
      _beatFilter = pending.beatName;
      _selectedStatus = 'All';
      adminOrdersNavIntent.value = null; // consume
    }
    // For subsequent intents (user drills again after having visited Orders
    // tab once), the listener path uses setState safely (first build done).
    adminOrdersNavIntent.addListener(_consumeNavIntent);
    _loadOrders();
  }

  @override
  void dispose() {
    adminOrdersNavIntent.removeListener(_consumeNavIntent);
    super.dispose();
  }

  void _consumeNavIntent() {
    // Only called AFTER initState completes — setState is safe here.
    final intent = adminOrdersNavIntent.value;
    if (intent == null) return;
    if (!mounted) return;
    setState(() {
      if (intent.startDate != null) _startDate = intent.startDate;
      if (intent.endDate != null) _endDate = intent.endDate;
      if (intent.teamId != null) _selectedTeamFilter = intent.teamId!;
      _beatFilter = intent.beatName;
      _selectedStatus = 'All';
    });
    adminOrdersNavIntent.value = null; // consume
    _loadOrders();
  }

  Future<void> _loadRole() async {
    final role = await _service.getUserRole();
    if (mounted) setState(() => _isSuperAdmin = role == 'super_admin');
  }

  Future<void> _loadOrders({bool forceRefresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
      _hasMore = true;
    });
    try {
      final teamId = _selectedTeamFilter;
      final orders = await _service.getOrdersByDateRange(
        startDate: _startDate,
        endDate: _endDate,
        teamId: teamId,
        limit: _pageSize,
        offset: 0,
        forceRefresh: forceRefresh,
      );
      setState(() {
        _orders = orders;
        _loading = false;
        _hasFiltered = true;
        _hasMore = orders.length >= _pageSize;
      });
      _applyStatusFilter();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final teamId = _selectedTeamFilter;
      final moreOrders = await _service.getOrdersByDateRange(
        startDate: _startDate,
        endDate: _endDate,
        teamId: teamId,
        limit: _pageSize,
        offset: _orders.length,
      );
      setState(() {
        _orders.addAll(moreOrders);
        _loadingMore = false;
        _hasMore = moreOrders.length >= _pageSize;
      });
      _applyStatusFilter();
    } catch (e) {
      setState(() => _loadingMore = false);
    }
  }

  /// Paginated list shows ~50 orders; exports must include everything that
  /// matches the current date-range/team filter. Page through until exhausted
  /// before handing data to the CSV/PDF builder.
  Future<bool> _ensureAllOrdersLoaded() async {
    if (!_hasMore) return true;
    if (_loadingMore) return false;
    setState(() => _loadingMore = true);
    Fluttertoast.showToast(msg: 'Loading all orders for export…');
    try {
      while (_hasMore && mounted) {
        final more = await _service.getOrdersByDateRange(
          startDate: _startDate,
          endDate: _endDate,
          teamId: _selectedTeamFilter,
          limit: _pageSize,
          offset: _orders.length,
        );
        _orders.addAll(more);
        _hasMore = more.length >= _pageSize;
      }
      if (!mounted) return false;
      setState(() => _loadingMore = false);
      _applyStatusFilter();
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _loadingMore = false);
        Fluttertoast.showToast(msg: 'Failed to load all orders: $e');
      }
      return false;
    }
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() => _startDate = picked);
    }
  }

  Future<void> _pickEndDate() async {
    final firstAllowedDate = _startDate ?? DateTime(2020);

    DateTime initial = _endDate ?? DateTime.now();
    if (initial.isBefore(firstAllowedDate)) {
      initial = firstAllowedDate;
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstAllowedDate,
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && mounted) {
      setState(() => _endDate = picked);
    }
  }

  void _applyStatusFilter() {
    setState(() {
      Iterable<OrderModel> list = _orders;
      if (_selectedStatus != 'All') {
        list = list.where((o) => o.status.toLowerCase() == _selectedStatus.toLowerCase());
      }
      if (_beatFilter != null && _beatFilter!.isNotEmpty) {
        list = list.where((o) => o.beat == _beatFilter);
      }
      _filteredOrders = list.toList();
    });
  }

  void _clearFilter() {
    setState(() {
      _startDate = null;
      _endDate = null;
      _beatFilter = null;
    });
    _loadOrders();
  }

  String _formatDate(DateTime? d) {
    if (d == null) return 'Select';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  Map<String, List<OrderModel>> _groupByCustomer() {
    final map = <String, List<OrderModel>>{};
    for (final o in _filteredOrders) {
      map.putIfAbsent(o.customerName, () => []).add(o);
    }
    final sorted = Map.fromEntries(
      map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return sorted;
  }

  String _buildCsv({
    required List<OrderModel> orders,
    required Map<String, double> productMrpMap,
    required Map<String, double> productUnitPriceMap,
    required Map<String, String> productBillingNameMap,
    required Map<String, String> userNameMap,
    required DateTime exportDate,
    String? invoicePrefix,
    int? invoiceStartNum,
    // Cross-team billing protection: when non-null, line items whose
    // product_id/sku isn't in these sets are SKIPPED. The selected team's
    // billing software only knows its own SKUs, so cross-brand items
    // (e.g. SHADANI in JA export) must be excluded here and will be
    // exported separately when the admin switches to the other team.
    Set<String>? teamProductIds,
    Set<String>? teamProductSkus,
  }) {
    final buffer = StringBuffer();
    const t = '\t';

    buffer.writeln(
      'Invoice No${t}Order ID${t}Order Date${t}Customer Name${t}Qty${t}Rep Name${t}Item Name${t}MRP${t}Unit Price${t}Item Discount${t}Discount${t}Item Gross Amount${t}Notes',
    );

    const months = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
    final dateStr = '="${exportDate.day.toString().padLeft(2, '0')}-${months[exportDate.month - 1]}-${exportDate.year}"';
    final bool scoped = teamProductIds != null && teamProductIds.isNotEmpty;
    bool itemBelongsToTeam(OrderItemModel item) {
      if (!scoped) return true;
      if (teamProductIds.contains(item.productId)) return true;
      if (teamProductSkus != null && item.sku.isNotEmpty && teamProductSkus.contains(item.sku)) return true;
      return false;
    }
    int invoiceCounter = invoiceStartNum ?? 0;
    for (final o in orders) {
      // Skip entire order if scoped and no line items belong to the team.
      final eligibleItems = scoped
          ? o.lineItems.where(itemBelongsToTeam).toList()
          : o.lineItems;
      if (scoped && o.lineItems.isNotEmpty && eligibleItems.isEmpty) continue;

      final invoiceNo = (invoicePrefix != null && invoiceStartNum != null)
          ? '$invoicePrefix${invoiceCounter++}'
          : '';
      final repName = (o.userId != null ? userNameMap[o.userId] : null) ?? '';
      // Sanitize notes: replace newlines and tabs to prevent breaking rows
      final notes = (o.notes ?? '').replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();

      if (eligibleItems.isEmpty) {
        buffer.writeln(
          '$invoiceNo$t${o.id}$t$dateStr$t${o.customerName}${t}0$t$repName$t${t}0.00${t}0.00${t}0.00${t}0.00${t}0.00$t$notes',
        );
      } else {
        for (final item in eligibleItems) {
          final mrp = item.mrp > 0 ? item.mrp : (productMrpMap[item.productId] ?? productMrpMap[item.sku] ?? 0.0);
          // Use current product unit_price if it changed after order was placed
          final currentUnitPrice = productUnitPriceMap[item.productId] ?? productUnitPriceMap[item.sku] ?? item.unitPrice;
          final itemName = productBillingNameMap[item.productId] ?? productBillingNameMap[item.sku] ?? item.productName;
          final grossAmount = item.quantity * currentUnitPrice;
          buffer.writeln(
            '$invoiceNo$t${o.id}$t$dateStr$t${o.customerName}$t${item.quantity}$t$repName$t$itemName$t${mrp.toStringAsFixed(2)}$t${currentUnitPrice.toStringAsFixed(2)}${t}0.00${t}0.00$t${grossAmount.toStringAsFixed(2)}$t$notes',
          );
        }
      }
    }

    return buffer.toString();
  }

  Future<void> _downloadCsv() async {
    if (_filteredOrders.isEmpty) {
      Fluttertoast.showToast(msg: 'No orders to export');
      return;
    }

    // Exports must include every order matching the current date-range/team,
    // not just the paginated slice currently on screen.
    final fullyLoaded = await _ensureAllOrdersLoaded();
    if (!fullyLoaded || !mounted) return;

    // Step 1: Ask which order status to export
    String exportStatus = 'Pending';
    final statusResult = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('Export Orders', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Select which orders to export',
                    style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: exportStatus,
                  decoration: InputDecoration(
                    labelText: 'Order Status',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  items: ['Pending', 'All', 'Delivered'].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                  onChanged: (v) {
                    if (v != null) setDialogState(() => exportStatus = v);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: Text('Cancel', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, exportStatus),
                child: Text('Next', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        );
      },
    );
    if (statusResult == null) return;

    // Filter orders by selected status
    final statusFilteredOrders = statusResult == 'All'
        ? _filteredOrders
        : _filteredOrders.where((o) => o.status.toLowerCase() == statusResult.toLowerCase()).toList();
    if (statusFilteredOrders.isEmpty) {
      Fluttertoast.showToast(msg: 'No $statusResult orders to export');
      return;
    }

    // Pre-load selected team's products + cross-team orders BEFORE the beat
    // picker so it can show a team-wise split per beat. (The final CSV build
    // re-uses these same maps/sets further down.)
    final products = await _service.getProducts(teamId: _selectedTeamFilter);
    final mrpMap = <String, double>{};
    final unitPriceMap = <String, double>{};
    final billingNameMap = <String, String>{};
    final teamProductIds = <String>{};
    final teamProductSkus = <String>{};
    for (final p in products) {
      mrpMap[p.id] = p.mrp;
      unitPriceMap[p.id] = p.unitPrice;
      billingNameMap[p.id] = p.billingName ?? p.name;
      teamProductIds.add(p.id);
      if (p.sku.isNotEmpty) {
        mrpMap[p.sku] = p.mrp;
        unitPriceMap[p.sku] = p.unitPrice;
        billingNameMap[p.sku] = p.billingName ?? p.name;
        teamProductSkus.add(p.sku);
      }
    }

    final otherTeam = _selectedTeamFilter == 'JA' ? 'MA' : 'JA';
    List<OrderModel> crossTeamExtra = const [];
    try {
      final otherTeamOrders = await _service.getOrdersByDateRange(
        startDate: _startDate,
        endDate: _endDate,
        teamId: otherTeam,
        limit: 10000,
      );
      crossTeamExtra = otherTeamOrders.where((o) {
        if (statusResult != 'All' && o.status.toLowerCase() != statusResult!.toLowerCase()) return false;
        return o.lineItems.any((it) =>
            teamProductIds.contains(it.productId) ||
            (it.sku.isNotEmpty && teamProductSkus.contains(it.sku)));
      }).toList();
    } catch (e) {
      debugPrint('[ExportCsv] Cross-team fetch failed: $e — continuing without it');
    }

    // Step 2: Ask which beats to export (multi-select).
    // Beats come from BOTH same-team and cross-team orders so the admin can
    // see team-wise counts per beat. A cross-team order's beat is the beat
    // the OTHER team's rep was on when the order was booked.
    final sameTeamBeatCount = <String, int>{};
    final crossTeamBeatCount = <String, int>{};
    for (final o in statusFilteredOrders) {
      if (o.beat.isEmpty) continue;
      sameTeamBeatCount[o.beat] = (sameTeamBeatCount[o.beat] ?? 0) + 1;
    }
    for (final o in crossTeamExtra) {
      if (o.beat.isEmpty) continue;
      crossTeamBeatCount[o.beat] = (crossTeamBeatCount[o.beat] ?? 0) + 1;
    }
    final beats = {...sameTeamBeatCount.keys, ...crossTeamBeatCount.keys}.toList()..sort();
    final selectedBeats = <String>{...beats}; // all selected by default
    final beatResult = await showDialog<Set<String>?>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final allSelected = selectedBeats.length == beats.length;
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text('Select Beats', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Select which beat orders to export',
                        style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant)),
                    const SizedBox(height: 12),
                    // Select All / Deselect All
                    CheckboxListTile(
                      dense: true,
                      title: Text('All Beats', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
                      value: allSelected,
                      onChanged: (_) {
                        setDialogState(() {
                          if (allSelected) {
                            selectedBeats.clear();
                          } else {
                            selectedBeats.addAll(beats);
                          }
                        });
                      },
                    ),
                    const Divider(height: 1),
                    // Individual beats — bumped 300 → 520 so 20-30 beat
                    // lists don't force inside-dialog scrolling on mobile.
                    // User directive 2026-04-18: "i need bigger spaces in
                    // everything".
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(ctx).size.height * 0.6,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: beats.length,
                        itemBuilder: (_, i) {
                          final beat = beats[i];
                          final sameCount = sameTeamBeatCount[beat] ?? 0;
                          final crossCount = crossTeamBeatCount[beat] ?? 0;
                          // Subtitle shows team-wise split so admin sees
                          // whether the beat carries cross-team pickups too.
                          // Team-letter labels use the admin's selected team
                          // first (X same-team), then other team for cross.
                          final parts = <String>[];
                          if (sameCount > 0) parts.add('$sameCount $_selectedTeamFilter');
                          if (crossCount > 0) parts.add('$crossCount cross-team from $otherTeam');
                          final totalOrders = sameCount + crossCount;
                          return CheckboxListTile(
                            dense: true,
                            title: Text(beat, style: GoogleFonts.manrope(fontSize: 13)),
                            subtitle: Text(
                              '$totalOrders order${totalOrders == 1 ? '' : 's'} · ${parts.join(' + ')}',
                              style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
                            ),
                            value: selectedBeats.contains(beat),
                            onChanged: (_) {
                              setDialogState(() {
                                if (selectedBeats.contains(beat)) {
                                  selectedBeats.remove(beat);
                                } else {
                                  selectedBeats.add(beat);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: Text('Cancel', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
                ),
                FilledButton(
                  onPressed: selectedBeats.isEmpty ? null : () => Navigator.pop(ctx, selectedBeats),
                  child: Text('Next (${selectedBeats.length})', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
                ),
              ],
            );
          },
        );
      },
    );
    if (beatResult == null || beatResult.isEmpty) return;

    // Apply the beat filter to BOTH same-team and cross-team sets. Admin's
    // tick-list now governs both — unticking a beat excludes cross-team
    // pickups on that beat as well.
    final allSelected = beatResult.length == beats.length;
    final exportOrders = allSelected
        ? statusFilteredOrders
        : statusFilteredOrders.where((o) => beatResult.contains(o.beat)).toList();
    if (!allSelected) {
      crossTeamExtra = crossTeamExtra
          .where((o) => beatResult.contains(o.beat))
          .toList();
    }
    if (exportOrders.isEmpty && crossTeamExtra.isEmpty) {
      Fluttertoast.showToast(msg: 'No orders for selected beats');
      return;
    }

    // Step 3: Ask for starting invoice number
    final invoiceController = TextEditingController();
    final invoiceResult = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Starting Invoice No', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Enter starting invoice number (e.g. INV420).\nIt will auto-increment for each order.',
                style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            TextField(
              controller: invoiceController,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'e.g. INV420',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: Text('Ignore', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, invoiceController.text.trim()),
            child: Text('Add Invoice No', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    // Parse prefix and starting number from input like "INV420"
    String? invoicePrefix;
    int? invoiceStartNum;
    if (invoiceResult != null && invoiceResult.isNotEmpty) {
      final match = RegExp(r'^([A-Za-z]*)(\d+)$').firstMatch(invoiceResult);
      if (match != null) {
        invoicePrefix = match.group(1)!;
        invoiceStartNum = int.parse(match.group(2)!);
      } else {
        Fluttertoast.showToast(msg: 'Invalid format. Use like INV420');
        return;
      }
    }

    // Step 4: Ask for export date (for DUA Clipper import — DD-MMM-YYYY text format)
    DateTime exportDate = DateTime.now().subtract(const Duration(days: 1));
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: exportDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: 'Select order date for export',
    );
    if (pickedDate == null) return;
    exportDate = pickedDate;

    // products / teamProductIds / teamProductSkus / crossTeamExtra were all
    // computed earlier (before the beat picker) so that the picker could
    // show per-beat team-wise counts. They flow into the final _buildCsv
    // call below unchanged.

    // Build user name lookup map
    // Map by app_users.id AND by email (handles early users like Ranjeet
    // whose auth UID differs from app_users.id)
    final users = await _service.getAppUsers(allTeams: true);
    final userNameMap = <String, String>{};
    for (final u in users) {
      userNameMap[u.id] = u.fullName;
    }
    // For unmatched order user_ids, resolve via direct DB lookup
    final unmatchedIds = _filteredOrders
        .where((o) => o.userId != null && !userNameMap.containsKey(o.userId))
        .map((o) => o.userId!)
        .toSet();
    for (final uid in unmatchedIds) {
      final name = await _service.getUserFullName(uid);
      if (name != null) userNameMap[uid] = name;
    }

    // Pre-export summary: show the admin a breakdown of same-team vs
    // cross-team orders BEFORE the CSV is generated. Cross-team pickups
    // happen automatically when a rep from the other team sold one of this
    // team's products (e.g. JA rep sold SHADANI → appears in MA export).
    // Giving admin visibility prevents surprise if the order count looks
    // higher than the Orders tab's team-filtered list.
    if (crossTeamExtra.isNotEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Export Summary', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Billing export for team $_selectedTeamFilter will include:',
                style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.check_circle_rounded, size: 16, color: Colors.green.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${exportOrders.length} order(s) booked under $_selectedTeamFilter',
                      style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.compare_arrows_rounded, size: 16, color: Colors.orange.shade800),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${crossTeamExtra.length} cross-team order(s) from $otherTeam-booked reps with $_selectedTeamFilter products',
                      style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Line items that don\'t belong to $_selectedTeamFilter will be skipped — each team\'s billing software only sees its own SKUs.',
                style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant, fontStyle: FontStyle.italic),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Export CSV', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    // Merge the same-team picked orders with the cross-team orders that carry
    // this-team products. _buildCsv will skip any line items that don't
    // belong to this team, so mixed orders are automatically trimmed.
    final mergedExportOrders = <OrderModel>[...exportOrders, ...crossTeamExtra];
    final csv = _buildCsv(
      orders: mergedExportOrders,
      productMrpMap: mrpMap,
      productUnitPriceMap: unitPriceMap,
      productBillingNameMap: billingNameMap,
      userNameMap: userNameMap,
      exportDate: exportDate,
      invoicePrefix: invoicePrefix,
      invoiceStartNum: invoiceStartNum,
      teamProductIds: teamProductIds,
      teamProductSkus: teamProductSkus,
    );
    final dateLabel = _startDate != null || _endDate != null
        ? '_${_formatDate(_startDate).replaceAll('/', '-')}_to_${_formatDate(_endDate).replaceAll('/', '-')}'
        : '_all';
    final filename = 'orders_customer_wise$dateLabel.xls';

    triggerCsvDownload(csv, filename);
    Fluttertoast.showToast(msg: 'File downloaded: $filename');
  }

  Future<void> _downloadPdf() async {
    if (_filteredOrders.isEmpty) {
      Fluttertoast.showToast(msg: 'No orders to export');
      return;
    }

    // Exports must include every order matching the current date-range/team,
    // not just the paginated slice currently on screen.
    final fullyLoaded = await _ensureAllOrdersLoaded();
    if (!fullyLoaded || !mounted) return;

    setState(() => _generatingPdf = true);

    try {
      final pdf = pw.Document();
      final grouped = _groupByCustomer();

      // FIXED: Used standard hyphen instead of long dash
      final dateRangeLabel = (_startDate != null || _endDate != null)
          ? 'Date Range: ${_formatDate(_startDate)} - ${_formatDate(_endDate)}'
          : 'All Orders';

      final grandTotalAll = _filteredOrders.fold<double>(
        0,
        (sum, o) => sum + o.grandTotal,
      );

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(24),
          header: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Orders Report - Customer Wise',
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    'Generated: ${_formatDate(DateTime.now())}',
                    style: const pw.TextStyle(fontSize: 9),
                  ),
                ],
              ),
              pw.SizedBox(height: 4),
              pw.Text(dateRangeLabel, style: const pw.TextStyle(fontSize: 10)),
              pw.Divider(thickness: 1),
            ],
          ),
          footer: (context) => pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              // FIXED: Replaced ₹ with Rs.
              pw.Text(
                'Total Orders: ${_orders.length}  |  Grand Total: Rs. ${grandTotalAll.toStringAsFixed(2)}',
                style: const pw.TextStyle(fontSize: 9),
              ),
              pw.Text(
                'Page ${context.pageNumber} of ${context.pagesCount}',
                style: const pw.TextStyle(fontSize: 9),
              ),
            ],
          ),
          build: (context) {
            final widgets = <pw.Widget>[];

            for (final entry in grouped.entries) {
              final customerName = entry.key;
              final customerOrders = entry.value;
              final customerTotal = customerOrders.fold<double>(
                0,
                (sum, o) => sum + o.grandTotal,
              );

              widgets.add(
                pw.Container(
                  color: PdfColors.blueGrey800,
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        customerName,
                        style: pw.TextStyle(
                          fontSize: 11,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.white,
                        ),
                      ),
                      // FIXED: Replaced ₹ with Rs.
                      pw.Text(
                        '${customerOrders.length} order${customerOrders.length == 1 ? '' : 's'}  |  Rs. ${customerTotal.toStringAsFixed(2)}',
                        style: pw.TextStyle(
                          fontSize: 9,
                          color: PdfColors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              );

              for (final order in customerOrders) {
                final orderDate =
                    '${order.orderDate.day.toString().padLeft(2, '0')}/${order.orderDate.month.toString().padLeft(2, '0')}/${order.orderDate.year}';
                final deliveryDate = order.deliveryDate != null
                    ? '${order.deliveryDate!.day.toString().padLeft(2, '0')}/${order.deliveryDate!.month.toString().padLeft(2, '0')}/${order.deliveryDate!.year}'
                    : '-';

                widgets.add(
                  pw.Container(
                    color: PdfColors.grey200,
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: pw.Row(
                      children: [
                        pw.Expanded(
                          child: pw.Text(
                            'Order: ${order.id.length > 8 ? order.id.substring(0, 8) : order.id}...',
                            style: const pw.TextStyle(fontSize: 8),
                          ),
                        ),
                        pw.Text(
                          'Beat: ${order.beat}',
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                        pw.SizedBox(width: 12),
                        pw.Text(
                          'Date: $orderDate',
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                        pw.SizedBox(width: 12),
                        pw.Text(
                          'Delivery: $deliveryDate',
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                        pw.SizedBox(width: 12),
                        pw.Text(
                          'Status: ${order.status}',
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                      ],
                    ),
                  ),
                );

                if (order.lineItems.isNotEmpty) {
                  widgets.add(
                    pw.Table(
                      border: pw.TableBorder.all(
                        color: PdfColors.grey300,
                        width: 0.5,
                      ),
                      columnWidths: {
                        0: const pw.FlexColumnWidth(3),
                        1: const pw.FlexColumnWidth(2),
                        2: const pw.FixedColumnWidth(35),
                        3: const pw.FixedColumnWidth(55),
                        4: const pw.FixedColumnWidth(55),
                      },
                      children: [
                        pw.TableRow(
                          decoration: const pw.BoxDecoration(
                            color: PdfColors.grey100,
                          ),
                          children: [
                            _pdfCell('Product', isHeader: true),
                            _pdfCell('SKU', isHeader: true),
                            _pdfCell(
                              'Qty',
                              isHeader: true,
                              align: pw.Alignment.centerRight,
                            ),
                            _pdfCell(
                              'Unit Price',
                              isHeader: true,
                              align: pw.Alignment.centerRight,
                            ),
                            _pdfCell(
                              'Line Total',
                              isHeader: true,
                              align: pw.Alignment.centerRight,
                            ),
                          ],
                        ),
                        ...order.lineItems.map(
                          (item) => pw.TableRow(
                            children: [
                              _pdfCell(item.productName),
                              _pdfCell(item.sku),
                              _pdfCell(
                                '${item.quantity}',
                                align: pw.Alignment.centerRight,
                              ),
                              // FIXED: Replaced ₹ with Rs.
                              _pdfCell(
                                'Rs. ${item.unitPrice.toStringAsFixed(2)}',
                                align: pw.Alignment.centerRight,
                              ),
                              // FIXED: Replaced ₹ with Rs.
                              _pdfCell(
                                'Rs. ${item.lineTotal.toStringAsFixed(2)}',
                                align: pw.Alignment.centerRight,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }

                widgets.add(
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    alignment: pw.Alignment.centerRight,
                    // FIXED: Replaced ₹ with Rs.
                    child: pw.Text(
                      'Subtotal: Rs. ${order.subtotal.toStringAsFixed(2)}  |  GST: Rs. ${order.vat.toStringAsFixed(2)}  |  Grand Total: Rs. ${order.grandTotal.toStringAsFixed(2)}',
                      style: pw.TextStyle(
                        fontSize: 8,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                );

                widgets.add(pw.SizedBox(height: 4));
              }

              widgets.add(
                pw.Container(
                  color: PdfColors.blueGrey50,
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  alignment: pw.Alignment.centerRight,
                  // FIXED: Replaced ₹ with Rs. and long dash with normal dash
                  child: pw.Text(
                    'Customer Total - $customerName: Rs. ${customerTotal.toStringAsFixed(2)}',
                    style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              );

              widgets.add(pw.SizedBox(height: 10));
            }

            return widgets;
          },
        ),
      );

      final bytes = await pdf.save();
      final dateLabel = _startDate != null || _endDate != null
          ? '_${_formatDate(_startDate).replaceAll('/', '-')}_to_${_formatDate(_endDate).replaceAll('/', '-')}'
          : '_all';
      final statusLabel = _selectedStatus == 'All' ? '' : '_${_selectedStatus.toLowerCase()}';
      final filename = 'orders_customer_wise$dateLabel$statusLabel.pdf';

      if (kIsWeb) {
        triggerPdfDownload(bytes, filename);
        Fluttertoast.showToast(msg: 'PDF downloaded: $filename');
      } else {
        await Printing.sharePdf(bytes: bytes, filename: filename);
        Fluttertoast.showToast(msg: 'PDF ready: $filename');
      }
    } catch (e) {
      Fluttertoast.showToast(
        msg:
            'PDF generation failed: ${e.toString().substring(0, e.toString().length > 60 ? 60 : e.toString().length)}',
      );
    } finally {
      setState(() => _generatingPdf = false);
    }
  }

  pw.Widget _pdfCell(
    String text, {
    bool isHeader = false,
    pw.Alignment align = pw.Alignment.centerLeft,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      alignment: align,
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: 8,
          fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
        overflow: pw.TextOverflow.clip,
      ),
    );
  }

  Color _statusColor(String status) {
    return switch (status.toLowerCase()) {
      'pending' => AppTheme.warning,
      'confirmed' => Colors.blue,
      'delivered' => AppTheme.success,
      'invoiced' => Colors.teal,
      'paid' => Colors.green.shade700,
      'cancelled' => AppTheme.error,
      'returned' => Colors.red.shade700,
      'partially delivered' => Colors.orange,
      _ => AppTheme.primary,
    };
  }

  /// Shows a bottom sheet for admin to change order status with role enforcement.
  void _showStatusPicker(OrderModel order) {
    // statuses available based on role
    final available = _allStatuses
        .where((s) => s != 'All')
        .where((s) => _isSuperAdmin || !_adminOnlyStatuses.contains(s))
        .where((s) => s != order.status)
        .toList();

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Change Status — ${order.customerName}',
                style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Current: ${order.status}',
                style: GoogleFonts.manrope(
                    fontSize: 12, color: AppTheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: available.map((s) {
                final isDestructive = _adminOnlyStatuses.contains(s);
                return ActionChip(
                  label: Text(s),
                  backgroundColor: isDestructive
                      ? Colors.red.shade50
                      : Colors.blue.shade50,
                  labelStyle: TextStyle(
                    color: isDestructive ? Colors.red : Colors.blue.shade800,
                    fontWeight: FontWeight.w600,
                  ),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    try {
                      await _service.updateOrderStatus(
                          order.id, s, isSuperAdmin: _isSuperAdmin);
                      // Update status in-place without refetching
                      setState(() {
                        final idx = _orders.indexWhere((o) => o.id == order.id);
                        if (idx != -1) _orders[idx] = _orders[idx].copyWithStatus(s);
                        final fIdx = _filteredOrders.indexWhere((o) => o.id == order.id);
                        if (fIdx != -1) _filteredOrders[fIdx] = _filteredOrders[fIdx].copyWithStatus(s);
                      });
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('Order marked $s'),
                          backgroundColor:
                              isDestructive ? Colors.red : Colors.green,
                        ));
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('Error: $e'),
                          backgroundColor: AppTheme.error,
                        ));
                      }
                    }
                  },
                );
              }).toList(),
            ),
            if (!_isSuperAdmin)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Cancel / Return / Partial Delivery requires super_admin role.',
                  style: GoogleFonts.manrope(
                      fontSize: 11, color: AppTheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        // ── Date Filter Bar ──────────────────────────────────────
        SliverToBoxAdapter(child: Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Filter by Date',
                style: GoogleFonts.manrope(
                  fontSize: 14.0,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.onSurface,
                ),
              ),
              const SizedBox(height: 8.0),
              Row(
                children: [
                  Expanded(
                    child: _DatePickerButton(
                      label: 'From',
                      value: _formatDate(_startDate),
                      onTap: _pickStartDate,
                    ),
                  ),
                  const SizedBox(width: 8.0),
                  Expanded(
                    child: _DatePickerButton(
                      label: 'To',
                      value: _formatDate(_endDate),
                      onTap: _pickEndDate,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8.0),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10.0),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10.0),
                      ),
                      onPressed: _loading ? null : _loadOrders,
                      icon: const Icon(Icons.search_rounded, size: 16),
                      label: Text(
                        'Apply Filter',
                        style: GoogleFonts.manrope(
                          fontSize: 14.0,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  if (_startDate != null || _endDate != null) ...[
                    const SizedBox(width: 8.0),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.error,
                        side: BorderSide(color: AppTheme.error),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10.0),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10.0),
                      ),
                      onPressed: _clearFilter,
                      child: Text(
                        'Clear',
                        style: GoogleFonts.manrope(fontSize: 14.0),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        )),

        // Beat filter banner — shown only when a dashboard drill-through set
        // _beatFilter. Tap X to clear and see all orders in the period.
        if (_beatFilter != null)
          SliverToBoxAdapter(child: Container(
            color: AppTheme.primary.withValues(alpha: 0.08),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.filter_alt_rounded, size: 16, color: AppTheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Filtered to beat: ${_beatFilter!}',
                    style: GoogleFonts.manrope(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primary),
                  ),
                ),
                InkWell(
                  onTap: () {
                    setState(() => _beatFilter = null);
                    _applyStatusFilter();
                  },
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close_rounded, size: 18),
                  ),
                ),
              ],
            ),
          )),

        // Team Filter Chips (JA / MA)
        if (_hasFiltered && !_loading && _error == null)
          SliverToBoxAdapter(child: Container(
            color: AppTheme.surface,
            padding: const EdgeInsets.fromLTRB(12.0, 10.0, 12.0, 4.0),
            child: Row(
              children: ['JA', 'MA'].map((team) {
                final selected = _selectedTeamFilter == team;
                final label = team == 'JA' ? 'Jagannath' : 'Madhav';
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _selectedTeamFilter = team);
                      _loadOrders();
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: selected ? AppTheme.secondary : AppTheme.secondary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(label, style: GoogleFonts.manrope(
                        fontSize: 12, fontWeight: FontWeight.w600,
                        color: selected ? Colors.white : AppTheme.secondary,
                      )),
                    ),
                  ),
                );
              }).toList(),
            ),
          )),

        // ── Status Filter Chips ──────────────────────────────────
        if (_hasFiltered && !_loading && _error == null)
          SliverToBoxAdapter(child: Container(
            color: AppTheme.surface,
            padding: const EdgeInsets.fromLTRB(12.0, 8.0, 12.0, 4.0),
            child: SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: ['All', 'Pending', 'Confirmed', 'Invoiced', 'Delivered']
                    .map((status) {
                  final selected = _selectedStatus == status;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _selectedStatus = status);
                        _applyStatusFilter();
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: selected
                              ? AppTheme.primary
                              : AppTheme.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          status,
                          style: GoogleFonts.manrope(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: selected
                                ? Colors.white
                                : AppTheme.primary,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          )),

        // ── Summary + Download Bar ───────────────────────────────
        if (_hasFiltered && !_loading && _error == null)
          SliverToBoxAdapter(child: Container(
            color: AppTheme.surface,
            padding: const EdgeInsets.symmetric(
              horizontal: 12.0,
              vertical: 8.0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_filteredOrders.length}${_hasMore ? '+' : ''} order${_filteredOrders.length == 1 ? '' : 's'} found  •  ${_groupByCustomer().length} customer${_groupByCustomer().length == 1 ? '' : 's'}',
                  style: GoogleFonts.manrope(
                    fontSize: 14.0,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8.0),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.success,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10.0),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                        ),
                        onPressed: _downloadCsv,
                        icon: const Icon(Icons.table_chart_rounded, size: 15),
                        label: Text(
                          'Download CSV',
                          style: GoogleFonts.manrope(
                            fontSize: 13.0,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8.0),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFD32F2F),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10.0),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                        ),
                        onPressed: (_generatingPdf || _orders.isEmpty)
                            ? null
                            : _downloadPdf,
                        icon: _generatingPdf
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.picture_as_pdf_rounded,
                                size: 15,
                              ),
                        label: Text(
                          _generatingPdf ? 'Generating...' : 'Download PDF',
                          style: GoogleFonts.manrope(
                            fontSize: 13.0,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          )),

        // ── Orders List ──────────────────────────────────────────
        if (_loading)
          const SliverFillRemaining(child: Center(child: CircularProgressIndicator())),
        if (!_loading && _error != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 48),
                  const SizedBox(height: 8),
                  Text('Error loading orders', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.red)),
                  const SizedBox(height: 4),
                  Text(_error!, textAlign: TextAlign.center, style: GoogleFonts.manrope(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                    onPressed: _loadOrders,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text('Retry', style: GoogleFonts.manrope()),
                  ),
                ],
              ),
            ),
          ),
        if (!_loading && _error == null && _filteredOrders.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyStateWidget(
              icon: Icons.receipt_long_rounded,
              title: _hasFiltered ? 'No orders found' : 'No orders yet',
              description: _hasFiltered
                  ? 'Try adjusting your date range or status filter.'
                  : 'Orders will appear here once placed.',
            ),
          ),
        if (!_loading && _error == null && _filteredOrders.isNotEmpty)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final order = _filteredOrders[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: _OrderAdminCard(
                    order: order,
                    statusColor: _statusColor(order.status),
                    onChangeStatus: () => _showStatusPicker(order),
                  ),
                );
              },
              childCount: _filteredOrders.length,
            ),
          ),
        // Load More button
        if (!_loading && _hasMore && _filteredOrders.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
              child: _loadingMore
                  ? const Center(child: Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(),
                    ))
                  : OutlinedButton.icon(
                      onPressed: _loadMore,
                      icon: const Icon(Icons.expand_more_rounded),
                      label: Text('Load More Orders',
                          style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primary,
                        side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.3)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        minimumSize: const Size(double.infinity, 44),
                      ),
                    ),
            ),
          ),
        // Bottom padding
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

class _DatePickerButton extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _DatePickerButton({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.outline),
          borderRadius: BorderRadius.circular(10.0),
          color: Colors.white,
        ),
        child: Row(
          children: [
            Icon(
              Icons.calendar_today_rounded,
              size: 14,
              color: AppTheme.primary,
            ),
            const SizedBox(width: 6.0),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.manrope(
                      fontSize: 10.0,
                      color: AppTheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    value,
                    style: GoogleFonts.manrope(
                      fontSize: 13.0,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderAdminCard extends StatelessWidget {
  final OrderModel order;
  final Color statusColor;
  final VoidCallback? onChangeStatus;

  const _OrderAdminCard({
    required this.order,
    required this.statusColor,
    this.onChangeStatus,
  });

  @override
  Widget build(BuildContext context) {
    final orderDate =
        '${order.orderDate.day.toString().padLeft(2, '0')}/${order.orderDate.month.toString().padLeft(2, '0')}/${order.orderDate.year}';
    final deliveryDate = order.deliveryDate != null
        ? '${order.deliveryDate!.day.toString().padLeft(2, '0')}/${order.deliveryDate!.month.toString().padLeft(2, '0')}/${order.deliveryDate!.year}'
        : '-';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.0)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Order header row
            Row(
              children: [
                Expanded(
                  child: Text(
                    order.customerName,
                    style: GoogleFonts.manrope(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GestureDetector(
                  onTap: onChangeStatus,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: statusColor.withAlpha(31),
                      borderRadius: BorderRadius.circular(6.0),
                      border: onChangeStatus != null
                          ? Border.all(color: statusColor.withValues(alpha: 0.4), width: 0.8)
                          : null,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          order.status,
                          style: GoogleFonts.manrope(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: statusColor,
                          ),
                        ),
                        if (onChangeStatus != null) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.edit_outlined, size: 10, color: statusColor),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Order ID: ${order.id.length > 12 ? order.id.substring(0, 12) : order.id}...',
              style: GoogleFonts.manrope(
                fontSize: 10,
                color: AppTheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.map_rounded, size: 12, color: AppTheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(order.beat, style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.calendar_today_rounded, size: 12, color: AppTheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(orderDate, style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.local_shipping_rounded, size: 12, color: AppTheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(deliveryDate, style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                  ],
                ),
              ],
            ),
            if (order.lineItems.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 6),
              ...order.lineItems.map(
                (item) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(
                          item.productName,
                          style: GoogleFonts.manrope(
                            fontSize: 11,
                            color: AppTheme.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        'x${item.quantity}',
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          color: AppTheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '₹${item.lineTotal.toStringAsFixed(2)}',
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              runSpacing: 2,
              children: [
                Text(
                  'Subtotal: ₹${order.subtotal.toStringAsFixed(2)}  |  GST: ₹${order.vat.toStringAsFixed(2)}  |  ',
                  style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant),
                ),
                Text(
                  'Total: ₹${order.grandTotal.toStringAsFixed(2)}',
                  style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.onSurface),
                ),
              ],
            ),
            if (order.finalBillNo != null && order.finalBillNo!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.receipt_rounded, size: 12, color: AppTheme.success),
                  const SizedBox(width: 4),
                  Text(
                    'Bill No: ${order.finalBillNo}',
                    style: GoogleFonts.manrope(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.success,
                    ),
                  ),
                ],
              ),
            ],
            if (order.notes != null && order.notes!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Note: ${order.notes}',
                style: GoogleFonts.manrope(
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  color: AppTheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
