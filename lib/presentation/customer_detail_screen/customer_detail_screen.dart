import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import '../../services/gemini_ocr_service.dart';

import '../../routes/app_routes.dart';
import '../../theme/app_theme.dart';
import '../../services/supabase_service.dart';
import '../../services/cart_service.dart';
import '../../services/google_drive_service.dart';
import '../../services/auth_service.dart';

class CustomerDetailScreen extends StatefulWidget {
  const CustomerDetailScreen({super.key});

  @override
  State<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends State<CustomerDetailScreen> {
  CustomerModel? _customer;
  BeatModel? _beat;

  bool _ordersLoading = true;
  String? _ordersError;
  List<OrderModel> _orders = [];

  bool _collectionsLoading = true;
  List<dynamic> _collections = [];

  // OPNBIL outstanding bills + RECT receipts + ITTR billed items from billing software
  bool _billsLoading = true;
  List<Map<String, dynamic>> _outstandingBills = [];
  bool _receiptsLoading = true;
  List<Map<String, dynamic>> _receipts = [];
  bool _billedItemsLoading = true;
  List<Map<String, dynamic>> _billedItems = [];
  // RCTBIL: receipt_no → list of invoice numbers paid by that receipt
  Map<String, List<String>> _receiptBillMap = {};

  // Dual-team support — only when navigated from merged multi-team beat view
  // AND customer actually belongs to both teams
  bool _isMergedView = false;
  bool get _isDualTeam => _isMergedView &&
      _customer != null &&
      _customer!.belongsToTeam('JA') && _customer!.belongsToTeam('MA');
  List<dynamic> _collectionsJA = [];
  List<dynamic> _collectionsMA = [];
  String _collectionsTeamFilter = 'JA'; // for collections tab toggle

  // Role-based tab control
  bool get _isBrandRep => SupabaseService.instance.currentUserRole == 'brand_rep';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_customer != null) return;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      if (args['customer'] is CustomerModel) {
        _customer = args['customer'] as CustomerModel;
        _loadOrders();
        _loadCollections();
        _loadBillingData();
      }
      if (args['beat'] is BeatModel) {
        _beat = args['beat'] as BeatModel;
      }
      _isMergedView = args['isMergedView'] as bool? ?? false;
    } else if (args is CustomerModel) {
      _customer = args;
      _loadOrders();
      _loadCollections();
      _loadBillingData();
    }
  }

  Future<void> _loadOrders() async {
    if (_customer == null) return;
    setState(() { _ordersLoading = true; _ordersError = null; });
    try {
      final orders = await SupabaseService.instance.getCustomerOrders(_customer!.id);
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _ordersLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _ordersError = e.toString(); _ordersLoading = false; });
    }
  }

  Future<void> _loadCollections() async {
    if (_customer == null) return;
    setState(() => _collectionsLoading = true);
    try {
      if (_isDualTeam) {
        final results = await Future.wait([
          SupabaseService.instance.getCollectionHistory(_customer!.id, teamId: 'JA'),
          SupabaseService.instance.getCollectionHistory(_customer!.id, teamId: 'MA'),
        ]);
        if (!mounted) return;
        setState(() {
          _collectionsJA = results[0];
          _collectionsMA = results[1];
          _collections = _collectionsTeamFilter == 'JA' ? _collectionsJA : _collectionsMA;
          _collectionsLoading = false;
        });
      } else {
        final data = await SupabaseService.instance.getCollectionHistory(_customer!.id);
        if (!mounted) return;
        setState(() { _collections = data; _collectionsLoading = false; });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _collectionsLoading = false);
    }
  }

  Future<void> _loadBillingData() async {
    if (_customer == null) return;
    final isRep = SupabaseService.instance.currentUserRole == 'sales_rep' ||
        SupabaseService.instance.currentUserRole == 'brand_rep';
    try {
      if (_isDualTeam) {
        // Load both teams' data for dual-team customers
        final savedTeam = AuthService.currentTeam;
        AuthService.currentTeam = 'JA';
        final jaResults = await Future.wait([
          SupabaseService.instance.getCustomerBills(_customer!.id, repOnly: isRep),
          SupabaseService.instance.getCustomerReceipts(_customer!.id, repOnly: isRep),
          SupabaseService.instance.getCustomerBilledItems(_customer!.id, repOnly: isRep),
        ]);
        AuthService.currentTeam = 'MA';
        final maResults = await Future.wait([
          SupabaseService.instance.getCustomerBills(_customer!.id, repOnly: isRep),
          SupabaseService.instance.getCustomerReceipts(_customer!.id, repOnly: isRep),
          SupabaseService.instance.getCustomerBilledItems(_customer!.id, repOnly: isRep),
        ]);
        AuthService.currentTeam = savedTeam;
        if (!mounted) return;
        setState(() {
          _outstandingBills = [...jaResults[0] as List<Map<String, dynamic>>, ...maResults[0] as List<Map<String, dynamic>>];
          _billsLoading = false;
          _receipts = [...jaResults[1] as List<Map<String, dynamic>>, ...maResults[1] as List<Map<String, dynamic>>];
          _receiptsLoading = false;
          _billedItems = [...jaResults[2] as List<Map<String, dynamic>>, ...maResults[2] as List<Map<String, dynamic>>];
          _billedItemsLoading = false;
        });
      } else {
        final results = await Future.wait([
          SupabaseService.instance.getCustomerBills(_customer!.id, repOnly: isRep),
          SupabaseService.instance.getCustomerReceipts(_customer!.id, repOnly: isRep),
          SupabaseService.instance.getCustomerBilledItems(_customer!.id, repOnly: isRep),
        ]);
        if (!mounted) return;
        setState(() {
          _outstandingBills = results[0] as List<Map<String, dynamic>>;
          _billsLoading = false;
          _receipts = results[1] as List<Map<String, dynamic>>;
          _receiptsLoading = false;
          _billedItems = results[2] as List<Map<String, dynamic>>;
          _billedItemsLoading = false;
        });
      }
      // Load receipt → bill mappings from RCTBIL
      _loadReceiptBillMap();
    } catch (e) {
      if (!mounted) return;
      setState(() { _billsLoading = false; _receiptsLoading = false; _billedItemsLoading = false; });
    }
  }

  Future<void> _loadReceiptBillMap() async {
    if (_receipts.isEmpty) return;
    final receiptNos = _receipts
        .map((r) => r['receipt_no'] as String? ?? '')
        .where((r) => r.isNotEmpty)
        .toSet()
        .toList();
    if (receiptNos.isEmpty) return;

    try {
      final data = await SupabaseService.instance.client
          .from('customer_receipt_bills')
          .select('receipt_no, invoice_no')
          .inFilter('receipt_no', receiptNos)
          .eq('team_id', AuthService.currentTeam);
      final map = <String, List<String>>{};
      for (final row in data) {
        final rcpt = row['receipt_no'] as String? ?? '';
        final inv = row['invoice_no'] as String? ?? '';
        if (rcpt.isNotEmpty && inv.isNotEmpty) {
          map.putIfAbsent(rcpt, () => []);
          if (!map[rcpt]!.contains(inv)) map[rcpt]!.add(inv);
        }
      }
      if (mounted) setState(() => _receiptBillMap = map);
    } catch (e) {
      debugPrint('⚠️ _loadReceiptBillMap error: $e');
    }
  }

  void _goToNewOrder() {
    CartService.instance.setCustomerSession(_customer!, _beat);
    Navigator.pushNamed(context, AppRoutes.productsScreen);
  }

  // ─── Payment methods ───

  void _showPaymentBottomSheet({double? presetAmount, List<OrderModel>? presetOrders, String? presetBillNo}) {
    final amountController = TextEditingController(text: presetAmount?.toStringAsFixed(2) ?? '');
    final billNoController = TextEditingController(
      text: presetBillNo ?? (presetOrders?.map((o) =>
        o.finalBillNo != null && o.finalBillNo!.isNotEmpty
            ? o.finalBillNo!
            : o.id.split('-').last.toUpperCase()
      ).join(', ') ?? ''),
    );
    String selectedMethod = 'UPI';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              left: 20, right: 20, top: 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Settle Payment', style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                if (_customer != null && _customer!.outstandingForTeam(AuthService.currentTeam) > 0)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.account_balance_wallet_rounded, size: 16, color: Colors.orange.shade700),
                        const SizedBox(width: 8),
                        Text(
                          'Outstanding: ₹${_customer!.outstandingForTeam(AuthService.currentTeam).toStringAsFixed(0)}',
                          style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.orange.shade800),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: RadioListTile<String>(
                        title: Text('UPI', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.bold)),
                        value: 'UPI',
                        groupValue: selectedMethod,
                        onChanged: (val) => setModalState(() => selectedMethod = val!),
                        contentPadding: EdgeInsets.zero,
                        activeColor: AppTheme.primary,
                      ),
                    ),
                    Expanded(
                      child: RadioListTile<String>(
                        title: Text('Cash', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.bold)),
                        value: 'CASH',
                        groupValue: selectedMethod,
                        onChanged: (val) => setModalState(() => selectedMethod = val!),
                        contentPadding: EdgeInsets.zero,
                        activeColor: Colors.orange,
                      ),
                    ),
                    Expanded(
                      child: RadioListTile<String>(
                        title: Text('Cheque', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.bold)),
                        value: 'Cheque',
                        groupValue: selectedMethod,
                        onChanged: (val) => setModalState(() => selectedMethod = val!),
                        contentPadding: EdgeInsets.zero,
                        activeColor: Colors.purple,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Total Amount (\u20B9)',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    prefixIcon: const Icon(Icons.currency_rupee),
                  ),
                ),
                const SizedBox(height: 12),
                // Bill number dropdown from verified orders + manual entry
                Autocomplete<String>(
                  optionsBuilder: (textEditingValue) {
                    final verifiedBills = _orders
                        .where((o) => o.status == 'Verified' || o.status == 'Invoiced' || o.status == 'Delivered')
                        .where((o) => o.finalBillNo != null && o.finalBillNo!.isNotEmpty)
                        .map((o) => o.finalBillNo!)
                        .toSet()
                        .toList();
                    if (textEditingValue.text.isEmpty) return verifiedBills;
                    return verifiedBills.where((b) => b.toLowerCase().contains(textEditingValue.text.toLowerCase()));
                  },
                  initialValue: billNoController.value,
                  onSelected: (val) => billNoController.text = val,
                  fieldViewBuilder: (ctx, ctrl, focusNode, onSubmit) {
                    // Sync with our controller
                    ctrl.text = billNoController.text;
                    ctrl.addListener(() => billNoController.text = ctrl.text);
                    return TextField(
                      controller: ctrl,
                      focusNode: focusNode,
                      decoration: InputDecoration(
                        labelText: 'Bill Number(s)',
                        hintText: 'Select verified bill or type manually',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        prefixIcon: const Icon(Icons.receipt_outlined),
                        suffixIcon: const Icon(Icons.arrow_drop_down),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    onPressed: () async {
                      final amount = amountController.text.trim();
                      final billNo = billNoController.text.trim();
                      if (amount.isEmpty || billNo.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter amount and bill number')));
                        return;
                      }
                      Navigator.pop(ctx);
                      final activeOrders = (presetOrders?.isNotEmpty == true) ? presetOrders : null;
                      if (selectedMethod == 'UPI') {
                        _showQrDialog(amount, billNo,
                          onCaptured: activeOrders != null
                              ? (driveFileId) => _processMultiPayment(orders: activeOrders, amount: double.parse(amount), method: 'UPI', driveFileId: driveFileId)
                              : null,
                        );
                      } else {
                        // Cash or Cheque — direct record, no QR
                        if (activeOrders != null) {
                          await _processMultiPayment(orders: activeOrders, amount: double.parse(amount), method: selectedMethod);
                        } else {
                          await _processPayment(billNo: billNo, amount: double.parse(amount), method: selectedMethod);
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: selectedMethod == 'UPI' ? AppTheme.primary : selectedMethod == 'Cheque' ? Colors.purple : Colors.orange,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text(selectedMethod == 'UPI' ? 'Generate QR & Capture Proof' : 'Record ${selectedMethod} Payment'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showQrDialog(String amount, String billNo, {Future<void> Function(String driveFileId)? onCaptured}) {
    final teamUpi = AuthService.teamUpi.isNotEmpty ? AuthService.teamUpi : 'default@upi';
    final teamName = AuthService.currentTeam == 'JA' ? 'JAGANNATH' : 'MADHAV';
    final upiString = 'upi://pay?pa=$teamUpi&pn=MAJAA_$teamName&am=$amount&tn=${Uri.encodeComponent("Bill $billNo")}&cu=INR';

    showDialog(
      context: context,
      barrierDismissible: false, // cannot dismiss by tapping outside
      builder: (ctx) => PopScope(
        canPop: false, // back button also blocked
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('Scan to Pay ₹$amount\n($teamName)', textAlign: TextAlign.center, style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade200), borderRadius: BorderRadius.circular(12)),
                child: QrImageView(data: upiString, version: QrVersions.auto, size: 200.0),
              ),
              const SizedBox(height: 16),
              Text('Bills: $billNo', style: GoogleFonts.manrope(fontWeight: FontWeight.w600, fontSize: 12), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
                child: const Text(
                  '⚠️ You MUST capture the customer\'s payment success screen.\n'
                  'Screenshot will be sent to WhatsApp automatically.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Colors.red, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          actions: [
            Row(
              children: [
                Expanded(
                  flex: 1,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await _captureProofAndProcess(billNo, double.parse(amount), onCaptured: onCaptured);
                    },
                    icon: const Icon(Icons.camera_alt_rounded),
                    label: const Text('Capture Proof'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _captureProofAndProcess(String billNo, double amount, {Future<void> Function(String driveFileId)? onCaptured}) async {
    // ── Step 1: Capture — mandatory, keep looping until user takes a photo ──
    XFile? photo;
    while (photo == null) {
      final picker = ImagePicker();
      photo = await picker.pickImage(source: ImageSource.camera, imageQuality: 80);
      if (photo == null && mounted) {
        // Photo is required — show warning and loop back
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('Screenshot Required', style: TextStyle(fontWeight: FontWeight.w800)),
            content: const Text(
              'You must capture the customer\'s UPI payment success screen before recording this payment.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Take Photo'),
              ),
            ],
          ),
        );
      }
    }

    try {
      // ── Step 2: Share proof to group via share sheet ──
      final customerName = _customer?.name ?? 'Customer';
      final date = DateFormat('dd-MM-yyyy').format(DateTime.now());

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(photo.path)],
          text: 'UPI Payment Proof\n$customerName\nBill: $billNo\nAmount: ₹$amount\nDate: $date',
        ),
      );

      // ── Step 3: Record payment ──
      if (onCaptured != null) {
        await onCaptured('shared');
      } else {
        await _processPayment(billNo: billNo, amount: amount, method: 'UPI');
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _processMultiPayment({required List<OrderModel> orders, required double amount, required String method, String? driveFileId}) async {
    try {
      final orderIds = orders.map((o) => o.id).toList();
      await SupabaseService.instance.settleMultipleOrders(
        orderIds: orderIds,
        customerId: _customer!.id,
        customerName: _customer!.name,
        paymentMethod: method,
        totalAmount: amount,
        driveFileId: driveFileId,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$method Payment of ₹$amount recorded for ${orders.length} orders!'), backgroundColor: Colors.green),
        );
        _loadCollections();
        _loadOrders();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Database Error: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _processPayment({required String billNo, required double amount, required String method, String? driveFileId}) async {
    try {
      await SupabaseService.instance.recordCollection(
        billNo: billNo,
        customerId: _customer!.id,
        customerName: _customer!.name,
        amountPaid: amount,
        remainingBalance: 0,
        paymentMethod: method,
        driveFileId: driveFileId,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$method Payment of ₹$amount Recorded!'), backgroundColor: Colors.green));
        _loadCollections();
        _loadOrders();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Database Error: $e'), backgroundColor: Colors.red));
    }
  }

  void _viewPaymentPhoto(BuildContext context, String fileId) {
    final imageUrl = 'https://drive.google.com/uc?export=view&id=$fileId';
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(10),
        child: Stack(
          alignment: Alignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: InteractiveViewer(
                child: CachedNetworkImage(
                  imageUrl: imageUrl,
                  placeholder: (context, url) => const CircularProgressIndicator(color: Colors.white),
                  errorWidget: (context, url, error) => Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(20),
                    child: const Text('Error loading proof from Google Drive.'),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 10, right: 10,
              child: IconButton(icon: const Icon(Icons.close, color: Colors.white, size: 30), onPressed: () => Navigator.pop(ctx)),
            ),
            Positioned(
              bottom: 10,
              child: TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://drive.google.com/file/d/$fileId/view'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new, color: Colors.white, size: 14),
                label: const Text('View in Drive', style: TextStyle(color: Colors.white)),
                style: TextButton.styleFrom(
                  backgroundColor: Colors.black54,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    if (_customer == null) return const Scaffold(body: Center(child: Text('Customer not found.')));
    final c = _customer!;
    final phonePresent = c.phone.isNotEmpty && c.phone != 'No Phone';

    return DefaultTabController(
      length: _isBrandRep ? 2 : 5,
      child: Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          title: Text(c.name, style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 16)),
          backgroundColor: AppTheme.surface,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _goToNewOrder,
          backgroundColor: AppTheme.primary,
          foregroundColor: Colors.white,
          icon: const Icon(Icons.add_shopping_cart_rounded),
          label: Text('Take Order', style: GoogleFonts.manrope(fontWeight: FontWeight.w600, fontSize: 13)),
        ),
        body: Column(
          children: [
            _buildHeroHeader(c, phonePresent),
            Container(
              color: AppTheme.surface,
              child: TabBar(
                indicatorColor: AppTheme.primary,
                labelColor: AppTheme.primary,
                unselectedLabelColor: AppTheme.onSurfaceVariant,
                labelStyle: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700),
                tabs: [
                  if (!_isBrandRep) const Tab(text: 'Orders'),
                  if (!_isBrandRep) const Tab(text: 'Billed'),
                  const Tab(text: 'Outstanding'),
                  if (!_isBrandRep) const Tab(text: 'Collections'),
                  const Tab(text: 'Info'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  if (!_isBrandRep) _buildOrdersTab(),
                  if (!_isBrandRep) _buildBilledTab(),
                  _buildOutstandingTab(),
                  if (!_isBrandRep) _buildCollectionsTab(),
                  _buildInfoTab(c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroHeader(CustomerModel c, bool phonePresent) {
    final balance = c.outstandingForTeam(AuthService.currentTeam);
    final initial = c.name.isNotEmpty ? c.name[0].toUpperCase() : 'U';

    return Container(
      color: AppTheme.surface,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: AppTheme.primary,
                child: Text(initial, style: GoogleFonts.manrope(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.name, style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.onSurface), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      phonePresent ? c.phone : 'No Phone',
                      style: GoogleFonts.manrope(fontSize: 13, color: phonePresent ? AppTheme.onSurfaceVariant : Colors.red),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _buildTypeBadge(c.type),
                  const SizedBox(height: 6),
                  if (_isDualTeam) ...[
                    _buildTeamBalanceChip('JA', c.outstandingForTeam('JA')),
                    const SizedBox(height: 4),
                    _buildTeamBalanceChip('MA', c.outstandingForTeam('MA')),
                  ] else
                    _buildBalanceChip(balance),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              if (phonePresent) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final uri = Uri(scheme: 'tel', path: c.phone);
                      if (await canLaunchUrl(uri)) launchUrl(uri);
                    },
                    icon: const Icon(Icons.call_rounded, size: 15),
                    label: Text('Call', style: GoogleFonts.manrope(fontWeight: FontWeight.w600, fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.green.shade700,
                      side: BorderSide(color: Colors.green.shade300),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final digits = c.phone.replaceAll(RegExp(r'\D'), '');
                      final number = digits.length >= 10 ? digits.substring(digits.length - 10) : digits;
                      final uri = Uri.parse('whatsapp://send?phone=91$number');
                      if (await canLaunchUrl(uri)) launchUrl(uri);
                    },
                    icon: const Icon(Icons.chat_rounded, size: 15),
                    label: Text('WhatsApp', style: GoogleFonts.manrope(fontWeight: FontWeight.w600, fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.green.shade800,
                      side: BorderSide(color: Colors.green.shade300),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (!_isBrandRep) ...[
                if (_isDualTeam) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        AuthService.currentTeam = 'JA';
                        _showPaymentBottomSheet();
                      },
                      icon: const Icon(Icons.payments_outlined, size: 15),
                      label: Text('Settle JA', style: GoogleFonts.manrope(fontWeight: FontWeight.w600, fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.blue,
                        side: BorderSide(color: Colors.blue.withValues(alpha: 0.5)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        AuthService.currentTeam = 'MA';
                        _showPaymentBottomSheet();
                      },
                      icon: const Icon(Icons.payments_outlined, size: 15),
                      label: Text('Settle MA', style: GoogleFonts.manrope(fontWeight: FontWeight.w600, fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orange,
                        side: BorderSide(color: Colors.orange.withValues(alpha: 0.5)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                ] else
                  Expanded(
                    flex: phonePresent ? 1 : 3,
                    child: OutlinedButton.icon(
                      onPressed: () => _showPaymentBottomSheet(),
                      icon: const Icon(Icons.payments_outlined, size: 15),
                      label: Text('Settle Due', style: GoogleFonts.manrope(fontWeight: FontWeight.w600, fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primary,
                        side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.5)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTypeBadge(String type) {
    final color = type.toLowerCase() == 'wholesale' ? Colors.blue : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
      child: Text(type.toUpperCase(), style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w800, color: color)),
    );
  }

  Widget _buildBalanceChip(double balance) {
    if (balance == 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
        child: Text('Cleared', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.green.shade700)),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
      child: Text('₹${balance.toStringAsFixed(0)} due', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.red.shade700)),
    );
  }

  Widget _buildTeamBalanceChip(String team, double balance) {
    final color = team == 'JA' ? Colors.blue : Colors.orange;
    final label = balance == 0
        ? '$team ✓'
        : '$team ₹${balance.toStringAsFixed(0)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: balance == 0
            ? Colors.green.withValues(alpha: 0.1)
            : color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: GoogleFonts.manrope(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: balance == 0 ? Colors.green.shade700 : color,
        ),
      ),
    );
  }

  // ─── BILLED TAB (ITTR data) ──────────────────────────────────

  Widget _buildBilledTab() {
    if (_billedItemsLoading) return const Center(child: CircularProgressIndicator());
    if (_billedItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_outlined, size: 64, color: AppTheme.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text('No billed items', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('ITTR data will appear after sync', style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    // Group by invoice_no
    final Map<String, List<Map<String, dynamic>>> byInvoice = {};
    for (final item in _billedItems) {
      final inv = item['invoice_no'] as String? ?? '';
      byInvoice.putIfAbsent(inv, () => []);
      byInvoice[inv]!.add(item);
    }
    final invoices = byInvoice.entries.toList();

    // Build invoice_no → bill_amount lookup from customer_bills (INV data)
    // This gives us the net/final amount per invoice instead of gross from ITTR
    final Map<String, double> invBillAmount = {};
    for (final bill in _outstandingBills) {
      final inv = bill['invoice_no'] as String? ?? '';
      final book = bill['book'] as String? ?? '';
      final key = book.isNotEmpty ? '$book$inv' : inv;
      invBillAmount[key] = (bill['bill_amount'] as num?)?.toDouble() ?? 0;
      invBillAmount[inv] = (bill['bill_amount'] as num?)?.toDouble() ?? 0;
    }

    // Total billed: prefer INV bill_amount per invoice, fall back to ITTR sum
    double totalBilled = 0;
    for (final inv in invoices) {
      final invoiceNo = inv.key;
      final invTotal = invBillAmount[invoiceNo];
      if (invTotal != null) {
        totalBilled += invTotal;
      } else {
        totalBilled += inv.value.fold(0.0, (sum, i) => sum + ((i['amount'] as num?)?.toDouble() ?? 0));
      }
    }
    final totalItems = _billedItems.fold(0, (sum, i) => sum + ((i['quantity'] as int?) ?? 0));

    return Column(
      children: [
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Total Billed', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
              Text('\u20B9${totalBilled.toStringAsFixed(0)}',
                  style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.primary)),
            ]),
            const Spacer(),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${invoices.length} invoices', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
              Text('$totalItems items', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
            ]),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            itemCount: invoices.length,
            itemBuilder: (context, index) {
              final inv = invoices[index];
              final invoiceNo = inv.key;
              final items = inv.value;
              final billDate = items.first['bill_date'] as String? ?? '';
              // Prefer INV bill_amount (net), fall back to ITTR item sum (gross)
              final double invoiceTotal = invBillAmount[invoiceNo]
                  ?? items.fold<double>(0.0, (sum, i) => sum + ((i['amount'] as num?)?.toDouble() ?? 0));
              final dateStr = billDate.isNotEmpty
                  ? DateFormat('dd MMM yyyy').format(DateTime.parse(billDate))
                  : '';

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.outlineVariant),
                ),
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                  childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  shape: const Border(),
                  title: Row(children: [
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Invoice #$invoiceNo', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700)),
                        Text('$dateStr \u2022 ${items.length} items', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                      ],
                    )),
                    Text('\u20B9${invoiceTotal.toStringAsFixed(0)}',
                        style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800, color: AppTheme.primary)),
                  ]),
                  children: items.map((item) {
                    final itemName = item['item_name'] as String? ?? '';
                    final qty = item['quantity'] as int? ?? 0;
                    final mrp = (item['mrp'] as num?)?.toDouble() ?? 0;
                    final rate = (item['rate'] as num?)?.toDouble() ?? 0;
                    final amt = (item['amount'] as num?)?.toDouble() ?? 0;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(itemName, style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                            Text('MRP: \u20B9${mrp.toStringAsFixed(0)} \u2022 Rate: \u20B9${rate.toStringAsFixed(0)}',
                                style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant)),
                          ],
                        )),
                        const SizedBox(width: 8),
                        Text('x$qty', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700)),
                        const SizedBox(width: 12),
                        SizedBox(width: 60, child: Text('\u20B9${amt.toStringAsFixed(0)}',
                            textAlign: TextAlign.right,
                            style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary))),
                      ]),
                    );
                  }).toList(),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildOutstandingTab() {
    if (_billsLoading) return const Center(child: CircularProgressIndicator());

    // Use OPNBIL data, filter to non-cleared bills with pending amount > 0
    final pendingBills = _outstandingBills.where((b) {
      final pending = (b['pending_amount'] as num?)?.toDouble() ?? 0;
      final cleared = b['cleared'] as bool? ?? false;
      return !cleared && pending > 0;
    }).toList();

    if (pendingBills.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline_rounded, size: 64, color: Colors.green.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text('No pending bills', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.onSurface)),
            const SizedBox(height: 4),
            Text('All dues cleared', style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    final totalDue = pendingBills.fold(0.0, (sum, b) => sum + ((b['pending_amount'] as num?)?.toDouble() ?? 0));
    final totalBillAmt = pendingBills.fold(0.0, (sum, b) => sum + ((b['bill_amount'] as num?)?.toDouble() ?? 0));
    final totalReceived = pendingBills.fold(0.0, (sum, b) => sum + ((b['received_amount'] as num?)?.toDouble() ?? 0));

    return Column(
      children: [
        // Summary header
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Row(children: [
              Text('Total Outstanding:', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('\u20B9${totalDue.toStringAsFixed(0)}',
                  style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.red.shade700)),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              Text('Billed: \u20B9${totalBillAmt.toStringAsFixed(0)}', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
              const Spacer(),
              Text('Received: \u20B9${totalReceived.toStringAsFixed(0)}', style: GoogleFonts.manrope(fontSize: 11, color: Colors.green.shade700)),
            ]),
          ]),
        ),
        const Divider(height: 1),
        // Bill list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            itemCount: pendingBills.length,
            itemBuilder: (context, index) {
              final b = pendingBills[index];
              final invoiceNo = b['invoice_no'] as String? ?? '';
              final book = b['book'] as String? ?? '';
              final billDate = b['bill_date'] as String? ?? '';
              final billAmt = (b['bill_amount'] as num?)?.toDouble() ?? 0;
              final pending = (b['pending_amount'] as num?)?.toDouble() ?? 0;
              final received = (b['received_amount'] as num?)?.toDouble() ?? 0;
              final creditDays = b['credit_days'] as int? ?? 0;
              final dateStr = billDate.isNotEmpty ? DateFormat('dd MMM yyyy').format(DateTime.parse(billDate)) : '';

              // Check if overdue
              bool isOverdue = false;
              if (creditDays > 0 && billDate.isNotEmpty) {
                final dueDate = DateTime.parse(billDate).add(Duration(days: creditDays));
                isOverdue = DateTime.now().isAfter(dueDate);
              }

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isOverdue ? Colors.red.shade50 : AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isOverdue ? Colors.red.shade200 : AppTheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text('$book-$invoiceNo', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700)),
                            if (isOverdue) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(4)),
                                child: Text('OVERDUE', style: GoogleFonts.manrope(fontSize: 8, fontWeight: FontWeight.w800, color: Colors.white)),
                              ),
                            ],
                          ]),
                          const SizedBox(height: 2),
                          Text(dateStr, style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                          if (received > 0)
                            Text('Paid: \u20B9${received.toStringAsFixed(0)} / \u20B9${billAmt.toStringAsFixed(0)}',
                                style: GoogleFonts.manrope(fontSize: 10, color: Colors.green.shade700)),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('\u20B9${pending.toStringAsFixed(0)}',
                            style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.red.shade700)),
                        if (!_isBrandRep) ...[
                          const SizedBox(height: 4),
                          GestureDetector(
                            onTap: () => _showPaymentBottomSheet(presetAmount: pending, presetBillNo: '$book-$invoiceNo'),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(8)),
                              child: Text('Settle', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildOrdersTab() {
    if (_ordersLoading) return const Center(child: CircularProgressIndicator());
    if (_ordersError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded, size: 48, color: AppTheme.error),
            const SizedBox(height: 12),
            Text('Error: $_ordersError', textAlign: TextAlign.center, style: GoogleFonts.manrope(color: AppTheme.error)),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _loadOrders, child: const Text('Retry')),
          ],
        ),
      );
    }
    // Reps only see their own app orders, not office-billed
    final isRep = !SupabaseService.instance.isAdmin;
    final visibleOrders = isRep
        ? _orders.where((o) => o.source != 'office').toList()
        : _orders;
    if (visibleOrders.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long_outlined, size: 64, color: AppTheme.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text('No orders yet', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.onSurface)),
          ],
        ),
      );
    }
    return _OrdersTabView(
      orders: visibleOrders,
      onMultiSettle: (amt, orders) => _showPaymentBottomSheet(presetAmount: amt, presetOrders: orders),
    );
  }

  Widget _buildCollectionsTab() {
    if (_collectionsLoading) return const Center(child: CircularProgressIndicator());

    return Column(
      children: [
        // JA/MA toggle for dual-team customers
        if (_isDualTeam)
          Container(
            color: AppTheme.surface,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Row(
              children: [
                _buildCollectionsTeamChip('JA', Colors.blue),
                const SizedBox(width: 10),
                _buildCollectionsTeamChip('MA', Colors.orange),
              ],
            ),
          ),
        Expanded(child: _buildCollectionsList()),
      ],
    );
  }

  Widget _buildCollectionsTeamChip(String team, Color color) {
    final selected = _collectionsTeamFilter == team;
    final count = team == 'JA' ? _collectionsJA.length : _collectionsMA.length;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _collectionsTeamFilter = team;
            _collections = team == 'JA' ? _collectionsJA : _collectionsMA;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? color : color.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? color : color.withValues(alpha: 0.2),
              width: selected ? 2 : 1,
            ),
          ),
          child: Center(
            child: Text(
              '$team ($count)',
              style: GoogleFonts.manrope(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : color,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCollectionsList() {
    // Merge app collections + RECT billing software receipts
    final allCollections = <Map<String, dynamic>>[];

    // App collections (existing)
    for (final c in _collections) {
      allCollections.add({
        'source': 'app',
        'date': c['created_at']?.toString().substring(0, 10) ?? '',
        'amount': (c['amount_paid'] as num?)?.toDouble() ?? 0,
        'method': c['payment_mode'] ?? c['payment_method'] ?? 'Cash',
        'bill_no': c['bill_no'] ?? '',
        'drive_id': c['drive_file_id'],
      });
    }

    // RECT receipts from billing software
    for (final r in _receipts) {
      allCollections.add({
        'source': 'billing',
        'date': r['receipt_date'] as String? ?? '',
        'amount': (r['amount'] as num?)?.toDouble() ?? 0,
        'method': (r['cash_yn'] as bool? ?? false) ? 'CASH' : 'Bank',
        'bank': r['bank_name'] as String? ?? '',
        'receipt_no': r['receipt_no'] as String? ?? '',
      });
    }

    // Sort by date descending
    allCollections.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));

    if (allCollections.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.payments_outlined, size: 64, color: AppTheme.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text('No collections yet', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.onSurface)),
          ],
        ),
      );
    }

    final totalCollected = allCollections.fold(0.0, (sum, c) => sum + ((c['amount'] as num?)?.toDouble() ?? 0));

    return Column(
      children: [
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Text('Total Collected:', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('\u20B9${totalCollected.toStringAsFixed(0)}',
                style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.green.shade700)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            itemCount: allCollections.length,
            itemBuilder: (context, index) {
              final c = allCollections[index];
              final isApp = c['source'] == 'app';
              final method = c['method'] as String? ?? '';
              final isCash = method == 'CASH' || method == 'Cash';
              final dateStr = (c['date'] as String).isNotEmpty
                  ? DateFormat('dd MMM yyyy').format(DateTime.parse(c['date'] as String))
                  : '';
              final amt = (c['amount'] as num?)?.toDouble() ?? 0;

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: isCash ? Colors.orange.shade50 : Colors.green.shade50,
                      child: Icon(
                        isCash ? Icons.money : Icons.account_balance_rounded,
                        size: 16,
                        color: isCash ? Colors.orange.shade700 : Colors.green.shade700,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('\u20B9${amt.toStringAsFixed(0)}',
                              style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800, color: AppTheme.onSurface)),
                          Text(
                            isApp
                                ? 'Bill #${c['bill_no']} \u2022 $dateStr'
                                : () {
                                    final rcptNo = c['receipt_no'] as String? ?? '';
                                    final bills = _receiptBillMap[rcptNo];
                                    final billLabel = bills != null && bills.isNotEmpty
                                        ? 'Against ${bills.join(', ')}'
                                        : 'Rcpt #$rcptNo';
                                    final bank = c['bank'] as String? ?? '';
                                    return '$billLabel${bank.isNotEmpty ? ' \u2022 $bank' : ''} \u2022 $dateStr';
                                  }(),
                            style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isApp ? Colors.blue.withValues(alpha: 0.1) : Colors.teal.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isApp ? 'App' : 'Billing',
                        style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w700,
                            color: isApp ? Colors.blue : Colors.teal),
                      ),
                    ),
                    if (isApp && c['drive_id'] != null)
                      IconButton(
                        icon: Icon(Icons.camera_alt_outlined, color: AppTheme.primary, size: 18),
                        onPressed: () => _viewPaymentPhoto(context, c['drive_id']),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildInfoTab(CustomerModel c) {
    // Calculate totals from OPNBIL data
    final pendingBills = _outstandingBills.where((b) => !(b['cleared'] as bool? ?? false) && ((b['pending_amount'] as num?)?.toDouble() ?? 0) > 0);
    final totalOutstanding = pendingBills.fold(0.0, (sum, b) => sum + ((b['pending_amount'] as num?)?.toDouble() ?? 0));
    final totalBilled = _outstandingBills.fold(0.0, (sum, b) => sum + ((b['bill_amount'] as num?)?.toDouble() ?? 0));
    final totalReceived = _outstandingBills.fold(0.0, (sum, b) => sum + ((b['received_amount'] as num?)?.toDouble() ?? 0));
    final pendingBillCount = pendingBills.length;
    final overdueBills = pendingBills.where((b) {
      final cd = b['credit_days'] as int? ?? 0;
      final bd = b['bill_date'] as String? ?? '';
      if (cd <= 0 || bd.isEmpty) return false;
      return DateTime.now().isAfter(DateTime.parse(bd).add(Duration(days: cd)));
    }).length;

    // Use OPNBIL total if available, fall back to profile outstanding
    final balance = totalOutstanding > 0 ? totalOutstanding : c.outstandingForTeam(AuthService.currentTeam);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      child: Column(
        children: [
          // Outstanding summary card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: balance > 0 ? Colors.red.shade50 : Colors.green.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: balance > 0 ? Colors.red.shade300 : Colors.green.shade300, width: 1.5),
            ),
            child: Column(children: [
              Row(children: [
                Icon(balance > 0 ? Icons.warning_amber_rounded : Icons.check_circle_outline, color: balance > 0 ? Colors.red : Colors.green, size: 28),
                const SizedBox(width: 12),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Total Outstanding', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
                  Text('\u20B9${balance.toStringAsFixed(0)}',
                      style: GoogleFonts.manrope(fontSize: 22, fontWeight: FontWeight.w800, color: balance > 0 ? Colors.red.shade700 : Colors.green.shade700)),
                ]),
              ]),
              if (totalBilled > 0) ...[
                const SizedBox(height: 12),
                Row(children: [
                  _infoStat('Bills', '$pendingBillCount pending', Colors.orange),
                  const SizedBox(width: 8),
                  _infoStat('Billed', '\u20B9${totalBilled.toStringAsFixed(0)}', Colors.blue),
                  const SizedBox(width: 8),
                  _infoStat('Received', '\u20B9${totalReceived.toStringAsFixed(0)}', Colors.green),
                ]),
                if (overdueBills > 0) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: Colors.red.shade100, borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.schedule_rounded, size: 14, color: Colors.red.shade700),
                      const SizedBox(width: 4),
                      Text('$overdueBills overdue bill${overdueBills == 1 ? '' : 's'}',
                          style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.red.shade700)),
                    ]),
                  ),
                ],
              ],
            ]),
          ),
          const SizedBox(height: 16),
          // Customer details
          Container(
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.outlineVariant),
            ),
            child: Column(
              children: [
                _infoTile(Icons.location_on_outlined, 'Address', c.address.isNotEmpty ? c.address : '\u2014'),
                Divider(height: 1, color: AppTheme.outlineVariant),
                _infoTile(Icons.route_outlined, 'Route', c.deliveryRoute.isNotEmpty ? c.deliveryRoute : '\u2014'),
                Divider(height: 1, color: AppTheme.outlineVariant),
                _infoTile(Icons.map_outlined, 'Beat', c.beatNameForTeam(AuthService.currentTeam).isNotEmpty ? c.beatNameForTeam(AuthService.currentTeam) : '\u2014'),
                Divider(height: 1, color: AppTheme.outlineVariant),
                _infoTile(Icons.category_outlined, 'Type', c.type),
                if (c.gstin != null && c.gstin!.isNotEmpty) ...[
                  Divider(height: 1, color: AppTheme.outlineVariant),
                  _infoTile(Icons.receipt_outlined, 'GSTIN', c.gstin!),
                ],
                if (c.creditDays > 0) ...[
                  Divider(height: 1, color: AppTheme.outlineVariant),
                  _infoTile(Icons.schedule_outlined, 'Credit Days', '${c.creditDays} days'),
                ],
                if (c.creditLimit > 0) ...[
                  Divider(height: 1, color: AppTheme.outlineVariant),
                  _infoTile(Icons.credit_card_outlined, 'Credit Limit', '\u20B9${c.creditLimit.toStringAsFixed(0)}'),
                ],
                if (c.lockBill) ...[
                  Divider(height: 1, color: AppTheme.outlineVariant),
                  _infoTile(Icons.lock_outlined, 'Bill Lock', 'Locked'),
                ],
                Divider(height: 1, color: AppTheme.outlineVariant),
                _infoTile(Icons.badge_outlined, 'Customer ID', c.id),
                if (c.accCodeJa != null && c.accCodeJa!.isNotEmpty) ...[
                  Divider(height: 1, color: AppTheme.outlineVariant),
                  _infoTile(Icons.numbers_outlined, 'JA Code', c.accCodeJa!),
                ],
                if (c.accCodeMa != null && c.accCodeMa!.isNotEmpty) ...[
                  Divider(height: 1, color: AppTheme.outlineVariant),
                  _infoTile(Icons.numbers_outlined, 'MA Code', c.accCodeMa!),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoStat(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
        child: Column(children: [
          Text(value, style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(height: 2),
          Text(label, style: GoogleFonts.manrope(fontSize: 9, color: AppTheme.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Widget _infoTile(IconData icon, String label, String value) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.onSurfaceVariant, size: 20),
      title: Text(label, style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
      subtitle: Text(value, style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600)),
      dense: true,
    );
  }
}

// ─── Orders Tab View ───

class _OrdersTabView extends StatefulWidget {
  final List<OrderModel> orders;
  final void Function(double total, List<OrderModel> orders) onMultiSettle;

  const _OrdersTabView({required this.orders, required this.onMultiSettle});

  @override
  State<_OrdersTabView> createState() => _OrdersTabViewState();
}

class _OrdersTabViewState extends State<_OrdersTabView> {
  final Set<String> _selectedIds = {};
  final Set<String> _expandedIds = {};

  void _toggleSelection(OrderModel order) {
    setState(() {
      if (_selectedIds.contains(order.id)) {
        _selectedIds.remove(order.id);
      } else {
        _selectedIds.add(order.id);
      }
    });
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'pending': return Colors.orange;
      case 'confirmed': return Colors.blue;
      case 'invoiced': return Colors.purple;
      case 'delivered': return Colors.green;
      case 'returned': return Colors.orange;
      case 'verified': return Colors.teal;
      case 'paid': return Colors.green.shade800;
      case 'cancelled': return Colors.red;
      default: return Colors.grey;
    }
  }

  Future<void> _redeliverOrder(OrderModel order) async {
    final picker = ImagePicker();
    final photo = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 50,
      maxWidth: 1200,
      maxHeight: 1200,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (photo == null) return; // User cancelled camera

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Re-delivery confirmed! Processing in background.'), backgroundColor: Colors.green, duration: Duration(seconds: 2)),
    );

    // Fire-and-forget: update status + run background pipeline
    try {
      await SupabaseService.instance.updateOrderStatus(order.id, 'Pending Verification', isSuperAdmin: true);
      await SupabaseService.instance.processDeliveryBillWithBackgroundPipeline(
        orderId: order.id,
        imagePath: photo.path,
        extractedBillNo: null,
        extractedAmount: null,
      );
    } catch (e) {
      debugPrint('Re-deliver error: $e');
    }
  }

  void _viewBillPhoto(BuildContext context, String url) {
    // Google Drive `uc?export=view` URLs can redirect through an HTML page.
    // The thumbnail endpoint returns raw JPEG directly and is reliable in Flutter.
    final displayUrl = _toDriveDirectUrl(url);

    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 6.0,
              child: Center(
                child: CachedNetworkImage(
                  imageUrl: displayUrl,
                  fit: BoxFit.contain,
                  placeholder: (_, __) => const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                  errorWidget: (_, __, ___) => Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.broken_image_rounded, color: Colors.white54, size: 64),
                      const SizedBox(height: 12),
                      Text('Could not load image', style: GoogleFonts.manrope(color: Colors.white54)),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                        child: const Text('Open in Browser', style: TextStyle(color: Colors.lightBlueAccent)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Close button
            Positioned(
              top: 40, right: 16,
              child: CircleAvatar(
                backgroundColor: Colors.black54,
                child: IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
                ),
              ),
            ),
            // Open-in-browser button (always accessible for Drive photos)
            Positioned(
              top: 40, left: 16,
              child: CircleAvatar(
                backgroundColor: Colors.black54,
                child: IconButton(
                  tooltip: 'Open in browser',
                  onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_browser_rounded, color: Colors.white, size: 22),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Converts a Google Drive share URL to a direct-image URL usable in Image.network.
  /// Non-Drive URLs are returned unchanged.
  String _toDriveDirectUrl(String url) {
    // Pattern: https://drive.google.com/uc?export=view&id=FILE_ID
    final viewMatch = RegExp(r'drive\.google\.com/uc\?(?:export=view&id=|id=)([^&]+)').firstMatch(url);
    if (viewMatch != null) {
      final fileId = viewMatch.group(1)!;
      // thumbnail endpoint returns raw JPEG, no redirect page, no auth required for public files
      return 'https://drive.google.com/thumbnail?id=$fileId&sz=w2048-h2048';
    }
    // Pattern: https://drive.google.com/file/d/FILE_ID/view
    final fileMatch = RegExp(r'drive\.google\.com/file/d/([^/]+)').firstMatch(url);
    if (fileMatch != null) {
      final fileId = fileMatch.group(1)!;
      return 'https://drive.google.com/thumbnail?id=$fileId&sz=w2048-h2048';
    }
    return url; // Supabase or other URLs pass through unchanged
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.orders.where((o) => _selectedIds.contains(o.id)).toList();
    final total = selected.fold(0.0, (s, o) => s + o.grandTotal);

    return Stack(
      children: [
        ListView.builder(
          padding: EdgeInsets.fromLTRB(16, 12, 16, _selectedIds.isNotEmpty ? 90 : 24),
          itemCount: widget.orders.length,
          itemBuilder: (context, index) {
            final order = widget.orders[index];
            final isSelected = _selectedIds.contains(order.id);
            final isExpanded = _expandedIds.contains(order.id);
            final statusColor = _statusColor(order.status);

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: isSelected ? AppTheme.primaryContainer.withValues(alpha: 0.3) : AppTheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSelected ? AppTheme.primary : AppTheme.outlineVariant,
                  width: isSelected ? 1.5 : 1,
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  if (_selectedIds.isNotEmpty) {
                    _toggleSelection(order);
                  } else {
                    setState(() {
                      if (isExpanded) {
                        _expandedIds.remove(order.id);
                      } else {
                        _expandedIds.add(order.id);
                      }
                    });
                  }
                },
                onLongPress: () => _toggleSelection(order),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          if (_selectedIds.isNotEmpty)
                            Checkbox(
                              value: isSelected,
                              activeColor: AppTheme.primary,
                              onChanged: (_) => _toggleSelection(order),
                            ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      order.finalBillNo != null && order.finalBillNo!.isNotEmpty
                                          ? order.finalBillNo!
                                          : 'ORD-${order.id.split('-').last.toUpperCase()}',
                                      style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: statusColor.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        order.status,
                                        style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: statusColor),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '₹${order.grandTotal.toStringAsFixed(2)}',
                                  style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800, color: AppTheme.onSurface),
                                ),
                                Text(
                                  DateFormat('dd MMM yyyy').format(order.orderDate),
                                  style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant),
                                ),
                                if (order.billPhotoUrl != null && order.billPhotoUrl!.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  InkWell(
                                    onTap: () => _viewBillPhoto(context, order.billPhotoUrl!),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Colors.blue.shade50,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: Colors.blue.shade200),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.receipt_long_rounded, size: 11, color: Colors.blue.shade700),
                                          const SizedBox(width: 4),
                                          Text('View Bill', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.blue.shade700)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ] else if (order.status == 'Delivered' || order.status == 'Pending Verification' || order.status == 'Verified') ...[
                                  const SizedBox(height: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.no_photography_rounded, size: 11, color: Colors.grey.shade600),
                                        const SizedBox(width: 4),
                                        Text('No bill photo', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
                                      ],
                                    ),
                                  ),
                                ],
                                // Re-deliver button for returned orders
                                if (order.status == 'Returned') ...[
                                  const SizedBox(height: 6),
                                  InkWell(
                                    onTap: () => _redeliverOrder(order),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.shade50,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: Colors.orange.shade300),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.local_shipping_rounded, size: 12, color: Colors.orange.shade700),
                                          const SizedBox(width: 4),
                                          Text('Re-deliver', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.orange.shade700)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Icon(
                            isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                            color: AppTheme.onSurfaceVariant,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                    if (isExpanded && order.lineItems.isNotEmpty) ...[
                      Divider(height: 1, color: AppTheme.outlineVariant),
                      // Header
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        child: Row(children: [
                          Expanded(child: Text('Ordered Items', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.onSurfaceVariant))),
                          Text('Qty', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.onSurfaceVariant)),
                          const SizedBox(width: 12),
                          SizedBox(width: 50, child: Text('Amt', textAlign: TextAlign.right, style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.onSurfaceVariant))),
                        ]),
                      ),
                      ...order.lineItems.map((item) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.productName, style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
                                  if (item.sku.isNotEmpty) Text(item.sku, style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant)),
                                ],
                              ),
                            ),
                            Text('×${item.quantity}', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
                            const SizedBox(width: 12),
                            SizedBox(width: 50, child: Text('\u20B9${item.lineTotal.toStringAsFixed(0)}', textAlign: TextAlign.right, style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700))),
                          ],
                        ),
                      )),
                      // Show bill diff for verified orders
                      if (order.status == 'Verified' || order.status == 'Invoiced' || order.status == 'Paid')
                        _BilledItemsDiff(orderId: order.id, orderedItems: order.lineItems),
                      const SizedBox(height: 4),
                    ],
                  ],
                ),
              ),
            );
          },
        ),

        if (_selectedIds.isNotEmpty)
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, -2))],
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${selected.length} Bills Selected', style: GoogleFonts.manrope(fontSize: 12, color: Colors.grey)),
                      Text('₹${total.toStringAsFixed(2)}', style: GoogleFonts.manrope(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.primary)),
                    ],
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: () {
                      widget.onMultiSettle(total, selected);
                      setState(() => _selectedIds.clear());
                    },
                    icon: const Icon(Icons.payments),
                    label: const Text('Settle Now'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// _PaymentScreenshotPicker removed — UPI proof is captured via QR screen camera + WhatsApp sharing

/// Shows billed items vs ordered items diff for verified orders.
class _BilledItemsDiff extends StatefulWidget {
  final String orderId;
  final List<OrderItemModel> orderedItems;
  const _BilledItemsDiff({required this.orderId, required this.orderedItems});

  @override
  State<_BilledItemsDiff> createState() => _BilledItemsDiffState();
}

class _BilledItemsDiffState extends State<_BilledItemsDiff> {
  List<Map<String, dynamic>>? _billedItems;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await SupabaseService.instance.client
          .from('order_billed_items')
          .select()
          .eq('order_id', widget.orderId)
          .order('created_at');
      if (mounted) setState(() { _billedItems = List<Map<String, dynamic>>.from(items); _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Padding(padding: EdgeInsets.all(8), child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))));
    if (_billedItems == null || _billedItems!.isEmpty) return const SizedBox.shrink();

    // Build ordered items map: name -> qty
    final orderedMap = <String, int>{};
    for (final item in widget.orderedItems) {
      orderedMap[item.productName.toLowerCase()] = item.quantity;
    }

    // Build billed items map: name -> qty
    final billedMap = <String, double>{};
    for (final item in _billedItems!) {
      final name = (item['billed_item_name'] as String? ?? '').toLowerCase();
      billedMap[name] = (item['quantity'] as num?)?.toDouble() ?? 0;
    }

    // Find differences
    final diffs = <Widget>[];

    // Items in order but qty changed or removed in bill
    for (final entry in orderedMap.entries) {
      final billedQty = billedMap[entry.key];
      if (billedQty == null) {
        // Item not in bill — returned
        diffs.add(_diffRow(entry.key, 'Returned by customer', Colors.red));
      } else if (billedQty < entry.value) {
        final returned = entry.value - billedQty.toInt();
        diffs.add(_diffRow(entry.key, '$returned pcs returned', Colors.orange));
      }
    }

    // Items in bill but not in order — new
    for (final entry in billedMap.entries) {
      if (!orderedMap.containsKey(entry.key)) {
        diffs.add(_diffRow(entry.key, 'Added in bill (not ordered)', Colors.blue));
      }
    }

    if (diffs.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: 1, color: Colors.orange.shade200),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text('Bill Changes', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.orange.shade700)),
        ),
        ...diffs,
      ],
    );
  }

  Widget _diffRow(String name, String message, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      child: Row(children: [
        Icon(Icons.info_outline_rounded, size: 12, color: color),
        const SizedBox(width: 6),
        Expanded(child: Text(name, style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
        Text(message, style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }
}
