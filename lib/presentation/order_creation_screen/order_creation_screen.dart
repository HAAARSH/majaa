import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/supabase_service.dart';
import '../../services/auth_service.dart';
import '../../services/cart_service.dart';
import '../../services/offline_service.dart';
import '../../theme/app_theme.dart';
import './widgets/order_header_widget.dart';
import './widgets/order_line_item_widget.dart';
import './widgets/order_totals_card_widget.dart';
import './widgets/order_notes_widget.dart';
import './widgets/customer_info_card_widget.dart';

class OrderCreationScreen extends StatefulWidget {
  const OrderCreationScreen({super.key});

  @override
  State<OrderCreationScreen> createState() => _OrderCreationScreenState();
}

class _OrderCreationScreenState extends State<OrderCreationScreen> {
  bool _isSubmitting = false;
  bool _submitLock = false;
  final _notesController = TextEditingController();

  // 1. The Order Number variable
  late String _orderNumber;

  // 2. The Locked Date Variables we just added
  DateTime _selectedDate = DateTime.now();
  final DateTime _minDate = DateTime.now().subtract(const Duration(days: 1));
  final DateTime _maxDate = DateTime.now().add(const Duration(days: 1));

  CustomerModel? get _selectedCustomer => CartService.instance.currentCustomer;
  BeatModel? get _selectedBeat => CartService.instance.currentBeat;

  bool get _isEditing => CartService.instance.editingOrderId != null;

  @override
  void initState() {
    super.initState();

    // Reuse original order ID when editing, generate new one for fresh orders
    _orderNumber = CartService.instance.editingOrderId ??
        'ORD-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _selectLockedDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: _minDate, // 🚨 LOCKED: Cannot pick before yesterday
      lastDate: _maxDate,  // 🚨 LOCKED: Cannot pick after tomorrow
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: AppTheme.primary, // Selection color
              onPrimary: Colors.white,
              onSurface: Colors.black,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }


