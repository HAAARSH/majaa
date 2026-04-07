import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/app_routes.dart';
import '../../theme/app_theme.dart';
import '../../services/supabase_service.dart';
import '../../services/cart_service.dart';
import '../../services/offline_service.dart';
import './widgets/customer_info_card_widget.dart';
import './widgets/order_header_widget.dart';
import './widgets/order_line_item_widget.dart';
import './widgets/order_notes_widget.dart';
import './widgets/order_totals_card_widget.dart';

class OrderCreationScreen extends StatefulWidget {
  const OrderCreationScreen({super.key});

  @override
  State<OrderCreationScreen> createState() => _OrderCreationScreenState();
}

class _OrderCreationScreenState extends State<OrderCreationScreen>
    with TickerProviderStateMixin {
  bool _isSubmitting = false;
  final _notesController = TextEditingController();
  List<CustomerModel> _customers = [];
  bool _loadingCustomers = true;
  late AnimationController _entranceController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  final String _orderNumber =
      'ORD-${DateTime.now().year}-${(DateTime.now().millisecondsSinceEpoch % 100000).toString().padLeft(5, '0')}';

  CustomerModel? get _selectedCustomer => CartService.instance.currentCustomer;
  BeatModel? get _selectedBeat => CartService.instance.currentBeat;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400));
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _entranceController, curve: Curves.easeOut));
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(CurvedAnimation(
            parent: _entranceController, curve: Curves.easeOutCubic));
    _loadCustomers();
    _entranceController.forward();
  }

  Future<void> _loadCustomers() async {
    try {
      final list = await SupabaseService.instance.getCustomers();
      if (!mounted) return;
      setState(() => _customers = list);
    } finally {
      if (mounted) setState(() => _loadingCustomers = false);
    }
  }

  Future<void> _submitOrder() async {
    final cartItems = CartService.instance.cartNotifier.value;

    if (cartItems.isEmpty || _selectedCustomer == null) {
      Fluttertoast.showToast(
          msg: 'Add items and select a customer',
          backgroundColor: AppTheme.warning,
          textColor: Colors.white);
      return;
    }

    setState(() => _isSubmitting = true);

    final items = cartItems
        .map((item) => {
              'order_id': _orderNumber,
              'product_id': item.product.id,
              'product_name': item.product.name,
              'sku': item.product.sku,
              'quantity': item.quantity,
              'unit_price': item.product.unitPrice,
              'gst_rate': item.product.gstRate,
              'line_total': item.product.unitPrice * item.quantity,
            })
        .toList();

    final subtotal = double.parse(cartItems.fold(
        0.0, (sum, item) => sum + item.product.unitPrice * item.quantity).toStringAsFixed(2));
    final totalGst = double.parse(cartItems.fold(
        0.0,
        (sum, item) =>
            sum +
            (item.product.unitPrice * item.quantity * item.product.gstRate)).toStringAsFixed(2));
    final grandTotal = double.parse((subtotal + totalGst).toStringAsFixed(2));
    final totalUnits = cartItems.fold(0, (sum, item) => sum + item.quantity);
    final deliveryDate = DateTime.now();

    final fullOrderData = {
      'orderId': _orderNumber,
      'customerId': _selectedCustomer?.id,
      'customerName': _selectedCustomer?.name ?? '',
      'beat': _selectedCustomer?.beat ?? _selectedBeat?.beatName ?? '',
      'deliveryDate': deliveryDate.toIso8601String(),
      'subtotal': subtotal,
      'vat': totalGst,
      'grandTotal': grandTotal,
      'itemCount': cartItems.length,
      'totalUnits': totalUnits,
      'notes': _notesController.text,
      'items': items,
    };

    try {
      final persistedId = await SupabaseService.instance.createOrder(
        orderId: _orderNumber,
        customerId: _selectedCustomer?.id,
        customerName: _selectedCustomer?.name ?? '',
        beat: _selectedCustomer?.beat ?? _selectedBeat?.beatName ?? '',
        deliveryDate: deliveryDate,
        subtotal: subtotal,
        vat: totalGst,
        grandTotal: grandTotal,
        itemCount: cartItems.length,
        totalUnits: totalUnits,
        notes: _notesController.text,
        items: items,
      );

      if (!mounted) return;
      if (persistedId.isEmpty) throw Exception('Failed');

      setState(() => _isSubmitting = false);
      _showSuccessDialog(isOffline: false);
    } catch (e) {
      await OfflineService.instance.queueOrder(fullOrderData);

      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showSuccessDialog(isOffline: true);
    }
  }

  void _showSuccessDialog({required bool isOffline}) {
    CartService.instance.clearCart();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                    color: isOffline
                        ? AppTheme.warningContainer
                        : AppTheme.statusAvailableContainer,
                    shape: BoxShape.circle),
                child: Icon(
                    isOffline
                        ? Icons.wifi_off_rounded
                        : Icons.check_circle_rounded,
                    color:
                        isOffline ? AppTheme.warning : AppTheme.statusAvailable,
                    size: 40)),
            const SizedBox(height: 16),
            Text(isOffline ? 'Saved Offline' : 'Order Submitted!',
                style: GoogleFonts.manrope(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.onSurface)),
            const SizedBox(height: 8),
            Text(_orderNumber,
                style: GoogleFonts.manrope(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primary,
                    letterSpacing: 0.5)),
            if (isOffline) ...[
              const SizedBox(height: 12),
              Text(
                'No internet connection. Order saved locally and will sync automatically when online.',
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(
                    fontSize: 12, color: AppTheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).popUntil((route) =>
                      route.settings.name == AppRoutes.customerListScreen);
                },
                style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                child: Text('Back to Customers',
                    style: GoogleFonts.manrope(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<CartItem>>(
        valueListenable: CartService.instance.cartNotifier,
        builder: (context, cartItems, _) {
          final subtotal = cartItems.fold(
              0.0, (sum, item) => sum + item.product.unitPrice * item.quantity);
          final totalGst = cartItems.fold(
              0.0,
              (sum, item) =>
                  sum +
                  (item.product.unitPrice *
                      item.quantity *
                      item.product.gstRate));
          final grandTotal = subtotal + totalGst;
          final totalUnits =
              cartItems.fold(0, (sum, item) => sum + item.quantity);
          final isTablet = MediaQuery.of(context).size.width >= 600;

          return Scaffold(
            backgroundColor: AppTheme.background,
            appBar: AppBar(
              backgroundColor: AppTheme.surface,
              elevation: 0,
              leading: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded,
                      color: AppTheme.onSurface),
                  onPressed: () => Navigator.pop(context)),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('New Order',
                      style: GoogleFonts.manrope(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.onSurface)),
                  Text(_orderNumber,
                      style: GoogleFonts.manrope(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.primary)),
                ],
              ),
            ),
            body: SafeArea(
              child: FadeTransition(
                opacity: _fadeAnim,
                child: SlideTransition(
                  position: _slideAnim,
                  child: isTablet
                      ? _buildTabletLayout(
                          cartItems, subtotal, totalGst, grandTotal, totalUnits)
                      : _buildPhoneLayout(cartItems, subtotal, totalGst,
                          grandTotal, totalUnits),
                ),
              ),
            ),
          );
        });
  }

  Widget _buildPhoneLayout(List<CartItem> cartItems, double subtotal,
      double totalGst, double grandTotal, int totalUnits) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OrderHeaderWidget(
            orderNumber: _orderNumber,
            orderDate: DateTime.now(),
          ),
          const SizedBox(height: 16),
          CustomerInfoCardWidget(
            customers: _customers,
            customer: _selectedCustomer,
            isLoading: _loadingCustomers,
            onCustomerSelected: (c) {
              if (c != null) {
                CartService.instance.setCustomerSession(c, _selectedBeat);
                setState(() {});
              }
            },
          ),
          const SizedBox(height: 16),
          _buildOrderLinesSection(cartItems, totalUnits),
          const SizedBox(height: 16),
          OrderNotesWidget(controller: _notesController),
          const SizedBox(height: 16),
          OrderTotalsCardWidget(
              subtotal: subtotal,
              totalGst: totalGst,
              grandTotal: grandTotal,
              totalUnits: totalUnits,
              totalLines: cartItems.length),
          const SizedBox(height: 24),
          _buildSubmitButton(cartItems, grandTotal),
        ],
      ),
    );
  }

  Widget _buildTabletLayout(List<CartItem> cartItems, double subtotal,
      double totalGst, double grandTotal, int totalUnits) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 65,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OrderHeaderWidget(
                  orderNumber: _orderNumber,
                  orderDate: DateTime.now(),
                ),
                const SizedBox(height: 16),
                _buildOrderLinesSection(cartItems, totalUnits),
                const SizedBox(height: 16),
                OrderNotesWidget(controller: _notesController),
              ],
            ),
          ),
        ),
        Expanded(
          flex: 35,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(8, 12, 16, 32),
            child: Column(
              children: [
                CustomerInfoCardWidget(
                  customers: _customers,
                  customer: _selectedCustomer,
                  isLoading: _loadingCustomers,
                  onCustomerSelected: (c) {
                    if (c != null) {
                      CartService.instance.setCustomerSession(c, _selectedBeat);
                      setState(() {});
                    }
                  },
                ),
                const SizedBox(height: 16),
                OrderTotalsCardWidget(
                    subtotal: subtotal,
                    totalGst: totalGst,
                    grandTotal: grandTotal,
                    totalUnits: totalUnits,
                    totalLines: cartItems.length),
                const SizedBox(height: 16),
                _buildSubmitButton(cartItems, grandTotal),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOrderLinesSection(List<CartItem> cartItems, int totalUnits) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.receipt_long_rounded,
                size: 18, color: AppTheme.primary),
            const SizedBox(width: 8),
            Text('Order Lines',
                style: GoogleFonts.manrope(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.onSurface)),
          ],
        ),
        const SizedBox(height: 10),
        if (cartItems.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.outlineVariant)),
            child: const Center(child: Text('No products added yet')),
          )
        else
          Container(
            decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.outlineVariant)),
            child: ListView.separated(
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              itemCount: cartItems.length,
              separatorBuilder: (_, __) => Divider(
                  height: 1,
                  color: AppTheme.outlineVariant,
                  indent: 16,
                  endIndent: 16),
              itemBuilder: (context, index) {
                return OrderLineItemWidget(
                  key: ValueKey(cartItems[index].product.id),
                  cartItem: cartItems[index],
                  index: index,
                  onQuantityChanged: (qty) => CartService.instance
                      .setItemQuantity(cartItems[index].product, qty),
                  onRemove: () => CartService.instance
                      .deleteItemEntirely(cartItems[index].product),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildSubmitButton(List<CartItem> cartItems, double grandTotal) {
    final bool hasItems = cartItems.isNotEmpty;
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: FilledButton(
        onPressed: (hasItems && !_isSubmitting) ? _submitOrder : null,
        style: FilledButton.styleFrom(
            backgroundColor: AppTheme.secondary,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14))),
        child: _isSubmitting
            ? const CircularProgressIndicator(color: Colors.white)
            : Text(
                hasItems
                    ? 'Submit Order · ₹${grandTotal.toStringAsFixed(2)}'
                    : 'Submit Order',
                style: GoogleFonts.manrope(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
      ),
    );
  }
}
