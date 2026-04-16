import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import '../../../services/supabase_service.dart';
import '../../../services/auth_service.dart';
import '../../../services/bill_extraction_service.dart';
import '../../../services/csv_reconciliation_service.dart';
import '../../../services/drive_sync_service.dart';
import '../../../theme/app_theme.dart';
import './admin_shared_widgets.dart';

class AdminBillVerificationTab extends StatefulWidget {
  const AdminBillVerificationTab({super.key});

  @override
  State<AdminBillVerificationTab> createState() => _AdminBillVerificationTabState();
}

class _AdminBillVerificationTabState extends State<AdminBillVerificationTab> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Pending + Returned orders
  List<Map<String, dynamic>> _pendingOrders = [];
  List<Map<String, dynamic>> _returnedOrders = [];
  bool _ordersLoading = true;

  // Item matching
  List<Map<String, dynamic>> _unmatchedItems = [];
  bool _itemsLoading = false;

  // Customer matching
  List<Map<String, dynamic>> _unmatchedCustomers = [];
  bool _customersLoading = false;

  // Upload state
  bool _uploading = false;
  String _uploadStatus = '';

  // CSV reconciliation
  List<Map<String, dynamic>> _dataChanges = [];
  bool _csvLoading = false;

  // Stock sync pending changes (new products + price changes from ITMRP)
  List<Map<String, dynamic>> _pendingNewProducts = [];
  List<Map<String, dynamic>> _pendingPriceChanges = [];

  // Customer sync pending changes (new + changed from ACMAST)
  List<Map<String, dynamic>> _pendingNewCustomers = [];
  List<Map<String, dynamic>> _pendingChangedCustomers = [];
  List<Map<String, dynamic>> _accCodeMismatches = [];

  // Date filter for uploads
  DateTime? _filterStartDate;
  DateTime? _filterEndDate;

  // Products + Customers for dropdowns
  List<Map<String, dynamic>> _allProducts = [];
  List<Map<String, dynamic>> _allCustomers = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) _loadTabData(_tabController.index);
    });
    _loadOrders();
    _loadDropdownData();
    _loadDriveDiscrepancies();
    _loadStockSyncPendingChanges();
    _loadCustomerSyncPendingChanges();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadDropdownData() async {
    try {
      final products = await SupabaseService.instance.getProducts();
      final customers = await SupabaseService.instance.getCustomers();
      if (mounted) {
        setState(() {
          _allProducts = products.map((p) => {'id': p.id, 'name': p.name}).toList();
          _allCustomers = customers.map((c) => {'id': c.id, 'name': c.name}).toList();
        });
      }
    } catch (_) {}
  }

  void _loadTabData(int index) {
    switch (index) {
      case 5: _loadUnmatchedItems(); break;
      case 6: _loadUnmatchedCustomers(); break;
    }
  }

  // ─── LOAD DRIVE DISCREPANCIES ─────────────────────────────────
  Future<void> _loadDriveDiscrepancies() async {
    try {
      final discrepancies = await DriveSyncService.instance.getDriveDiscrepancies();
      if (discrepancies.isNotEmpty && mounted) {
        setState(() {
          _dataChanges = [..._dataChanges, ...discrepancies];
        });
      }
    } catch (_) {}
  }

  // ─── LOAD STOCK SYNC PENDING CHANGES ────────────────────────
  Future<void> _loadStockSyncPendingChanges() async {
    final result = DriveSyncService.instance.lastStockSyncResult;
    if (result != null && mounted) {
      setState(() {
        _pendingNewProducts = List<Map<String, dynamic>>.from(result.newProducts);
        _pendingPriceChanges = List<Map<String, dynamic>>.from(result.priceChanges);
      });
    }
  }

  // ─── LOAD CUSTOMER SYNC PENDING CHANGES ─────────────────────
  Future<void> _loadCustomerSyncPendingChanges() async {
    final result = DriveSyncService.instance.lastCustomerSyncResult;
    if (result != null && mounted) {
      setState(() {
        _pendingNewCustomers = List<Map<String, dynamic>>.from(result.newCustomers);
        _accCodeMismatches = List<Map<String, dynamic>>.from(result.accCodeMismatches);
        // Changed customers are now auto-applied, no pending list
        _pendingChangedCustomers = [];
      });
    }
  }

  // ─── LOAD ORDERS ─────────────────────────────────────────────

  Future<void> _loadOrders() async {
    setState(() => _ordersLoading = true);
    try {
      final cols = 'id, customer_name, customer_id, billed_no, invoice_amount, final_bill_no, actual_billed_amount, bill_photo_url, verified_by_delivery, verified_by_office, status, team_id, order_date, grand_total';
      final team = AuthService.currentTeam;
      final results = await Future.wait([
        SupabaseService.instance.client.from('orders').select(cols)
            .eq('team_id', team).eq('status', 'Pending Verification').order('order_date', ascending: false),
        SupabaseService.instance.client.from('orders').select(cols)
            .eq('team_id', team).eq('status', 'Returned').order('order_date', ascending: false),
        SupabaseService.instance.client.from('orders').select(cols)
            .eq('team_id', team).eq('status', 'Delivered').eq('verified_by_office', false).order('order_date', ascending: false),
      ]);
      if (!mounted) return;
      setState(() {
        _pendingOrders = [...List<Map<String, dynamic>>.from(results[0]), ...List<Map<String, dynamic>>.from(results[2])];
        _returnedOrders = List<Map<String, dynamic>>.from(results[1]);
        _ordersLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _ordersLoading = false);
    }
  }

  // ─── LOAD UNMATCHED ITEMS ────────────────────────────────────

  Future<void> _loadUnmatchedItems() async {
    setState(() => _itemsLoading = true);
    try {
      final items = await BillExtractionService.instance.getUnmatchedItems();
      if (mounted) setState(() { _unmatchedItems = items; _itemsLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _itemsLoading = false);
    }
  }

  // ─── LOAD UNMATCHED CUSTOMERS ────────────────────────────────

  Future<void> _loadUnmatchedCustomers() async {
    setState(() => _customersLoading = true);
    try {
      final custs = await BillExtractionService.instance.getUnmatchedCustomers();
      if (mounted) setState(() { _unmatchedCustomers = custs; _customersLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _customersLoading = false);
    }
  }

  // ─── PDF UPLOAD + EXTRACTION ─────────────────────────────────

  Future<void> _uploadPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null && file.path == null) return;

    setState(() { _uploading = true; _uploadStatus = 'Reading file...'; });

    try {
      final Uint8List bytes;
      if (file.bytes != null) {
        bytes = file.bytes!;
      } else {
        // On mobile, read from path
        final f = await File(file.path!).readAsBytes();
        bytes = f;
      }

      // Detect mime type from file extension
      final ext = (file.extension ?? '').toLowerCase();
      final mimeType = switch (ext) {
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        _ => 'image/jpeg',
      };

      setState(() => _uploadStatus = 'Sending to Gemini OCR...');

      final bills = await BillExtractionService.instance.extractBillsFromImage(
        bytes,
        mimeType: mimeType,
        onProgress: (current, total) {
          if (mounted) {
            setState(() => _uploadStatus = total > 1
                ? 'Processing chunk $current of $total...'
                : 'Processing document...');
          }
        },
      );

      setState(() => _uploadStatus = 'Saving ${bills.length} bills...');

      final saved = await BillExtractionService.instance.saveExtractedBills(bills);

      setState(() {
        _uploading = false;
        _uploadStatus = '';
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Extracted & saved $saved bills'), backgroundColor: Colors.green),
        );
        _loadOrders();
        _loadUnmatchedItems();
        _loadUnmatchedCustomers();
      }
    } catch (e) {
      setState(() { _uploading = false; _uploadStatus = ''; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ─── VERIFY ORDER ────────────────────────────────────────────

  void _showVerifyDialog(Map<String, dynamic> order) {
    final ocrBillCtrl = TextEditingController(text: order['billed_no'] as String? ?? order['final_bill_no'] as String? ?? '');
    final ocrAmountCtrl = TextEditingController(text: order['invoice_amount']?.toString() ?? order['actual_billed_amount']?.toString() ?? '');
    final notesCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom + 16, left: 20, right: 20, top: 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Verify Bill', style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w800)),
                Text(order['customer_name'] ?? '', style: GoogleFonts.manrope(fontSize: 14, color: AppTheme.onSurfaceVariant)),
                const SizedBox(height: 12),

                // Photo viewer (if exists)
                if (order['bill_photo_url'] != null && (order['bill_photo_url'] as String).isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(order['bill_photo_url'] as String, height: 150, width: double.infinity, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(height: 100, color: Colors.grey.shade100, child: const Center(child: Icon(Icons.broken_image_rounded, size: 36)))),
                  ),
                  const SizedBox(height: 12),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.orange.shade200)),
                    child: Row(children: [
                      const Icon(Icons.warning_rounded, color: Colors.orange, size: 18),
                      const SizedBox(width: 10),
                      Expanded(child: Text('No bill photo. Enter details manually.', style: GoogleFonts.manrope(fontSize: 12, color: Colors.orange.shade800))),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ],

                // Bill number + amount — ALWAYS shown
                TextField(
                  controller: ocrBillCtrl,
                  decoration: const InputDecoration(labelText: 'Bill Number *', border: OutlineInputBorder(), prefixIcon: Icon(Icons.receipt_long_rounded)),
                  onChanged: (_) => setS(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ocrAmountCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Invoice Amount (\u20B9) *', border: OutlineInputBorder(), prefixIcon: Icon(Icons.currency_rupee_rounded)),
                  onChanged: (_) => setS(() {}),
                ),
                const SizedBox(height: 12),
                TextField(controller: notesCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes (optional)', border: OutlineInputBorder())),
                const SizedBox(height: 16),

                // Actions
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _flagOrder(order['id'] as String, notesCtrl.text.trim());
                      },
                      icon: const Icon(Icons.flag_rounded, color: Colors.orange),
                      label: const Text('Flag'),
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.orange, padding: const EdgeInsets.symmetric(vertical: 14)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () async {
                        if (ocrBillCtrl.text.trim().isEmpty || ocrAmountCtrl.text.trim().isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Bill number and amount required'), backgroundColor: Colors.red));
                          return;
                        }
                        Navigator.pop(ctx);
                        await _approveOrder(order['id'] as String, ocrBillCtrl.text.trim(), double.tryParse(ocrAmountCtrl.text.trim()), notesCtrl.text.trim());
                      },
                      icon: const Icon(Icons.check_circle_rounded),
                      label: const Text('Approve'),
                      style: FilledButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.symmetric(vertical: 14)),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    ).then((_) {
      ocrBillCtrl.dispose();
      ocrAmountCtrl.dispose();
      notesCtrl.dispose();
    });
  }

  Future<void> _approveOrder(String orderId, String finalBillNo, double? finalAmount, String notes) async {
    if (finalBillNo.isEmpty || finalAmount == null) return;
    try {
      final svc = SupabaseService.instance;
      final teamId = AuthService.currentTeam;

      final order = await svc.client.from('orders').select('customer_id, bill_photo_url').eq('id', orderId).single();
      final customerId = order['customer_id'] as String?;
      final currentPhotoUrl = order['bill_photo_url'] as String?;

      await svc.client.from('orders').update({
        'final_bill_no': finalBillNo,
        'actual_billed_amount': finalAmount,
        'billed_no': finalBillNo,
        'invoice_amount': finalAmount,
        'verified_by_office': true,
        'status': 'Verified',
        if (notes.isNotEmpty) 'notes': notes,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', orderId);

      // CHANGED: unified profile — update team-specific outstanding
      if (customerId != null) {
        final outCol = teamId == 'JA' ? 'outstanding_ja' : 'outstanding_ma';
        final profile = await svc.client.from('customer_team_profiles')
            .select(outCol).eq('customer_id', customerId).maybeSingle();
        if (profile != null) {
          final balance = (profile[outCol] as num?)?.toDouble() ?? 0.0;
          await svc.client.from('customer_team_profiles')
              .update({outCol: balance + finalAmount}).eq('customer_id', customerId);
        }
      }

      if (currentPhotoUrl != null && currentPhotoUrl.isNotEmpty) {
        final newUrl = await svc.renameBillPhoto(currentPhotoUrl, finalBillNo);
        if (newUrl != null) await svc.client.from('orders').update({'bill_photo_url': newUrl}).eq('id', orderId);
      }

      await svc.invalidateCache('customers');
      await svc.invalidateCache('recent_orders');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bill $finalBillNo verified'), backgroundColor: Colors.green));
        _loadOrders();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
    }
  }

  Future<void> _flagOrder(String orderId, String notes) async {
    try {
      await SupabaseService.instance.client.from('orders').update({
        'status': 'Flagged',
        if (notes.isNotEmpty) 'notes': notes,
      }).eq('id', orderId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Order flagged'), backgroundColor: Colors.orange));
        _loadOrders();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
    }
  }

  // ─── BUILD ───────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Tab bar
        Container(
          color: AppTheme.surface,
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            labelStyle: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 12),
            unselectedLabelStyle: GoogleFonts.manrope(fontWeight: FontWeight.w500, fontSize: 12),
            labelColor: AppTheme.primary,
            unselectedLabelColor: AppTheme.onSurfaceVariant,
            indicatorColor: AppTheme.primary,
            tabs: [
              Tab(text: 'Pending (${_pendingOrders.length})'),
              Tab(text: 'Returned (${_returnedOrders.length})'),
              const Tab(text: 'Upload PDF'),
              const Tab(text: 'Upload CSV'),
              Tab(text: 'Data Changes (${_dataChanges.length + _pendingNewProducts.length + _pendingPriceChanges.length + _pendingNewCustomers.length + _pendingChangedCustomers.length + _accCodeMismatches.length})'),
              Tab(text: 'Item Match (${_unmatchedItems.length})'),
              Tab(text: 'Customers (${_unmatchedCustomers.length})'),
            ],
          ),
        ),
        // Tab content
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildOrderList(_pendingOrders, isPending: true),
              _buildOrderList(_returnedOrders, isPending: false),
              _buildUploadTab(),
              _buildCsvUploadTab(),
              _buildDataChangesTab(),
              _buildItemMatchTab(),
              _buildCustomerMatchTab(),
            ],
          ),
        ),
      ],
    );
  }

  // ─── ORDER LIST (Pending / Returned) ─────────────────────────

  Widget _buildOrderList(List<Map<String, dynamic>> orders, {required bool isPending}) {
    if (_ordersLoading) return const Center(child: CircularProgressIndicator());
    if (orders.isEmpty) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(isPending ? Icons.verified_rounded : Icons.assignment_return_rounded, size: 56, color: isPending ? Colors.green : Colors.orange),
        const SizedBox(height: 12),
        Text(isPending ? 'All caught up!' : 'No returned orders', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w800)),
      ]));
    }

    return RefreshIndicator(
      onRefresh: _loadOrders,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: orders.length,
        itemBuilder: (ctx, i) {
          final o = orders[i];
          final status = o['status'] as String? ?? '';
          final isReturned = status == 'Returned';
          final billNo = o['billed_no'] as String? ?? o['final_bill_no'] as String? ?? '';
          final amount = (o['invoice_amount'] as num?)?.toDouble() ?? (o['actual_billed_amount'] as num?)?.toDouble() ?? (o['grand_total'] as num?)?.toDouble();
          final hasPhoto = o['bill_photo_url'] != null && (o['bill_photo_url'] as String).isNotEmpty;
          final name = o['customer_name'] as String? ?? 'Unknown';
          final dateStr = o['order_date'] != null ? DateFormat('dd MMM').format(DateTime.parse(o['order_date'] as String)) : '';

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isReturned ? Colors.orange.shade50 : AppTheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: isReturned ? Colors.orange.shade300 : AppTheme.outlineVariant),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 36, height: 36, decoration: BoxDecoration(
                  color: hasPhoto ? Colors.blue.shade50 : (isReturned ? Colors.orange.shade100 : Colors.grey.shade100),
                  borderRadius: BorderRadius.circular(8)),
                  child: Icon(hasPhoto ? Icons.photo_rounded : (isReturned ? Icons.assignment_return_rounded : Icons.no_photography_rounded),
                    color: hasPhoto ? Colors.blue : (isReturned ? Colors.orange.shade700 : Colors.grey), size: 18)),
                const SizedBox(width: 10),
                Expanded(child: Text(name, style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 14))),
                Text('\u20B9${amount?.toStringAsFixed(0) ?? '0'}', style: GoogleFonts.manrope(fontWeight: FontWeight.w800, fontSize: 14, color: isReturned ? Colors.orange.shade700 : AppTheme.primary)),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                if (billNo.isNotEmpty) Text('Bill: $billNo  •  ', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                Text(dateStr, style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                if (!hasPhoto && !isReturned) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.warning_amber_rounded, size: 12, color: Colors.grey.shade500),
                  const SizedBox(width: 2),
                  Text('No photo', style: GoogleFonts.manrope(fontSize: 10, color: Colors.grey.shade500)),
                ],
              ]),
              const SizedBox(height: 10),
              SizedBox(width: double.infinity, child: FilledButton.icon(
                onPressed: () => _showVerifyDialog(o),
                icon: Icon(isReturned ? Icons.edit_rounded : Icons.check_circle_rounded, size: 16),
                label: Text(isReturned ? 'Add Bill Details' : (hasPhoto ? 'Verify Bill' : 'Enter Manually'), style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 12)),
                style: FilledButton.styleFrom(backgroundColor: isReturned ? Colors.orange.shade700 : AppTheme.primary, padding: const EdgeInsets.symmetric(vertical: 10), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              )),
            ]),
          );
        },
      ),
    );
  }

  // ─── UPLOAD BILLS TAB ────────────────────────────────────────

  Widget _buildDateRangeFilter() {
    final fmt = DateFormat('dd MMM yyyy');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppTheme.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.outlineVariant)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Date Range Filter (optional)', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: () async {
              final d = await showDatePicker(context: context, initialDate: _filterStartDate ?? DateTime.now(), firstDate: DateTime(2024), lastDate: DateTime.now());
              if (d != null) setState(() => _filterStartDate = d);
            },
            icon: const Icon(Icons.calendar_today_rounded, size: 14),
            label: Text(_filterStartDate != null ? fmt.format(_filterStartDate!) : 'From', style: GoogleFonts.manrope(fontSize: 12)),
          )),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(
            onPressed: () async {
              final d = await showDatePicker(context: context, initialDate: _filterEndDate ?? DateTime.now(), firstDate: DateTime(2024), lastDate: DateTime.now());
              if (d != null) setState(() => _filterEndDate = d);
            },
            icon: const Icon(Icons.calendar_today_rounded, size: 14),
            label: Text(_filterEndDate != null ? fmt.format(_filterEndDate!) : 'To', style: GoogleFonts.manrope(fontSize: 12)),
          )),
          if (_filterStartDate != null || _filterEndDate != null)
            IconButton(icon: const Icon(Icons.clear_rounded, size: 18), onPressed: () => setState(() { _filterStartDate = null; _filterEndDate = null; })),
        ]),
      ]),
    );
  }

  Widget _buildUploadTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        Icon(Icons.upload_file_rounded, size: 56, color: AppTheme.primary.withAlpha(150)),
        const SizedBox(height: 12),
        Text('Upload Daily Bills', style: GoogleFonts.manrope(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text('Upload PDF or image. Gemini OCR extracts bill data.\nUse date filter to process only bills within a range.',
          textAlign: TextAlign.center, style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant, height: 1.5)),
        const SizedBox(height: 20),
        _buildDateRangeFilter(),
        const SizedBox(height: 20),
        if (_uploading) ...[
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(_uploadStatus, style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant)),
        ] else
          SizedBox(width: double.infinity, child: FilledButton.icon(
            onPressed: _uploadPdf,
            icon: const Icon(Icons.cloud_upload_rounded),
            label: Text('Select PDF / Image', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          )),
      ]),
    );
  }

  // ─── ITEM MATCH TAB ──────────────────────────────────────────

  Widget _buildItemMatchTab() {
    if (_itemsLoading) return const Center(child: CircularProgressIndicator());
    if (_unmatchedItems.isEmpty) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.check_circle_rounded, size: 56, color: Colors.green),
        const SizedBox(height: 12),
        Text('All items matched!', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w800)),
        Text('No unmatched billed items', style: GoogleFonts.manrope(color: AppTheme.onSurfaceVariant)),
      ]));
    }

    return RefreshIndicator(
      onRefresh: _loadUnmatchedItems,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _unmatchedItems.length,
        itemBuilder: (ctx, i) {
          final item = _unmatchedItems[i];
          final itemName = item['billed_item_name'] as String? ?? '';
          final billNo = item['bill_no'] as String? ?? '';
          final qty = item['quantity'];
          final amount = item['amount'];

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.amber.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.amber.shade200)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: Colors.amber.shade700, borderRadius: BorderRadius.circular(6)),
                  child: Text('UNMATCHED', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white))),
                const SizedBox(width: 8),
                Text('Bill: $billNo', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
              ]),
              const SizedBox(height: 8),
              Text(itemName, style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700)),
              if (qty != null || amount != null)
                Text('Qty: ${qty ?? '-'}  •  \u20B9${amount ?? '-'}', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
              const SizedBox(height: 10),
              // Product dropdown
              Autocomplete<Map<String, dynamic>>(
                optionsBuilder: (textEditingValue) {
                  if (textEditingValue.text.isEmpty) return _allProducts;
                  return _allProducts.where((p) => (p['name'] as String).toLowerCase().contains(textEditingValue.text.toLowerCase()));
                },
                displayStringForOption: (p) => p['name'] as String,
                onSelected: (product) async {
                  await BillExtractionService.instance.matchItem(item['id'] as String, product['id'] as String, itemName);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Matched "$itemName" → ${product['name']}'), backgroundColor: Colors.green));
                    _loadUnmatchedItems();
                  }
                },
                fieldViewBuilder: (ctx, ctrl, fn, onSubmit) => TextField(
                  controller: ctrl, focusNode: fn,
                  style: GoogleFonts.manrope(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search product to link...', isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    suffixIcon: IconButton(icon: const Icon(Icons.add_rounded, size: 18), tooltip: 'Add as new product',
                      onPressed: () => _addNewProduct(itemName, item)),
                  ),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }

  Future<void> _addNewProduct(String itemName, Map<String, dynamic> item) async {
    try {
      await SupabaseService.instance.addProduct({
        'name': itemName,
        'sku': item['hsn_code'] ?? '',
        'category': 'Uncategorized',
        'unit_price': (item['mrp'] as num?)?.toDouble() ?? 0,
        'gst_rate': (item['gst_rate'] as num?)?.toDouble() ?? 0,
      });
      // Re-fetch products and match
      await _loadDropdownData();
      final newProduct = _allProducts.where((p) => (p['name'] as String).toLowerCase() == itemName.toLowerCase()).firstOrNull;
      if (newProduct != null) {
        await BillExtractionService.instance.matchItem(item['id'] as String, newProduct['id'] as String, itemName);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added "$itemName" as new product'), backgroundColor: Colors.green));
        _loadUnmatchedItems();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
    }
  }

  // ─── CUSTOMER MATCH TAB ──────────────────────────────────────

  Widget _buildCustomerMatchTab() {
    if (_customersLoading) return const Center(child: CircularProgressIndicator());
    if (_unmatchedCustomers.isEmpty) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.check_circle_rounded, size: 56, color: Colors.green),
        const SizedBox(height: 12),
        Text('All customers matched!', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w800)),
        Text('No unmatched customer names', style: GoogleFonts.manrope(color: AppTheme.onSurfaceVariant)),
      ]));
    }

    return RefreshIndicator(
      onRefresh: _loadUnmatchedCustomers,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _unmatchedCustomers.length,
        itemBuilder: (ctx, i) {
          final extraction = _unmatchedCustomers[i];
          final ocrName = extraction['customer_name_ocr'] as String? ?? '';
          final billNo = extraction['bill_no'] as String? ?? '';
          final grandTotal = extraction['grand_total'];

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.purple.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.purple.shade200)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: Colors.purple.shade700, borderRadius: BorderRadius.circular(6)),
                  child: Text('UNMATCHED', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white))),
                const SizedBox(width: 8),
                Text('Bill: $billNo', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
              ]),
              const SizedBox(height: 8),
              Text(ocrName, style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700)),
              if (grandTotal != null)
                Text('\u20B9${(grandTotal as num).toStringAsFixed(0)}', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.primary)),
              const SizedBox(height: 10),
              Autocomplete<Map<String, dynamic>>(
                optionsBuilder: (textEditingValue) {
                  if (textEditingValue.text.isEmpty) return _allCustomers;
                  return _allCustomers.where((c) => (c['name'] as String).toLowerCase().contains(textEditingValue.text.toLowerCase()));
                },
                displayStringForOption: (c) => c['name'] as String,
                onSelected: (customer) async {
                  await BillExtractionService.instance.matchCustomer(extraction['id'] as String, customer['id'] as String);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Matched "$ocrName" → ${customer['name']}'), backgroundColor: Colors.green));
                    _loadUnmatchedCustomers();
                  }
                },
                fieldViewBuilder: (ctx, ctrl, fn, onSubmit) => TextField(
                  controller: ctrl, focusNode: fn,
                  style: GoogleFonts.manrope(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search customer to link...', isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  ),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }

  // ─── CSV UPLOAD TAB ──────────────────────────────────────────

  Widget _buildCsvUploadTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        Icon(Icons.table_chart_rounded, size: 56, color: Colors.teal.withAlpha(150)),
        const SizedBox(height: 12),
        Text('Upload Billing CSV', style: GoogleFonts.manrope(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text('Upload ITTR CSV. System compares against app data.\nUse date filter to process only a specific range.',
          textAlign: TextAlign.center, style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant, height: 1.5)),
        const SizedBox(height: 20),
        _buildDateRangeFilter(),
        const SizedBox(height: 20),
        if (_csvLoading) ...[
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text('Processing CSV...', style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant)),
        ] else
          SizedBox(width: double.infinity, child: FilledButton.icon(
            onPressed: _uploadCsv,
            icon: const Icon(Icons.upload_file_rounded),
            label: Text('Select CSV File', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
            style: FilledButton.styleFrom(backgroundColor: Colors.teal, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          )),
      ]),
    );
  }

  Future<void> _uploadCsv() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
    if (result == null || result.files.isEmpty) return;

    setState(() => _csvLoading = true);

    try {
      String csvContent;
      if (result.files.first.bytes != null) {
        csvContent = utf8.decode(result.files.first.bytes!);
      } else {
        csvContent = await File(result.files.first.path!).readAsString();
      }

      var bills = CsvReconciliationService.instance.parseCsv(csvContent);
      debugPrint('Parsed ${bills.length} bills from CSV');

      // Apply date filter if set
      if (_filterStartDate != null || _filterEndDate != null) {
        bills = bills.where((b) {
          final dateStr = b['date'] as String? ?? '';
          if (dateStr.isEmpty) return false;
          // Parse DD/MM/YYYY or YYYY-MM-DD
          DateTime? d;
          if (dateStr.contains('/')) {
            final parts = dateStr.split('/');
            if (parts.length == 3) d = DateTime.tryParse('${parts[2]}-${parts[1].padLeft(2, "0")}-${parts[0].padLeft(2, "0")}');
          } else {
            d = DateTime.tryParse(dateStr);
          }
          if (d == null) return true; // Include if can't parse
          if (_filterStartDate != null && d.isBefore(_filterStartDate!)) return false;
          if (_filterEndDate != null && d.isAfter(_filterEndDate!.add(const Duration(days: 1)))) return false;
          return true;
        }).toList();
        debugPrint('After date filter: ${bills.length} bills');
      }

      final changes = await CsvReconciliationService.instance.reconcile(bills);

      setState(() {
        _dataChanges = changes;
        _csvLoading = false;
      });

      // Switch to Data Changes tab
      _tabController.animateTo(4);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Found ${changes.length} differences in ${bills.length} bills'), backgroundColor: changes.isEmpty ? Colors.green : Colors.orange),
        );
      }
    } catch (e) {
      setState(() => _csvLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    }
  }

  // ─── DATA CHANGES TAB ────────────────────────────────────────

  Widget _buildDataChangesTab() {
    final hasStockChanges = _pendingNewProducts.isNotEmpty || _pendingPriceChanges.isNotEmpty;
    final hasCustomerChanges = _pendingNewCustomers.isNotEmpty || _pendingChangedCustomers.isNotEmpty;
    final totalChanges = _dataChanges.length + _pendingNewProducts.length + _pendingPriceChanges.length + _pendingNewCustomers.length + _pendingChangedCustomers.length + _accCodeMismatches.length;

    if (totalChanges == 0) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.check_circle_rounded, size: 56, color: Colors.green),
        const SizedBox(height: 12),
        Text('No differences found', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w800)),
        Text('Upload a CSV to compare data', style: GoogleFonts.manrope(color: AppTheme.onSurfaceVariant)),
      ]));
    }

    return Column(children: [
      // Bulk action bar
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: Colors.orange.shade50,
        child: Row(children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orange.shade700),
          const SizedBox(width: 8),
          Expanded(child: Text('$totalChanges changes to review', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 13, color: Colors.orange.shade800))),
          if (hasStockChanges || hasCustomerChanges)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: OutlinedButton.icon(
                onPressed: _clearAllSyncChanges,
                icon: const Icon(Icons.delete_sweep_rounded, size: 14),
                label: Text('Clear All', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 11)),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red, side: const BorderSide(color: Colors.red), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
              ),
            ),
          if (_dataChanges.isNotEmpty)
            FilledButton.icon(
              onPressed: _applyAllChanges,
              icon: const Icon(Icons.update_rounded, size: 16),
              label: Text('Apply Bills', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 12)),
              style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
            ),
        ]),
      ),
      // Changes list
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            // ── Stock Sync: New Products in Existing Categories ──
            if (_pendingNewProducts.isNotEmpty) ...[
              _buildSectionHeader('New Products from ITMRP', Icons.inventory_2_rounded, Colors.teal, _pendingNewProducts.length),
              const SizedBox(height: 6),
              ...List.generate(_pendingNewProducts.length, (i) => _buildNewProductCard(i)),
              const SizedBox(height: 16),
            ],

            // ── Stock Sync: Price Changes (RATE → unit_price) ──
            if (_pendingPriceChanges.isNotEmpty) ...[
              _buildSectionHeader('Price Changes from ITMRP', Icons.price_change_rounded, Colors.deepPurple, _pendingPriceChanges.length),
              const SizedBox(height: 6),
              ...List.generate(_pendingPriceChanges.length, (i) => _buildPriceChangeCard(i)),
              const SizedBox(height: 16),
            ],

            // ── Acc Code Mismatches (auto-fixed) ──
            if (_accCodeMismatches.isNotEmpty) ...[
              _buildSectionHeader('Acc Code Mismatches (Auto-Fixed)', Icons.warning_amber_rounded, Colors.red, _accCodeMismatches.length),
              const SizedBox(height: 6),
              ...List.generate(_accCodeMismatches.length, (i) {
                final m = _accCodeMismatches[i];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  color: Colors.red.shade50,
                  child: ListTile(
                    leading: const Icon(Icons.link_off, color: Colors.red),
                    title: Text('acc_code ${m['acc_code']} (${m['team']})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text('CSV: ${m['csv_name']}', style: const TextStyle(fontSize: 12, color: Colors.green)),
                        Text('DB was: ${m['db_name']}', style: const TextStyle(fontSize: 12, color: Colors.red)),
                        Text('Only ${m['similarity']}% similar — wrong acc_code cleared from "${m['db_name']}"', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                    isThreeLine: true,
                  ),
                );
              }),
              const SizedBox(height: 16),
            ],

            // ── Customer Sync: New Customers from ACMAST ──
            if (_pendingNewCustomers.isNotEmpty) ...[
              _buildSectionHeader('New Customers from ACMAST', Icons.person_add_rounded, Colors.indigo, _pendingNewCustomers.length),
              const SizedBox(height: 6),
              ...List.generate(_pendingNewCustomers.length, (i) => _buildNewCustomerCard(i)),
              const SizedBox(height: 16),
            ],

            // ── Customer Sync: Changed Customers ──
            if (_pendingChangedCustomers.isNotEmpty) ...[
              _buildSectionHeader('Customer Changes from ACMAST', Icons.edit_rounded, Colors.brown, _pendingChangedCustomers.length),
              const SizedBox(height: 6),
              ...List.generate(_pendingChangedCustomers.length, (i) => _buildChangedCustomerCard(i)),
              const SizedBox(height: 16),
            ],

            // ── Bill CSV Changes ──
            if (_dataChanges.isNotEmpty) ...[
              if (hasStockChanges || hasCustomerChanges) ...[
                _buildSectionHeader('Bill CSV Differences', Icons.receipt_long_rounded, Colors.orange, _dataChanges.length),
                const SizedBox(height: 6),
              ],
              ...List.generate(_dataChanges.length, (i) => _buildBillChangeCard(i)),
            ],
          ],
        ),
      ),
    ]);
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text('$title ($count)', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700, color: color))),
      ]),
    );
  }

  // ── New Product Card ────────────────────────────────────────
  Widget _buildNewProductCard(int index) {
    final item = _pendingNewProducts[index];
    final name = item['itemName'] as String? ?? '';
    final company = item['company'] as String? ?? '';
    final teamId = item['team_id'] as String? ?? '';
    final qty = item['qty'] as int? ?? 0;
    final mrp = item['mrp'] as double?;
    final rate = item['rate'] as double?;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.teal.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.teal.shade200),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.add_box_rounded, size: 18, color: Colors.teal.shade700),
          const SizedBox(width: 8),
          Expanded(child: Text(name, style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 13), overflow: TextOverflow.ellipsis)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: Colors.teal.shade700, borderRadius: BorderRadius.circular(6)),
            child: Text('NEW PRODUCT', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white)),
          ),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 12, runSpacing: 4, children: [
          Text('Category: $company', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
          if (teamId.isNotEmpty) Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: teamId == 'JA' ? Colors.blue.withValues(alpha: 0.12) : Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(teamId, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800,
              color: teamId == 'JA' ? Colors.blue : Colors.orange)),
          ),
          Text('Stock: $qty', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
          if (mrp != null) Text('MRP: \u20B9${mrp.toStringAsFixed(2)}', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
          if (rate != null) Text('Rate: \u20B9${rate.toStringAsFixed(2)}', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: () => _dismissNewProduct(index),
            icon: const Icon(Icons.close_rounded, size: 14),
            label: Text('Dismiss', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.grey, padding: const EdgeInsets.symmetric(vertical: 8)),
          )),
          const SizedBox(width: 8),
          Expanded(child: FilledButton.icon(
            onPressed: () => _approveNewProduct(index),
            icon: const Icon(Icons.add_rounded, size: 14),
            label: Text('Add Product', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(backgroundColor: Colors.teal, padding: const EdgeInsets.symmetric(vertical: 8)),
          )),
        ]),
      ]),
    );
  }

  // ── Price Change Card ───────────────────────────────────────
  Widget _buildPriceChangeCard(int index) {
    final item = _pendingPriceChanges[index];
    final name = item['productName'] as String? ?? '';
    final category = item['category'] as String? ?? '';
    final currentPrice = (item['currentPrice'] as num?)?.toDouble() ?? 0;
    final newPrice = (item['newPrice'] as num?)?.toDouble() ?? 0;
    final mrp = (item['mrp'] as num?)?.toDouble() ?? 0;
    final stockQty = item['stockQty'] as int? ?? 0;
    final priceDiff = newPrice - currentPrice;
    final isIncrease = priceDiff > 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.deepPurple.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.deepPurple.shade200),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.price_change_rounded, size: 18, color: Colors.deepPurple.shade700),
          const SizedBox(width: 8),
          Expanded(child: Text(name, style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 13), overflow: TextOverflow.ellipsis)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: Colors.deepPurple.shade700, borderRadius: BorderRadius.circular(6)),
            child: Text('PRICE', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white)),
          ),
        ]),
        const SizedBox(height: 6),
        Text(category, style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Wrap(spacing: 12, runSpacing: 4, children: [
          Text('Current: \u20B9${currentPrice.toStringAsFixed(2)}', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.red.shade700)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(isIncrease ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 12, color: isIncrease ? Colors.red : Colors.green),
            Text(' New: \u20B9${newPrice.toStringAsFixed(2)}', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.green.shade700)),
          ]),
          Text('Diff: ${isIncrease ? '+' : ''}\u20B9${priceDiff.toStringAsFixed(2)}', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 2),
        Text('MRP: \u20B9${mrp.toStringAsFixed(2)}  •  Stock: $stockQty', style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: () => _dismissPriceChange(index),
            icon: const Icon(Icons.close_rounded, size: 14),
            label: Text('Dismiss', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.grey, padding: const EdgeInsets.symmetric(vertical: 8)),
          )),
          const SizedBox(width: 8),
          Expanded(child: FilledButton.icon(
            onPressed: () => _approvePriceChange(index),
            icon: const Icon(Icons.check_rounded, size: 14),
            label: Text('Update Price', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(backgroundColor: Colors.deepPurple, padding: const EdgeInsets.symmetric(vertical: 8)),
          )),
        ]),
      ]),
    );
  }

  // ── Bill Change Card (existing logic) ───────────────────────
  Widget _buildBillChangeCard(int index) {
    final change = _dataChanges[index];
    final type = change['type'] as String;
    final billNo = change['bill_no'] as String? ?? '';
    final message = change['message'] as String? ?? '';

    Color cardColor;
    IconData icon;
    String badge;

    switch (type) {
      case 'new_bill':
        cardColor = Colors.blue.shade50;
        icon = Icons.add_circle_rounded;
        badge = 'NEW';
        break;
      case 'amount_mismatch':
        cardColor = Colors.red.shade50;
        icon = Icons.currency_rupee_rounded;
        badge = 'AMOUNT';
        break;
      case 'item_changes':
        cardColor = Colors.amber.shade50;
        icon = Icons.swap_horiz_rounded;
        badge = 'ITEMS';
        break;
      case 'can_auto_verify':
        cardColor = Colors.green.shade50;
        icon = Icons.verified_rounded;
        badge = 'VERIFY';
        break;
      default:
        cardColor = Colors.grey.shade50;
        icon = Icons.info_rounded;
        badge = 'INFO';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: cardColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 18, color: AppTheme.onSurface),
          const SizedBox(width: 8),
          Expanded(child: Text('Bill: $billNo', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 13), overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(6)),
            child: Text(badge, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white)),
          ),
        ]),
        const SizedBox(height: 6),
        Text(message, style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
        if (change['csv_customer'] != null)
          Text('Customer: ${change['csv_customer']}', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
        if (type == 'amount_mismatch') ...[
          const SizedBox(height: 4),
          Wrap(spacing: 12, runSpacing: 4, children: [
            Text('CSV: \u20B9${(change['csv_total'] as num).toStringAsFixed(2)}', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.green.shade700)),
            Text('App: \u20B9${(change['db_total'] as num).toStringAsFixed(2)}', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.red.shade700)),
            Text('Diff: \u20B9${(change['difference'] as num).toStringAsFixed(2)}', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w800)),
          ]),
        ],
        if (type == 'item_changes') ...[
          const SizedBox(height: 6),
          ...(change['item_changes'] as List).map((ic) => Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 4),
            child: Row(children: [
              Icon(
                ic['change'] == 'item_removed' ? Icons.remove_circle_rounded :
                ic['change'] == 'qty_reduced' ? Icons.arrow_downward_rounded :
                ic['change'] == 'new_item' ? Icons.add_circle_rounded :
                Icons.swap_horiz_rounded,
                size: 14, color: ic['change'] == 'item_removed' || ic['change'] == 'qty_reduced' ? Colors.red : Colors.green),
              const SizedBox(width: 6),
              Expanded(child: Text('${ic['item_name']}: ${ic['message']}', style: GoogleFonts.manrope(fontSize: 11))),
            ]),
          )),
        ],
      ]),
    );
  }

  // ── Apply / Dismiss Stock Sync Changes ──────────────────────

  Future<void> _approveNewProduct(int index) async {
    final item = _pendingNewProducts[index];
    try {
      await DriveSyncService.instance.applyNewProduct(item);
      // Removed from in-memory list via setState below
      setState(() => _pendingNewProducts.removeAt(index));
      await SupabaseService.instance.invalidateCache('products');
      await _loadDropdownData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added "${item['itemName']}" to products'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _dismissNewProduct(int index) async {
    // In-memory only
    setState(() => _pendingNewProducts.removeAt(index));
  }

  Future<void> _approvePriceChange(int index) async {
    final item = _pendingPriceChanges[index];
    try {
      await DriveSyncService.instance.applyPriceChange(
        item['productId'] as String,
        (item['newPrice'] as num).toDouble(),
      );
      // Removed from in-memory list via setState below
      setState(() => _pendingPriceChanges.removeAt(index));
      await SupabaseService.instance.invalidateCache('products');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Price updated for "${item['productName']}"'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _dismissPriceChange(int index) async {
    // In-memory only
    setState(() => _pendingPriceChanges.removeAt(index));
  }

  Future<void> _clearAllSyncChanges() async {
    final total = _pendingNewProducts.length + _pendingPriceChanges.length + _pendingNewCustomers.length + _pendingChangedCustomers.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Clear All Sync Changes?', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: Text('This will dismiss $total pending changes (stock + customer).',
          style: GoogleFonts.manrope(fontSize: 14, color: AppTheme.onSurfaceVariant)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Clear All', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    // In-memory only — clear lists via setState below
    setState(() {
      _pendingNewProducts.clear();
      _pendingPriceChanges.clear();
      _pendingNewCustomers.clear();
      _pendingChangedCustomers.clear();
      _accCodeMismatches.clear();
    });
  }

  // ── New Customer Card ───────────────────────────────────────
  Widget _buildNewCustomerCard(int index) {
    final item = _pendingNewCustomers[index];
    final name = item['name'] as String? ?? '';
    final address = item['address'] as String? ?? '';
    final phone = item['phone'] as String? ?? '';
    final group = item['group'] as String? ?? '';
    final amount = (item['amount'] as num?)?.toDouble() ?? 0;
    final accCode = item['acc_code'] as String? ?? '';
    final teamId = item['team_id'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.indigo.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.indigo.shade200),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.person_add_rounded, size: 18, color: Colors.indigo.shade700),
          const SizedBox(width: 8),
          Expanded(child: Text(name, style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 13), overflow: TextOverflow.ellipsis)),
          if (teamId.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: teamId == 'JA' ? Colors.blue.withValues(alpha: 0.12) : Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(teamId, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800,
                color: teamId == 'JA' ? Colors.blue : Colors.orange)),
            ),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: Colors.indigo.shade700, borderRadius: BorderRadius.circular(6)),
            child: Text('NEW CUSTOMER', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white)),
          ),
        ]),
        const SizedBox(height: 6),
        if (address.isNotEmpty)
          Text(address, style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
        Wrap(spacing: 12, runSpacing: 4, children: [
          if (accCode.isNotEmpty) Text('Code: $accCode', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
          if (phone.isNotEmpty) Text('Ph: $phone', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
          if (group.isNotEmpty) Text('Area: $group', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
          if (amount != 0) Text('Bal: \u20B9${amount.toStringAsFixed(0)}', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600, color: amount > 0 ? Colors.red : Colors.green)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: () => _dismissNewCustomer(index),
            icon: const Icon(Icons.close_rounded, size: 14),
            label: Text('Dismiss', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.grey, padding: const EdgeInsets.symmetric(vertical: 8)),
          )),
          const SizedBox(width: 8),
          Expanded(child: FilledButton.icon(
            onPressed: () => _approveNewCustomer(index),
            icon: const Icon(Icons.person_add_rounded, size: 14),
            label: Text('Add Customer', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(backgroundColor: Colors.indigo, padding: const EdgeInsets.symmetric(vertical: 8)),
          )),
        ]),
      ]),
    );
  }

  // ── Changed Customer Card ───────────────────────────────────
  Widget _buildChangedCustomerCard(int index) {
    final item = _pendingChangedCustomers[index];
    final customerName = item['customerName'] as String? ?? item['name'] as String? ?? '';
    final accCode = item['acc_code'] as String? ?? '';
    final teamId = item['team_id'] as String? ?? '';
    final changesRaw = item['changes'];
    final changes = changesRaw is Map
        ? Map<String, dynamic>.from(changesRaw)
        : <String, dynamic>{};

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.brown.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.brown.shade200),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.edit_rounded, size: 18, color: Colors.brown.shade700),
          const SizedBox(width: 8),
          Expanded(child: Text(customerName, style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 13), overflow: TextOverflow.ellipsis)),
          if (teamId.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: teamId == 'JA' ? Colors.blue.withValues(alpha: 0.12) : Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(teamId, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800,
                color: teamId == 'JA' ? Colors.blue : Colors.orange)),
            ),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: Colors.brown.shade700, borderRadius: BorderRadius.circular(6)),
            child: Text('CHANGED', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white)),
          ),
        ]),
        if (accCode.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('Code: $accCode', style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant)),
          ),
        const SizedBox(height: 6),
        ...changes.entries.map((e) {
          final field = e.key;
          final change = e.value is Map ? Map<String, dynamic>.from(e.value as Map) : <String, dynamic>{};
          final oldVal = change['old']?.toString() ?? '';
          final newVal = change['new']?.toString() ?? '';
          final fieldLabel = field == 'acc_code' ? 'Account Code' : field[0].toUpperCase() + field.substring(1);
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 70, child: Text('$fieldLabel:', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600))),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (oldVal.isNotEmpty) Text(oldVal, style: GoogleFonts.manrope(fontSize: 11, color: Colors.red.shade700, decoration: TextDecoration.lineThrough)),
                Text(newVal, style: GoogleFonts.manrope(fontSize: 11, color: Colors.green.shade700, fontWeight: FontWeight.w600)),
              ])),
            ]),
          );
        }),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: () => _dismissChangedCustomer(index),
            icon: const Icon(Icons.close_rounded, size: 14),
            label: Text('Dismiss', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.grey, padding: const EdgeInsets.symmetric(vertical: 8)),
          )),
          const SizedBox(width: 8),
          Expanded(child: FilledButton.icon(
            onPressed: () => _approveChangedCustomer(index),
            icon: const Icon(Icons.check_rounded, size: 14),
            label: Text('Apply Changes', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(backgroundColor: Colors.brown, padding: const EdgeInsets.symmetric(vertical: 8)),
          )),
        ]),
      ]),
    );
  }

  // ── Customer Apply / Dismiss ────────────────────────────────

  Future<void> _approveNewCustomer(int index) async {
    final item = _pendingNewCustomers[index];
    try {
      await DriveSyncService.instance.applyNewCustomer(item);
      // Removed from in-memory list via setState below
      setState(() => _pendingNewCustomers.removeAt(index));
      await SupabaseService.instance.invalidateCache('customers');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added "${item['name']}"'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _dismissNewCustomer(int index) async {
    // In-memory only
    setState(() => _pendingNewCustomers.removeAt(index));
  }

  Future<void> _approveChangedCustomer(int index) async {
    final item = _pendingChangedCustomers[index];
    try {
      final changesRaw = item['changes'];
      final changes = changesRaw is Map ? Map<String, dynamic>.from(changesRaw) : <String, dynamic>{};
      await DriveSyncService.instance.applyCustomerChange(item['customerId'] as String, changes);
      // Removed from in-memory list via setState below
      setState(() => _pendingChangedCustomers.removeAt(index));
      await SupabaseService.instance.invalidateCache('customers');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Updated "${item['customerName'] ?? item['name']}"'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _dismissChangedCustomer(int index) async {
    // In-memory only
    setState(() => _pendingChangedCustomers.removeAt(index));
  }

  Future<void> _applyAllChanges() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Apply All Changes?', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: Text('This will update ${_dataChanges.length} records in the database. This cannot be undone.',
          style: GoogleFonts.manrope(fontSize: 14, color: AppTheme.onSurfaceVariant)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Apply All', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final applied = await CsvReconciliationService.instance.applyChanges(_dataChanges);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Applied $applied changes'), backgroundColor: Colors.green),
        );
        setState(() => _dataChanges.clear());
        await DriveSyncService.instance.clearDriveDiscrepancies();
        _loadOrders();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    }
  }
}