  Future<void> _shareToWhatsApp(String orderId, double total) async {
    if (_selectedCustomer == null) return;

    final String phone = _selectedCustomer!.phone;
    final String message =
        "✨ *Order Confirmation* ✨\n"
        "━━━━━━━━━━━━━━━\n"
        "Hello *${_selectedCustomer!.name}*,\n\n"
        "Your order has been placed successfully with *M.A.J.A.A. Distribution*.\n\n"
        "📦 *Order ID:* $orderId\n"
        "💰 *Total Amount:* ₹${total.toStringAsFixed(2)}\n"
        "🗓️ *Date:* ${_selectedDate.day}/${_selectedDate.month}/${_selectedDate.year}\n\n"
        "Thank you for your business! 🙏";

    final String url = "whatsapp://send?phone=$phone&text=${Uri.encodeComponent(message)}";

    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url));
    } else {
      // Fallback to web link if whatsapp scheme fails
      final String webUrl = "https://wa.me/$phone/?text=${Uri.encodeComponent(message)}";
      if (await canLaunchUrl(Uri.parse(webUrl))) {
        await launchUrl(Uri.parse(webUrl), mode: LaunchMode.externalApplication);
      } else {
        Fluttertoast.showToast(msg: "WhatsApp not found");
      }
    }
  }

  Future<void> _submitOrder() async {
    if (_submitLock) return;
    _submitLock = true;

    final cartItems = CartService.instance.cartNotifier.value;

    if (cartItems.isEmpty) {
      Fluttertoast.showToast(msg: 'Your cart is empty');
      _submitLock = false;
      return;
    }

    if (_selectedCustomer == null) {
      Fluttertoast.showToast(msg: 'Please select a customer');
      _submitLock = false;
      return;
    }

    // Brand access guard — remove items not in allowed brands
    final userId = SupabaseService.instance.client.auth.currentUser?.id;
    if (userId != null) {
      final allowedBrands = await SupabaseService.instance.getUserBrandAccess(userId);
      if (allowedBrands.isNotEmpty) {
        final violating = cartItems.where((ci) => !allowedBrands.contains(ci.product.category)).toList();
        if (violating.isNotEmpty) {
          for (final item in violating) {
            CartService.instance.deleteItemEntirely(item.product);
          }
          Fluttertoast.showToast(
            msg: '${violating.length} item(s) removed — not in your allowed brands',
            toastLength: Toast.LENGTH_LONG,
          );
          _submitLock = false;
          return; // let user review the updated cart before re-submitting
        }
      }
    }

    setState(() => _isSubmitting = true);

    // Calculate totals outside try so catch can access them for offline queue
    double subtotal = 0;
    double totalGst = 0;
    int totalUnits = 0;

    final List<Map<String, dynamic>> itemsJson = cartItems.map((item) {
        final lineTotal = item.product.unitPrice * item.quantity;
        final gst = (lineTotal * item.product.gstRate * 100).round() / 100;

        subtotal += lineTotal;
        totalGst += gst;
        totalUnits += item.quantity;

        return {
          'order_id': _orderNumber,
          'product_id': item.product.id,
          'product_name': item.product.name,
          'sku': item.product.sku,
          'quantity': item.quantity,
          'unit_price': item.product.unitPrice,
          'mrp': item.product.mrp,
          'line_total': lineTotal,
          'gst_rate': item.product.gstRate,
        };
      }).toList();

    final grandTotal = subtotal + totalGst;

    try {
      // If editing, delete the old order first (order ID is reused)
      if (_isEditing) {
        await SupabaseService.instance.deleteOrder(_orderNumber);
        CartService.instance.editingOrderId = null;
      }

      await SupabaseService.instance.createOrder(
        orderId: _orderNumber,
        customerId: _selectedCustomer!.id,
        customerName: _selectedCustomer!.name,
        beat: _selectedCustomer!.beatNameForTeam(AuthService.currentTeam).isNotEmpty ? _selectedCustomer!.beatNameForTeam(AuthService.currentTeam) : _selectedBeat?.beatName ?? '',
        deliveryDate: _selectedDate,
        subtotal: subtotal,
        vat: totalGst,
        grandTotal: grandTotal,
        itemCount: cartItems.length,
        totalUnits: totalUnits,
        notes: _notesController.text,
        items: itemsJson,
      );

      await SupabaseService.instance.updateCustomerLastOrder(
        _selectedCustomer!.id,
        grandTotal,
      );

      if (mounted) {
        setState(() => _isSubmitting = false);
        _submitLock = false;
        _showSuccessDialog(total: grandTotal);
      }
    } catch (e) {
      // Offline fallback — queue order for later sync
      try {
        await OfflineService.instance.queueOperation('order', {
          'order_id': _orderNumber,
          'customer_id': _selectedCustomer!.id,
          'customer_name': _selectedCustomer!.name,
          'beat': _selectedCustomer!.beatNameForTeam(AuthService.currentTeam).isNotEmpty ? _selectedCustomer!.beatNameForTeam(AuthService.currentTeam) : _selectedBeat?.beatName ?? '',
          'delivery_date': _selectedDate.toIso8601String(),
          'subtotal': subtotal,
          'vat': totalGst,
          'grand_total': grandTotal,
          'item_count': cartItems.length,
          'total_units': totalUnits,
          'notes': _notesController.text,
          'items': itemsJson,
        });
        if (mounted) {
          setState(() => _isSubmitting = false);
          _submitLock = false;
          Fluttertoast.showToast(msg: 'Order queued offline — will sync when connected');
          _showSuccessDialog(total: grandTotal);
        }
        return;
      } catch (_) {}
      if (mounted) {
        setState(() => _isSubmitting = false);
        _submitLock = false;
        Fluttertoast.showToast(msg: "Error: $e");
      }
    }
  }

  void _showSuccessDialog({required double total}) {
    final currentOrderId = _orderNumber;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(canPop: false, child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            const Icon(Icons.check_circle_rounded, color: Colors.green, size: 64),
            const SizedBox(height: 16),
            Text(
              'Order Placed!',
              style: GoogleFonts.manrope(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              'Order ID: $currentOrderId',
              style: GoogleFonts.manrope(fontSize: 14, color: AppTheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: () => _shareToWhatsApp(currentOrderId, total),
                icon: const Icon(Icons.share, color: Colors.green, size: 18),
                label: const Text('Share Receipt', style: TextStyle(color: Colors.green)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.green),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                onPressed: () {
                  CartService.instance.clearCart();
                  // Safely pop back to root, avoiding crashes if stack is shorter than expected
                  int popCount = 0;
                  Navigator.of(context).popUntil((route) => popCount++ >= 4 || route.isFirst);
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text('Review Order', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        backgroundColor: AppTheme.surface,
        elevation: 0,
        centerTitle: true,
      ),
      body: ValueListenableBuilder<List<CartItem>>(
        valueListenable: CartService.instance.cartNotifier,
        builder: (context, cartItems, _) {
          if (cartItems.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.shopping_cart_outlined, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text('Your cart is empty', style: GoogleFonts.manrope(fontSize: 16, color: Colors.grey)),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Go Back'),
                  ),
                ],
              ),
            );
          }

          double subtotal = 0;
          double totalGst = 0;
          int totalUnits = 0;
          for (var item in cartItems) {
            final lineTotal = item.product.unitPrice * item.quantity;
            subtotal += lineTotal;
            totalGst += (lineTotal * item.product.gstRate * 100).round() / 100;
            totalUnits += item.quantity;
          }

          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    OrderHeaderWidget(orderNumber: _orderNumber, orderDate: _selectedDate),
                    const SizedBox(height: 16),
                    const SizedBox(height: 10),
                    Container(
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppTheme.outlineVariant),
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: cartItems.length,
                        separatorBuilder: (_, __) => Divider(height: 1, color: AppTheme.outlineVariant),
                        itemBuilder: (ctx, index) => OrderLineItemWidget(
                          cartItem: cartItems[index],
                          index: index,
                          onQuantityChanged: (q) => CartService.instance.setItemQuantity(cartItems[index].product, q),
                          onRemove: () => CartService.instance.deleteItemEntirely(cartItems[index].product),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    OrderNotesWidget(controller: _notesController),
                    const SizedBox(height: 16),
                    OrderTotalsCardWidget(
                      subtotal: subtotal,
                      totalGst: totalGst,
                      grandTotal: subtotal + totalGst,
                      totalUnits: totalUnits,
                      totalLines: cartItems.length,
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
              // Bottom Action Bar
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  boxShadow: [BoxShadow(color: Colors.black.withAlpha(12), blurRadius: 10, offset: const Offset(0, -4))],
                ),
                child: SafeArea(
                  child: SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: FilledButton(
                      onPressed: _isSubmitting ? null : _submitOrder,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: _isSubmitting
                          ? const CircularProgressIndicator(color: Colors.white)
                          : Text('Confirm & Place Order', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
