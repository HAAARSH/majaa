import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../services/billing_rules_service.dart';
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

  // Rules snapshot captured once per export. Set when the OI picker is
  // shown (line ~806) and consumed during _buildCsv (line ~1100), then
  // cleared. Without this shared ref, the 5-min cache TTL could expire
  // between the two dialogs and JA / MA CSVs might use inconsistent
  // merging strategies. Nullable so a non-OI export path still works.
  BillingRulesSnapshot? _cachedRulesSnapshot;

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
    // Phase C: Organic India per-customer routing override. When a customer
    // has a remembered/picked decision in [organicIndiaRouting], their OI
    // line items are routed to that team's CSV regardless of the product's
    // home team. Customers with no decision fall back to the default
    // product-catalog match (so OI products still go to their home team).
    Set<String>? organicIndiaKeys,
    Map<String, String>? organicIndiaRouting,
    String? csvTeamId,
    // Phase D: per-user role. brand_rep orders merge per-customer into a
    // single invoice; sales_rep orders stay one-invoice-per-order. If this
    // map is null or missing an entry, the order is treated as sales_rep
    // (safe default — never merges).
    Map<String, String>? userRoleMap,
    // Phase E: mutable sink the builder appends to for each order_items.id
    // that lands in this CSV (including every source id of a merged
    // brand_rep row). Ids are captured here at build time and persisted
    // server-side via the finalize_export_batch RPC after download.
    List<String>? writtenLineItemIdsSink,
    // Phase E: mutable sink for the order ids that had at least one line
    // written. Needed as the RPC's p_order_ids parameter.
    Set<String>? writtenOrderIdsSink,
    // Rules engine: how to group orders into invoices for this CSV.
    // Defaults to splitByRepRole so callers that haven't migrated (and
    // tests) get the legacy behaviour. New code should pass the value
    // from a BillingRulesSnapshot so per-team configuration applies.
    MergingStrategy mergingStrategy = MergingStrategy.splitByRepRole,
    // Customer-category rule: customers in this set NEVER merge. Their
    // orders stay one-invoice-per-order even when mergingStrategy would
    // otherwise merge them. Empty set (default) = rule disabled.
    Set<String> noMergeCustomerIds = const {},
  }) {
    final buffer = StringBuffer();
    const t = '\t';

    buffer.writeln(
      'Invoice No${t}Order ID${t}Order Date${t}Customer Name${t}Qty${t}Rep Name${t}Item Name${t}MRP${t}Unit Price${t}Item Discount${t}Discount${t}Item Gross Amount${t}Notes',
    );

    const months = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
    final dateStr = '="${exportDate.day.toString().padLeft(2, '0')}-${months[exportDate.month - 1]}-${exportDate.year}"';
    final bool scoped = teamProductIds != null && teamProductIds.isNotEmpty;
    final bool oiRoutingActive = organicIndiaKeys != null &&
        organicIndiaKeys.isNotEmpty &&
        organicIndiaRouting != null &&
        csvTeamId != null;

    bool itemBelongsToTeam(OrderItemModel item, String? customerId) {
      if (!scoped) return true;
      // Phase C: if this line is Organic India AND the customer has a
      // remembered/picked routing decision, that decision overrides the
      // product's home team. Customers with no decision fall through to
      // the default product-catalog match so OI still goes to its home team.
      if (oiRoutingActive) {
        final isOi = (item.productId != null &&
                organicIndiaKeys.contains(item.productId)) ||
            (item.sku.isNotEmpty && organicIndiaKeys.contains(item.sku));
        if (isOi && customerId != null && organicIndiaRouting.containsKey(customerId)) {
          return organicIndiaRouting[customerId] == csvTeamId;
        }
      }
      if (teamProductIds.contains(item.productId)) return true;
      if (teamProductSkus != null && item.sku.isNotEmpty && teamProductSkus.contains(item.sku)) return true;
      return false;
    }

    List<OrderItemModel> eligibleItemsOf(OrderModel o) {
      return scoped
          ? o.lineItems.where((i) => itemBelongsToTeam(i, o.customerId)).toList()
          : o.lineItems.toList();
    }

    String cleanNotes(String? raw) =>
        (raw ?? '').replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();

    // ── Route orders to the per-order path or the merge path based on
    // the configured merging strategy. The merge path = brandRepOrders
    // bucket; per-order path = salesRepOrders bucket.
    //   • splitByRepRole (legacy / JA): brand_rep merges per customer,
    //     sales_rep stays one-invoice-per-order.
    //   • mergeAllByCustomer: every order merges per customer.
    //   • noMerge: every order stays one-invoice-per-order.
    final salesRepOrders = <OrderModel>[];
    final brandRepOrders = <OrderModel>[];
    for (final o in orders) {
      // No-merge customer exception: force the per-order (sales_rep)
      // path regardless of team mergingStrategy. Set is populated from
      // billing_rules.no_merge_customer_ids for this team's CSV.
      if (o.customerId != null && noMergeCustomerIds.contains(o.customerId)) {
        salesRepOrders.add(o);
        continue;
      }
      switch (mergingStrategy) {
        case MergingStrategy.mergeAllByCustomer:
          brandRepOrders.add(o);
          break;
        case MergingStrategy.noMerge:
          salesRepOrders.add(o);
          break;
        case MergingStrategy.splitByRepRole:
          final uid = o.userId;
          final role = (uid != null && userRoleMap != null) ? userRoleMap[uid] : null;
          if (role == 'brand_rep') {
            brandRepOrders.add(o);
          } else {
            salesRepOrders.add(o);
          }
          break;
      }
    }

    // Stable invoice order: sales_rep first (by date then id), then
    // brand_rep groups (by customer_name).
    salesRepOrders.sort((a, b) {
      final d = a.orderDate.compareTo(b.orderDate);
      return d != 0 ? d : a.id.compareTo(b.id);
    });

    int invoiceCounter = invoiceStartNum ?? 0;

    // ── Part 1: sales_rep orders — one invoice per order (legacy path) ─
    for (final o in salesRepOrders) {
      final eligibleItems = eligibleItemsOf(o);
      if (scoped && eligibleItems.isEmpty) continue;

      final invoiceNo = (invoicePrefix != null && invoiceStartNum != null)
          ? '$invoicePrefix${invoiceCounter++}'
          : '';
      final repName = (o.userId != null ? userNameMap[o.userId] : null) ?? '';
      final notes = cleanNotes(o.notes);

      if (eligibleItems.isEmpty) {
        buffer.writeln(
          '$invoiceNo$t${o.id}$t$dateStr$t${o.customerName}${t}0$t$repName$t${t}0.00${t}0.00${t}0.00${t}0.00${t}0.00$t$notes',
        );
        writtenOrderIdsSink?.add(o.id);
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
          final iid = item.id;
          if (iid != null && iid.isNotEmpty) writtenLineItemIdsSink?.add(iid);
        }
        writtenOrderIdsSink?.add(o.id);
      }
    }

    // ── Part 2: brand_rep orders grouped per-customer into ONE invoice ─
    // Key: customer_id when present, else id-fallback so null-customer
    // orders don't silently collapse together.
    final brandRepByCustomer = <String, List<OrderModel>>{};
    for (final o in brandRepOrders) {
      final key = (o.customerId != null && o.customerId!.isNotEmpty)
          ? o.customerId!
          : '__noid_${o.id}';
      brandRepByCustomer.putIfAbsent(key, () => []).add(o);
    }
    final brandRepGroups = brandRepByCustomer.values.toList()
      ..sort((a, b) => a.first.customerName.compareTo(b.first.customerName));

    for (final group in brandRepGroups) {
      // Collect eligible items across every order in this customer's group.
      final allItems = <OrderItemModel>[];
      final orderIds = <String>[];
      final noteParts = <String>[];
      for (final o in group) {
        final eligible = eligibleItemsOf(o);
        if (eligible.isEmpty) continue;
        allItems.addAll(eligible);
        orderIds.add(o.id);
        writtenOrderIdsSink?.add(o.id);
        // Every source line-item id gets tracked even though they collapse
        // into fewer rows post-combine — the RPC's fully-exported check
        // counts ids, not rows.
        for (final it in eligible) {
          final iid = it.id;
          if (iid != null && iid.isNotEmpty) writtenLineItemIdsSink?.add(iid);
        }
        final n = cleanNotes(o.notes);
        if (n.isNotEmpty) noteParts.add(n);
      }
      if (allItems.isEmpty) continue;

      // Combine identical lines within the group (same product, same
      // order-time unit price). Different prices stay as separate rows so
      // price-change history is preserved on the merged invoice.
      final combined = _combineBrandRepLines(allItems);

      final invoiceNo = (invoicePrefix != null && invoiceStartNum != null)
          ? '$invoicePrefix${invoiceCounter++}'
          : '';
      final customerName = group.first.customerName;
      final orderIdList = orderIds.join(',');
      final notesStr = noteParts.join('; ');

      // Rep-name on the merged invoice. For the legacy splitByRepRole
      // strategy this path only ever ran for brand_rep orders, so the
      // historical literal "Brand Rep" stays correct. Under
      // mergeAllByCustomer (MA's new behaviour) the group can contain
      // sales_rep + brand_rep + multiple distinct reps — keep commission
      // visibility by using the rep's name when it's a single rep, and
      // "Multiple" when it isn't.
      String mergedRepName;
      if (mergingStrategy == MergingStrategy.mergeAllByCustomer) {
        final uniqueRepNames = group
            .map((o) => o.userId)
            .where((id) => id != null && id.isNotEmpty)
            .map((id) => userNameMap[id!] ?? '')
            .where((n) => n.isNotEmpty)
            .toSet();
        if (uniqueRepNames.length == 1) {
          mergedRepName = uniqueRepNames.first;
        } else if (uniqueRepNames.isEmpty) {
          mergedRepName = 'Brand Rep';
        } else {
          mergedRepName = 'Multiple';
        }
      } else {
        mergedRepName = 'Brand Rep';
      }

      for (final line in combined) {
        final item = line.representative;
        final mrp = item.mrp > 0
            ? item.mrp
            : (productMrpMap[item.productId] ?? productMrpMap[item.sku] ?? 0.0);
        // Merged rows use the order-time unit price (the grouping key) so
        // the invoice reflects what was booked, not what the master price
        // is today. Sum of stored line_totals is the gross for the row.
        final unitPrice = item.unitPrice;
        final itemName = productBillingNameMap[item.productId] ??
            productBillingNameMap[item.sku] ??
            item.productName;
        final grossAmount = line.lineTotalSum > 0
            ? line.lineTotalSum
            : line.quantitySum * unitPrice;
        buffer.writeln(
          '$invoiceNo$t$orderIdList$t$dateStr$t$customerName$t${line.quantitySum}$t$mergedRepName$t$itemName$t${mrp.toStringAsFixed(2)}$t${unitPrice.toStringAsFixed(2)}${t}0.00${t}0.00$t${grossAmount.toStringAsFixed(2)}$t$notesStr',
        );
      }
    }

    return buffer.toString();
  }

  /// Phase D: combine line items within a brand_rep customer group.
  /// Items sharing the SAME (product_id OR sku) AND SAME unit_price
  /// collapse into one row with summed quantity and summed line_total.
  /// Different prices for the same product stay as separate rows to
  /// preserve price-change history on the merged invoice.
  List<_MergedBrandRepLine> _combineBrandRepLines(List<OrderItemModel> items) {
    final buckets = <String, _MergedBrandRepLine>{};
    final order = <String>[]; // keep insertion order for stable output
    for (final it in items) {
      final productKey = (it.productId != null && it.productId!.isNotEmpty)
          ? 'p:${it.productId}'
          : (it.sku.isNotEmpty ? 's:${it.sku}' : 'n:${it.productName}');
      // 4-decimal rounding so float-jitter doesn't split what should merge.
      final priceKey = it.unitPrice.toStringAsFixed(4);
      final key = '$productKey|$priceKey';
      final existing = buckets[key];
      if (existing == null) {
        buckets[key] = _MergedBrandRepLine(
          representative: it,
          quantitySum: it.quantity,
          lineTotalSum: it.lineTotal,
        );
        order.add(key);
      } else {
        existing.quantitySum += it.quantity;
        existing.lineTotalSum += it.lineTotal;
      }
    }
    return [for (final k in order) buckets[k]!];
  }

  // Dual-team export (Phase B of ORDERS_EXPORT_OVERHAUL_PLAN).
  // One click → TWO files: JA{DD}{MM}.xls and MA{DD}{MM}.xls.
  // The UI team filter (_selectedTeamFilter) is intentionally IGNORED here
  // — admin always gets both teams' invoices. Line items are routed to a
  // team's CSV by the product's home team (via teamProductIds). Organic
  // India per-customer routing is deferred to Phase C.
  Future<void> _downloadCsv() async {
    // ─── Step 1: status picker (unchanged semantics) ─────────────────────
    String exportStatus = 'Pending';
    final statusResult = await showDialog<String?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Export Orders', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Select which orders to export (both teams)',
                  style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: exportStatus,
                decoration: InputDecoration(
                  labelText: 'Order Status',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                items: ['Pending', 'All', 'Delivered']
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
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
      ),
    );
    if (statusResult == null) return;

    // ─── Step 2: fetch BOTH teams' orders (bypassing the paginated _orders
    //     list which is team-filtered for UI). ──────────────────────────
    Fluttertoast.showToast(msg: 'Loading orders from both teams…');
    List<OrderModel> jaOrders = const [];
    List<OrderModel> maOrders = const [];
    try {
      final results = await Future.wait([
        _service.getOrdersByDateRange(
          startDate: _startDate, endDate: _endDate, teamId: 'JA', limit: 10000),
        _service.getOrdersByDateRange(
          startDate: _startDate, endDate: _endDate, teamId: 'MA', limit: 10000),
      ]);
      jaOrders = results[0];
      maOrders = results[1];
    } catch (e) {
      Fluttertoast.showToast(msg: 'Failed to load orders: $e');
      return;
    }
    if (!mounted) return;

    final bothTeamsOrders = <OrderModel>[...jaOrders, ...maOrders];
    final statusFilteredOrders = statusResult == 'All'
        ? bothTeamsOrders
        : bothTeamsOrders
            .where((o) => o.status.toLowerCase() == statusResult.toLowerCase())
            .toList();
    if (statusFilteredOrders.isEmpty) {
      Fluttertoast.showToast(msg: 'No $statusResult orders to export');
      return;
    }

    // ─── Step 3: fetch BOTH teams' products and index them ──────────────
    final productFetches = await Future.wait([
      _service.getProducts(teamId: 'JA'),
      _service.getProducts(teamId: 'MA'),
    ]);
    final jaProducts = _indexTeamProducts(productFetches[0]);
    final maProducts = _indexTeamProducts(productFetches[1]);

    // ─── Step 4: beat picker — unified beats across both teams with
    //     JA/MA counts per beat. ───────────────────────────────────────
    final jaBeatCount = <String, int>{};
    final maBeatCount = <String, int>{};
    for (final o in statusFilteredOrders) {
      if (o.beat.isEmpty) continue;
      if (o.teamId == 'JA') {
        jaBeatCount[o.beat] = (jaBeatCount[o.beat] ?? 0) + 1;
      } else {
        maBeatCount[o.beat] = (maBeatCount[o.beat] ?? 0) + 1;
      }
    }
    final beats = {...jaBeatCount.keys, ...maBeatCount.keys}.toList()..sort();
    if (beats.isEmpty) {
      Fluttertoast.showToast(msg: 'No beats found in $statusResult orders');
      return;
    }
    final selectedBeats = <String>{...beats};
    final beatResult = await showDialog<Set<String>?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
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
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx).size.height * 0.6,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: beats.length,
                      itemBuilder: (_, i) {
                        final beat = beats[i];
                        final jaCount = jaBeatCount[beat] ?? 0;
                        final maCount = maBeatCount[beat] ?? 0;
                        final parts = <String>[];
                        if (jaCount > 0) parts.add('$jaCount JA');
                        if (maCount > 0) parts.add('$maCount MA');
                        final totalOrders = jaCount + maCount;
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
      ),
    );
    if (beatResult == null || beatResult.isEmpty) return;

    final beatFilteredOrders = statusFilteredOrders
        .where((o) => beatResult.contains(o.beat))
        .toList();
    if (beatFilteredOrders.isEmpty) {
      Fluttertoast.showToast(msg: 'No orders for selected beats');
      return;
    }

    // ─── Step 4.5 (Phase C): Organic India per-customer routing ─────────
    // OI items can go to either JA or MA billing depending on the customer
    // (Pharmacy → JA default, other → MA default; admin can override and
    // the choice is remembered in customer_brand_routing).
    final organicIndiaKeys = <String>{};
    for (final p in productFetches[0]) {
      if (_isOrganicIndia(p)) {
        organicIndiaKeys.add(p.id);
        if (p.sku.isNotEmpty) organicIndiaKeys.add(p.sku);
      }
    }
    for (final p in productFetches[1]) {
      if (_isOrganicIndia(p)) {
        organicIndiaKeys.add(p.id);
        if (p.sku.isNotEmpty) organicIndiaKeys.add(p.sku);
      }
    }

    Map<String, String> organicIndiaRouting = const {};
    if (organicIndiaKeys.isNotEmpty) {
      // Which customers in this export have at least one OI line item?
      final oiCustomerIds = <String>{};
      for (final o in beatFilteredOrders) {
        final cid = o.customerId;
        if (cid == null || cid.isEmpty) continue;
        final hasOi = o.lineItems.any((it) {
          if (it.productId != null && organicIndiaKeys.contains(it.productId)) return true;
          if (it.sku.isNotEmpty && organicIndiaKeys.contains(it.sku)) return true;
          return false;
        });
        if (hasOi) oiCustomerIds.add(cid);
      }

      if (oiCustomerIds.isNotEmpty) {
        // Capture rules ONCE at the start of the export flow and thread
        // the snapshot through both the OI picker and the CSV build.
        // Previously each called snapshotForExport() independently,
        // risking mid-export drift if the cache TTL lapsed between
        // dialog steps (admin takes >5 min at the OI picker).
        final rulesSnapshot = await BillingRulesService.instance.snapshotForExport();
        _cachedRulesSnapshot = rulesSnapshot;
        final decisions = await _showOrganicIndiaPicker(
          oiCustomerIds,
          rulesSnapshot: rulesSnapshot,
        );
        if (decisions == null) return; // admin cancelled
        organicIndiaRouting = decisions;
      }
    }

    // ─── Step 5: dual invoice number inputs (JA + MA) ───────────────────
    final jaInvoiceCtl = TextEditingController();
    final maInvoiceCtl = TextEditingController();
    final invoiceResult = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Starting Invoice Numbers', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Enter each team\'s starting invoice (e.g. INV420). Leave a field blank to skip numbering for that file.',
              style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: jaInvoiceCtl,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'JA starting invoice',
                hintText: 'e.g. INV420',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: maInvoiceCtl,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'MA starting invoice',
                hintText: 'e.g. INVM100',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
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
            child: Text('Next', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (invoiceResult != true) return;

    final invoiceRe = RegExp(r'^([A-Za-z]*)(\d+)$');
    String? jaPrefix;
    int? jaStart;
    if (jaInvoiceCtl.text.trim().isNotEmpty) {
      final m = invoiceRe.firstMatch(jaInvoiceCtl.text.trim());
      if (m == null) {
        Fluttertoast.showToast(msg: 'Invalid JA invoice format. Use like INV420');
        return;
      }
      jaPrefix = m.group(1)!;
      jaStart = int.parse(m.group(2)!);
    }
    String? maPrefix;
    int? maStart;
    if (maInvoiceCtl.text.trim().isNotEmpty) {
      final m = invoiceRe.firstMatch(maInvoiceCtl.text.trim());
      if (m == null) {
        Fluttertoast.showToast(msg: 'Invalid MA invoice format. Use like INVM100');
        return;
      }
      maPrefix = m.group(1)!;
      maStart = int.parse(m.group(2)!);
    }

    // ─── Step 6: export date picker (DUA Clipper wants DD-MMM-YYYY) ─────
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now().subtract(const Duration(days: 1)),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: 'Select invoice date (shared across both files)',
    );
    if (pickedDate == null) return;
    final exportDate = pickedDate;

    // ─── Step 7: user-name + role lookup (role needed by Phase D merge) ─
    final users = await _service.getAppUsers(allTeams: true);
    final userNameMap = <String, String>{};
    final userRoleMap = <String, String>{};
    for (final u in users) {
      userNameMap[u.id] = u.fullName;
      userRoleMap[u.id] = u.role;
    }
    final unmatchedIds = beatFilteredOrders
        .where((o) => o.userId != null && !userNameMap.containsKey(o.userId))
        .map((o) => o.userId!)
        .toSet();
    for (final uid in unmatchedIds) {
      final name = await _service.getUserFullName(uid);
      if (name != null) userNameMap[uid] = name;
    }

    // ─── Step 7.5: customer acc_code lookups per team. ──────────────────
    // The exported CSV has no acc_code column — DUA Clipper matches by
    // customer name. We still count customers whose acc_code_<team> field
    // is blank so admins can cross-check those customers exist in the
    // team's DUA before importing. No orders are skipped based on this.
    final allCustomers = await _service.getCustomers();
    final jaAccCodeByCustomer = <String, String>{};
    final maAccCodeByCustomer = <String, String>{};
    for (final c in allCustomers) {
      final ja = c.accCodeJa;
      final ma = c.accCodeMa;
      if (ja != null && ja.trim().isNotEmpty) jaAccCodeByCustomer[c.id] = ja;
      if (ma != null && ma.trim().isNotEmpty) maAccCodeByCustomer[c.id] = ma;
    }

    bool customerHasAccCodeInTeam(String? customerId, String team) {
      if (customerId == null || customerId.isEmpty) return true;
      final m = team == 'JA' ? jaAccCodeByCustomer : maAccCodeByCustomer;
      return m.containsKey(customerId);
    }

    // ─── Step 8: compute per-team bucket stats for the summary ──────────
    // An order counts for team X's CSV when it has at least one line that
    // routes to X after OI override (Phase C). Cross-team = order booked
    // by the OTHER team but landing in this team's file. Orders for
    // customers without acc_code_<team> still export — that count is
    // surfaced as an informational note.
    int jaOrderCount = 0, jaCrossCount = 0;
    int maOrderCount = 0, maCrossCount = 0;
    int jaMissingAcc = 0, maMissingAcc = 0;
    for (final o in beatFilteredOrders) {
      final jaAcc = customerHasAccCodeInTeam(o.customerId, 'JA');
      final maAcc = customerHasAccCodeInTeam(o.customerId, 'MA');
      final hasJaLine = o.lineItems.any((it) => _itemRoutesToTeam(
            it, o.customerId, 'JA', jaProducts, organicIndiaKeys, organicIndiaRouting));
      final hasMaLine = o.lineItems.any((it) => _itemRoutesToTeam(
            it, o.customerId, 'MA', maProducts, organicIndiaKeys, organicIndiaRouting));
      if (hasJaLine && !jaAcc) jaMissingAcc++;
      if (hasMaLine && !maAcc) maMissingAcc++;
      if (hasJaLine) {
        jaOrderCount++;
        if (o.teamId != 'JA') jaCrossCount++;
      }
      if (hasMaLine) {
        maOrderCount++;
        if (o.teamId != 'MA') maCrossCount++;
      }
    }

    // ─── Step 9: summary dialog with skip-file checkboxes ───────────────
    bool buildJa = jaOrderCount > 0;
    bool buildMa = maOrderCount > 0;
    final jaFileName = _teamExportFilename('JA', exportDate);
    final maFileName = _teamExportFilename('MA', exportDate);

    final summaryResult = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Export Summary', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // JA block
                CheckboxListTile(
                  dense: true,
                  value: buildJa,
                  onChanged: jaOrderCount == 0
                      ? null
                      : (v) => setDialogState(() => buildJa = v ?? false),
                  title: Text(jaFileName, style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 14)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        jaOrderCount == 0
                            ? 'No orders have JA line items'
                            : '$jaOrderCount order(s) with JA line items'
                              '${jaCrossCount > 0 ? ' (incl. $jaCrossCount cross-team from MA reps)' : ''}',
                        style: GoogleFonts.manrope(fontSize: 12),
                      ),
                      if (jaMissingAcc > 0)
                        Text(
                          'ℹ $jaMissingAcc exported without JA acc_code — verify customer exists in JA DUA Clipper',
                          style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
                        ),
                      Text(
                        'Starting invoice: ${jaPrefix != null ? '$jaPrefix$jaStart' : '(none)'}',
                        style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 4),
                // MA block
                CheckboxListTile(
                  dense: true,
                  value: buildMa,
                  onChanged: maOrderCount == 0
                      ? null
                      : (v) => setDialogState(() => buildMa = v ?? false),
                  title: Text(maFileName, style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 14)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        maOrderCount == 0
                            ? 'No orders have MA line items'
                            : '$maOrderCount order(s) with MA line items'
                              '${maCrossCount > 0 ? ' (incl. $maCrossCount cross-team from JA reps)' : ''}',
                        style: GoogleFonts.manrope(fontSize: 12),
                      ),
                      if (maMissingAcc > 0)
                        Text(
                          'ℹ $maMissingAcc exported without MA acc_code — verify customer exists in MA DUA Clipper',
                          style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
                        ),
                      Text(
                        'Starting invoice: ${maPrefix != null ? '$maPrefix$maStart' : '(none)'}',
                        style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Uncheck a box to skip that team\'s file. Each CSV contains only its own team\'s products — cross-team line items are routed automatically.',
                  style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
            ),
            FilledButton(
              onPressed: (!buildJa && !buildMa)
                  ? null
                  : () => Navigator.pop(ctx, true),
              child: Text('Export', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
    if (summaryResult != true) return;

    // ─── Step 10: build CSVs and bundle for a single share sheet ────────
    final filesToDownload = <MapEntry<String, String>>[];

    // Merge product lookup maps across both teams so OI items routed across
    // teams (e.g. a JA-catalog OI product going to MA CSV per customer
    // override) still find their MRP / unit-price / billing-name refresh.
    // Team-scoping of WHICH lines go in each CSV is governed separately by
    // teamProductIds/teamProductSkus and organicIndiaRouting.
    final mergedMrp = <String, double>{...jaProducts.mrp, ...maProducts.mrp};
    final mergedUnitPrice = <String, double>{
      ...jaProducts.unitPrice,
      ...maProducts.unitPrice,
    };
    final mergedBillingName = <String, String>{
      ...jaProducts.billingName,
      ...maProducts.billingName,
    };

    // Phase E sinks: capture every order_items.id + order.id that lands in
    // either CSV so the post-export RPC can persist the tracking state.
    final writtenLineItemIds = <String>{};
    final writtenOrderIds = <String>{};
    int jaWrittenOrderCount = 0;
    int maWrittenOrderCount = 0;

    // Re-use the snapshot captured at the top of the export flow (OI
    // picker path) if available; otherwise the OI picker wasn't needed
    // and we take a fresh snapshot now. Either way, every _buildCsv
    // call below uses the SAME snapshot so JA + MA CSVs never disagree.
    final rulesSnapshot = _cachedRulesSnapshot
        ?? await BillingRulesService.instance.snapshotForExport();
    _cachedRulesSnapshot = null; // release the ref; no longer needed.

    if (buildJa && jaOrderCount > 0) {
      final jaLineSink = <String>[];
      final jaOrderSink = <String>{};
      final csv = _buildCsv(
        orders: beatFilteredOrders,
        productMrpMap: mergedMrp,
        productUnitPriceMap: mergedUnitPrice,
        productBillingNameMap: mergedBillingName,
        userNameMap: userNameMap,
        exportDate: exportDate,
        invoicePrefix: jaPrefix,
        invoiceStartNum: jaStart,
        teamProductIds: jaProducts.ids,
        teamProductSkus: jaProducts.skus,
        organicIndiaKeys: organicIndiaKeys,
        organicIndiaRouting: organicIndiaRouting,
        csvTeamId: 'JA',
        userRoleMap: userRoleMap,
        writtenLineItemIdsSink: jaLineSink,
        writtenOrderIdsSink: jaOrderSink,
        mergingStrategy: rulesSnapshot.mergingFor('JA'),
        noMergeCustomerIds: rulesSnapshot.noMergeCustomerIdsFor('JA'),
      );
      filesToDownload.add(MapEntry(jaFileName, csv));
      writtenLineItemIds.addAll(jaLineSink);
      writtenOrderIds.addAll(jaOrderSink);
      jaWrittenOrderCount = jaOrderSink.length;
    }
    if (buildMa && maOrderCount > 0) {
      final maLineSink = <String>[];
      final maOrderSink = <String>{};
      final csv = _buildCsv(
        orders: beatFilteredOrders,
        productMrpMap: mergedMrp,
        productUnitPriceMap: mergedUnitPrice,
        productBillingNameMap: mergedBillingName,
        userNameMap: userNameMap,
        exportDate: exportDate,
        invoicePrefix: maPrefix,
        invoiceStartNum: maStart,
        teamProductIds: maProducts.ids,
        teamProductSkus: maProducts.skus,
        organicIndiaKeys: organicIndiaKeys,
        organicIndiaRouting: organicIndiaRouting,
        csvTeamId: 'MA',
        userRoleMap: userRoleMap,
        writtenLineItemIdsSink: maLineSink,
        writtenOrderIdsSink: maOrderSink,
        mergingStrategy: rulesSnapshot.mergingFor('MA'),
        noMergeCustomerIds: rulesSnapshot.noMergeCustomerIdsFor('MA'),
      );
      filesToDownload.add(MapEntry(maFileName, csv));
      writtenLineItemIds.addAll(maLineSink);
      writtenOrderIds.addAll(maOrderSink);
      maWrittenOrderCount = maOrderSink.length;
    }

    if (filesToDownload.isEmpty) {
      Fluttertoast.showToast(msg: 'Nothing to export');
      return;
    }

    await triggerMultiCsvDownload(filesToDownload);
    Fluttertoast.showToast(
      msg: 'Downloaded: ${filesToDownload.map((e) => e.key).join(', ')}',
    );

    // ─── Step 11 (Phase E): post-export "Mark as Delivered" dialog ──────
    if (!mounted) return;
    await _showPostExportDialog(
      filesToDownload: filesToDownload,
      jaWrittenOrderCount: jaWrittenOrderCount,
      maWrittenOrderCount: maWrittenOrderCount,
      writtenOrderIds: writtenOrderIds,
      writtenLineItemIds: writtenLineItemIds,
      ordersById: {for (final o in beatFilteredOrders) o.id: o},
      invoiceDate: exportDate,
      jaFileName: buildJa ? jaFileName : null,
      maFileName: buildMa ? maFileName : null,
      jaInvoiceRange: buildJa && jaPrefix != null
          ? _invoiceRangeLabel(jaPrefix, jaStart!, jaWrittenOrderCount)
          : null,
      maInvoiceRange: buildMa && maPrefix != null
          ? _invoiceRangeLabel(maPrefix, maStart!, maWrittenOrderCount)
          : null,
      statusFilter: statusResult,
    );
  }

  // ─── Dual-team export helpers ─────────────────────────────────────────

  String _teamExportFilename(String teamCode, DateTime exportDate) {
    final dd = exportDate.day.toString().padLeft(2, '0');
    final mm = exportDate.month.toString().padLeft(2, '0');
    return '$teamCode$dd$mm.xls';
  }

  _TeamProductIndex _indexTeamProducts(List<ProductModel> products) {
    final idx = _TeamProductIndex();
    for (final p in products) {
      idx.ids.add(p.id);
      idx.mrp[p.id] = p.mrp;
      idx.unitPrice[p.id] = p.unitPrice;
      idx.billingName[p.id] = p.billingName ?? p.name;
      if (p.sku.isNotEmpty) {
        idx.skus.add(p.sku);
        idx.mrp[p.sku] = p.mrp;
        idx.unitPrice[p.sku] = p.unitPrice;
        idx.billingName[p.sku] = p.billingName ?? p.name;
      }
    }
    return idx;
  }

  bool _itemInTeam(OrderItemModel it, _TeamProductIndex idx) {
    if (it.productId != null && idx.ids.contains(it.productId)) return true;
    if (it.sku.isNotEmpty && idx.skus.contains(it.sku)) return true;
    return false;
  }

  // Phase C: is this product an Organic India item? Category is the
  // authoritative signal (plan mandate). Trim + lowercase to match what
  // product_categories.name uses.
  static const _organicIndiaBrandName = 'Organic India';
  bool _isOrganicIndia(ProductModel p) =>
      p.category.trim().toLowerCase() == _organicIndiaBrandName.toLowerCase();

  /// Does this line item route to [csvTeamId] given the OI override?
  /// Mirrors the rule inside _buildCsv.itemBelongsToTeam so summary counts
  /// match what actually lands in each file.
  bool _itemRoutesToTeam(
    OrderItemModel it,
    String? customerId,
    String csvTeamId,
    _TeamProductIndex sameTeamIdx,
    Set<String> oiKeys,
    Map<String, String> oiRouting,
  ) {
    if (oiKeys.isNotEmpty) {
      final isOi = (it.productId != null && oiKeys.contains(it.productId)) ||
          (it.sku.isNotEmpty && oiKeys.contains(it.sku));
      if (isOi && customerId != null && oiRouting.containsKey(customerId)) {
        return oiRouting[customerId] == csvTeamId;
      }
    }
    return _itemInTeam(it, sameTeamIdx);
  }

  /// Organic India per-customer routing picker.
  /// - Loads existing `customer_brand_routing` rows for the given customers.
  /// - Fills in the default for each customer (Pharmacy → JA, else MA).
  /// - Lets admin toggle per customer, optionally persist as "remember".
  /// - Returns customer_id → 'JA'|'MA' on confirm, or null on cancel.
  Future<Map<String, String>?> _showOrganicIndiaPicker(
    Iterable<String> customerIds, {
    // Passed in from the export flow so the OI picker and the later
    // CSV build share ONE snapshot of the rules. Without this, a long
    // admin pause in this dialog could let the 5-min cache TTL expire
    // and the CSV build (line ~1100) re-fetch different rule values.
    required BillingRulesSnapshot rulesSnapshot,
  }) async {
    final allCustomers = await _service.getCustomers();
    final customersById = <String, CustomerModel>{
      for (final c in allCustomers) c.id: c,
    };
    final remembered = await _service.getBrandRouting(
      brandName: _organicIndiaBrandName,
      customerIds: customerIds,
    );

    // Sort by customer name for stable presentation.
    final sortedCustomers = customerIds
        .where((id) => customersById.containsKey(id))
        .map((id) => customersById[id]!)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    if (sortedCustomers.isEmpty) {
      // OI items exist but customers couldn't be resolved — fall back to
      // defaults without pestering the admin.
      debugPrint('[OI Picker] No resolvable customers for ids=$customerIds');
      return const {};
    }

    final decisions = <String, String>{
      for (final c in sortedCustomers)
        c.id: remembered[c.id] ?? rulesSnapshot.organicIndiaDefaultFor(c.type),
    };
    bool rememberChoices = true;

    if (!mounted) return null;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Organic India Billing', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Organic India items found for ${sortedCustomers.length} customer(s). Pick which team each customer bills under.',
                  style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant),
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.55,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: sortedCustomers.length,
                    itemBuilder: (_, i) {
                      final c = sortedCustomers[i];
                      final current = decisions[c.id] ?? 'MA';
                      final wasRemembered = remembered.containsKey(c.id);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    c.name,
                                    style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    '${c.type}${wasRemembered ? ' · remembered' : ''}',
                                    style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 4),
                            ToggleButtons(
                              constraints: const BoxConstraints(minWidth: 40, minHeight: 30),
                              borderRadius: BorderRadius.circular(8),
                              isSelected: [current == 'JA', current == 'MA'],
                              onPressed: (idx) {
                                setDialogState(() {
                                  decisions[c.id] = idx == 0 ? 'JA' : 'MA';
                                });
                              },
                              children: const [
                                Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('JA')),
                                Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('MA')),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const Divider(height: 16),
                Row(
                  children: [
                    // Rule-driven reset: reads organic_india_default_by_
                    // customer_type from billing_rules via the snapshot we
                    // already captured. Replaces the old hardcoded
                    // "All Pharmacy → JA" shortcut which ignored admin
                    // edits to the rule. If admin changes the rule to
                    // route pharmacy → MA, this button respects it.
                    OutlinedButton(
                      onPressed: () {
                        setDialogState(() {
                          for (final c in sortedCustomers) {
                            decisions[c.id] =
                                rulesSnapshot.organicIndiaDefaultFor(c.type);
                          }
                        });
                      },
                      child: Text('Reset to rule defaults',
                          style: GoogleFonts.manrope(fontSize: 11)),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () {
                        setDialogState(() {
                          for (final c in sortedCustomers) {
                            decisions[c.id] = 'MA';
                          }
                        });
                      },
                      child: Text('Set all to MA',
                          style: GoogleFonts.manrope(fontSize: 11)),
                    ),
                  ],
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: rememberChoices,
                  onChanged: (v) => setDialogState(() => rememberChoices = v ?? false),
                  title: Text('Remember these choices for next time',
                      style: GoogleFonts.manrope(fontSize: 12)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Continue', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return null;

    if (rememberChoices) {
      try {
        await _service.upsertBrandRouting(
          brandName: _organicIndiaBrandName,
          decisions: decisions,
        );
      } catch (e) {
        // Surfacing the failure is better than silently losing the choice —
        // the decisions still apply to THIS export, just won't persist.
        Fluttertoast.showToast(
          msg: 'Could not save routing preferences: $e',
          toastLength: Toast.LENGTH_LONG,
        );
      }
    }
    return decisions;
  }

  /// Phase E: label like "INV420..INV453" for display. On 0 orders returns
  /// just the starting value so admin isn't confused.
  String _invoiceRangeLabel(String prefix, int start, int count) {
    if (count <= 0) return '$prefix$start';
    if (count == 1) return '$prefix$start';
    return '$prefix$start..$prefix${start + count - 1}';
  }

  /// Phase E: "Export Complete" dialog. Shows per-file order counts + a
  /// fully-vs-partial preview, then calls finalize_export_batch regardless
  /// of admin's choice so line-item tracking is always persisted. Only the
  /// `p_mark_delivered` flag toggles on Confirm vs Cancel.
  Future<void> _showPostExportDialog({
    required List<MapEntry<String, String>> filesToDownload,
    required int jaWrittenOrderCount,
    required int maWrittenOrderCount,
    required Set<String> writtenOrderIds,
    required Set<String> writtenLineItemIds,
    required Map<String, OrderModel> ordersById,
    required DateTime invoiceDate,
    required String? jaFileName,
    required String? maFileName,
    required String? jaInvoiceRange,
    required String? maInvoiceRange,
    required String statusFilter,
  }) async {
    // Client-side preview of fully-vs-partial. The RPC authoritatively
    // re-computes server-side; these numbers just help admin decide
    // whether to tick "mark Delivered".
    int fullCount = 0;
    int partialCount = 0;
    for (final oid in writtenOrderIds) {
      final o = ordersById[oid];
      if (o == null) continue;
      final totalLines = o.lineItems.length;
      if (totalLines == 0) continue; // empty orders never "fully export"
      final already = o.exportedLineItemIds.toSet();
      final itemIdsInOrder = o.lineItems
          .map((it) => it.id)
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toSet();
      final newlyForThisOrder =
          itemIdsInOrder.where(writtenLineItemIds.contains).toSet();
      final cumulative = {...already, ...newlyForThisOrder};
      // intersect with actual line-item ids so stale entries don't inflate
      final match = cumulative.intersection(itemIdsInOrder);
      if (match.length == totalLines && totalLines > 0) {
        fullCount++;
      } else {
        partialCount++;
      }
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Export Complete', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Downloaded:', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              if (jaFileName != null)
                Text('✓ $jaFileName — $jaWrittenOrderCount order(s)'
                    '${jaInvoiceRange != null ? ' · $jaInvoiceRange' : ''}',
                    style: GoogleFonts.manrope(fontSize: 12)),
              if (maFileName != null)
                Text('✓ $maFileName — $maWrittenOrderCount order(s)'
                    '${maInvoiceRange != null ? ' · $maInvoiceRange' : ''}',
                    style: GoogleFonts.manrope(fontSize: 12)),
              const SizedBox(height: 12),
              Text('Of these:', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('• $fullCount order(s) FULLY exported — every line item covered.',
                  style: GoogleFonts.manrope(fontSize: 12)),
              Text('• $partialCount order(s) PARTIALLY exported — waiting on remaining line items.',
                  style: GoogleFonts.manrope(fontSize: 12)),
              const SizedBox(height: 12),
              Text(
                fullCount == 0
                    ? 'No fully-exported orders to mark as Delivered.'
                    : 'Mark the $fullCount fully-exported order(s) as Delivered? Partial orders stay Pending and flip automatically when their remaining items get exported.',
                style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(fullCount == 0 ? 'Close' : 'Cancel',
                style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
          ),
          if (fullCount > 0)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Yes, mark Delivered',
                  style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
            ),
        ],
      ),
    );

    // RPC call runs either way so line-item tracking is persisted even
    // when admin declines the status flip. result == null is impossible
    // (barrierDismissible is false) but defend anyway.
    final markDelivered = result == true;
    try {
      await _service.finalizeExportBatch(
        orderIds: writtenOrderIds.toList(),
        lineItemIdsWritten: writtenLineItemIds.toList(),
        markDelivered: markDelivered,
        batchMetadata: {
          'invoice_date': '${invoiceDate.year}-${invoiceDate.month.toString().padLeft(2, '0')}-${invoiceDate.day.toString().padLeft(2, '0')}',
          if (jaFileName != null) 'ja_file_name': jaFileName,
          if (maFileName != null) 'ma_file_name': maFileName,
          if (jaInvoiceRange != null) 'ja_invoice_range': jaInvoiceRange,
          if (maInvoiceRange != null) 'ma_invoice_range': maInvoiceRange,
          'status_filter': statusFilter,
          if (_startDate != null)
            'date_range_start':
                '${_startDate!.year}-${_startDate!.month.toString().padLeft(2, '0')}-${_startDate!.day.toString().padLeft(2, '0')}',
          if (_endDate != null)
            'date_range_end':
                '${_endDate!.year}-${_endDate!.month.toString().padLeft(2, '0')}-${_endDate!.day.toString().padLeft(2, '0')}',
        },
      );
      if (mounted) {
        Fluttertoast.showToast(
          msg: markDelivered
              ? 'Batch recorded. $fullCount order(s) marked Delivered.'
              : 'Batch recorded. Statuses unchanged.',
        );
      }
      if (markDelivered && fullCount > 0) {
        // Refresh the Orders tab so the admin sees new statuses immediately.
        await _loadOrders();
      }
    } catch (e) {
      if (mounted) {
        Fluttertoast.showToast(
          msg: 'Export saved locally but batch log failed: $e',
          toastLength: Toast.LENGTH_LONG,
        );
      }
    }
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
                      // Pass team so JA-authed admin editing MA via filter
                      // hits the right team_id row instead of silently no-op'ing.
                      await _service.updateOrderStatus(
                          order.id, s,
                          isSuperAdmin: _isSuperAdmin,
                          teamId: _selectedTeamFilter);
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

// Product-index scratchpad for dual-team export. Holds a team's products
// keyed by product id AND by sku (SKU is a secondary key so legacy order
// items that lost their product_id can still be routed via SKU match).
class _TeamProductIndex {
  final Set<String> ids = <String>{};
  final Set<String> skus = <String>{};
  final Map<String, double> mrp = <String, double>{};
  final Map<String, double> unitPrice = <String, double>{};
  final Map<String, String> billingName = <String, String>{};
}

// Phase D: one merged row inside a brand_rep-per-customer invoice.
// Representative keeps the original line's product/sku/name/unit-price so
// the merged row renders with the same identity as the originals.
class _MergedBrandRepLine {
  final OrderItemModel representative;
  int quantitySum;
  double lineTotalSum;
  _MergedBrandRepLine({
    required this.representative,
    required this.quantitySum,
    required this.lineTotalSum,
  });
}
