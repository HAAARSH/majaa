import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/pricing.dart';
import '../../services/supabase_service.dart';
import '../../services/auth_service.dart';
import '../../services/billing_rules_service.dart';
import '../../services/cart_service.dart';
import '../../services/offline_service.dart';
import '../../theme/app_theme.dart';
import './widgets/order_header_widget.dart';
import './widgets/order_line_item_widget.dart';
import './widgets/order_totals_card_widget.dart';
import './widgets/order_notes_widget.dart';

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

  // Delivery date is fixed to tomorrow. Whether it actually ships on time
  // is an admin/delivery concern, not the rep's.
  final DateTime _selectedDate =
      DateTime.now().add(const Duration(days: 1));

  CustomerModel? get _selectedCustomer => CartService.instance.currentCustomer;
  BeatModel? get _selectedBeat => CartService.instance.currentBeat;

  bool get _isEditing => CartService.instance.editingOrderId != null;

  @override
  void initState() {
    super.initState();

    // Reuse original order ID when editing, generate new one for fresh orders.
    // Full 13-digit millis + 4-hex-char random suffix so two reps submitting
    // within the same second cannot collide (createOrder uses upsert).
    final rand = Random().nextInt(0xFFFF).toRadixString(16).toUpperCase().padLeft(4, '0');
    _orderNumber = CartService.instance.editingOrderId ??
        'ORD-${DateTime.now().millisecondsSinceEpoch}-$rand';
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _shareToWhatsApp(String orderId, double total) async {
    if (_selectedCustomer == null) return;

    final String phone = _selectedCustomer!.phone;
    // Guard: without a phone, whatsapp://send?phone= opens a blank chat and
    // wa.me/ opens a browser error. Tell the rep directly instead.
    if (phone.trim().isEmpty || phone.trim().toLowerCase() == 'no phone') {
      Fluttertoast.showToast(
        msg: 'No phone number on file — cannot share via WhatsApp.',
        toastLength: Toast.LENGTH_LONG,
      );
      return;
    }
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

    if (_selectedCustomer == null) {
      Fluttertoast.showToast(msg: 'Please select a customer');
      _submitLock = false;
      return;
    }

    // Defense-in-depth: brand access is enforced at product list time
    // (see products_screen), but a stale cart restored from a previous
    // session could theoretically contain now-disallowed items. Instead of
    // silently dropping them, we block submit with a confirmation listing
    // the affected items so the rep knows exactly what's being removed and
    // can renegotiate with the customer before placing the order.
    final userId = SupabaseService.instance.client.auth.currentUser?.id;
    if (userId != null) {
      final allowedBrands = await SupabaseService.instance.getUserBrandAccess(userId);
      if (allowedBrands.isNotEmpty) {
        final violating = CartService.instance.cartNotifier.value
            .where((ci) => !allowedBrands.contains(ci.product.category)).toList();
        if (violating.isNotEmpty) {
          final proceed = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Text('Some items are no longer allowed'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Your brand access has changed. These items must be removed before placing the order:',
                  ),
                  const SizedBox(height: 12),
                  ...violating.map((ci) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '• ${ci.product.name}  ×${ci.quantity}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      )),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel & Review'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Remove & Continue'),
                ),
              ],
            ),
          );
          if (proceed != true) {
            _submitLock = false;
            return;
          }
          for (final item in violating) {
            CartService.instance.deleteItemEntirely(item.product);
          }
        }
      }
    }
    if (!mounted) { _submitLock = false; return; }

    // Re-read the cart AFTER any brand-access strip so we never submit a cart
    // that was mutated behind our back.
    final cartItems = CartService.instance.cartNotifier.value;

    if (cartItems.isEmpty) {
      Fluttertoast.showToast(msg: 'Your cart is empty');
      _submitLock = false;
      return;
    }

    // Resolve beat_name with explicit fallbacks. The REP's currently-selected
    // beat wins — the order belongs to wherever the rep physically placed it
    // (so pending lists and delivery manifests bucket correctly). Customer's
    // primary ACMAST beat is only a fallback for admin / edit / cart-restore
    // paths where no rep beat is set. This also makes the ordering-beat
    // override feature work naturally: a customer with primary=Dharampur,
    // order_beat=Panditvari gets tagged Panditvari when the rep is on that
    // route, so the pending order shows up in the right rep's list.
    // Empty beat still rejects — an untagged order breaks NDD + manifests.
    final repBeatName = _selectedBeat?.beatName ?? '';
    final customerBeatName = _selectedCustomer!.beatNameForTeam(AuthService.currentTeam);
    final resolvedBeatName = repBeatName.isNotEmpty
        ? repBeatName
        : (customerBeatName.isNotEmpty
            ? customerBeatName
            : (CartService.instance.editingOriginalBeatName ?? ''));

    if (resolvedBeatName.isEmpty) {
      Fluttertoast.showToast(
        msg: 'Beat not set — cannot place order. Assign this customer to a beat first.',
        toastLength: Toast.LENGTH_LONG,
      );
      _submitLock = false;
      return;
    }

    setState(() => _isSubmitting = true);

    // Calculate totals outside try so catch can access them for offline queue
    double subtotal = 0;
    double totalGst = 0;
    int totalUnits = 0;

    // Load the per-team CSDS flag once and flip the global switch so every
    // priceFor() in this submission uses the same setting. Default OFF (safe);
    // admin enables per team from the Rules tab once smoke-tested.
    CsdsPricing.enabled = await BillingRulesService.instance
        .isCsdsEnabled(AuthService.currentTeam);

    // Build line items. When CsdsPricing.enabled is true we route each line
    // through priceFor() so the customer's DUA-synced discount cascade is
    // applied. When OFF the breakdown still returns a valid result (just
    // rate × qty + GST), so the same code path handles both modes.
    // Track the worst/best outcome across lines for the order-level audit
    // flag so admin can answer "why did this order come out this way?"
    // without re-running the cascade.
    bool anyRuleMatched = false;
    bool anyScheme = false;
    bool anyMissingBrand = false;
    final List<Map<String, dynamic>> itemsJson = [];
    for (final item in cartItems) {
      final product = item.product;
      // Fetch latest product to get ITEM-enriched fields (item_group,
      // vat_per, maybe company). Cart's Product model is a snapshot at
      // add-time so pricing decisions need fresh values.
      final fresh = CsdsPricing.enabled
          ? await SupabaseService.instance.getProductById(product.id)
          : null;
      // CSDS.COMPANY field = brand name. products.category is the
      // authoritative brand (populated at product creation or from ITMRP
      // stock sync). fresh.company (ITEM master) is same data but only
      // present after an ITEM sync has run — use as fallback only so the
      // CsdsPricing path works before ITEM sync lands.
      final brand = (fresh?.category.isNotEmpty ?? false)
          ? fresh!.category
          : (fresh?.company ?? product.category);
      final itemGroup = fresh?.itemGroup ?? '';
      final taxPercent = fresh != null && fresh.totalTaxPercent > 0
          ? fresh.totalTaxPercent
          : product.gstRate * 100;

      final breakdown = await CsdsPricing.priceFor(
        baseRate: product.unitPrice,
        qty: item.quantity,
        taxPercent: taxPercent,
        customerId: _selectedCustomer!.id,
        company: brand,
        itemGroup: itemGroup,
      );

      if (CsdsPricing.enabled) {
        if (brand.isEmpty) {
          anyMissingBrand = true;
        } else if (breakdown.rule != null) {
          anyRuleMatched = true;
          if (breakdown.freeQty > 0) anyScheme = true;
        }
      }

      final lineTotal = breakdown.taxable;
      final gst = (breakdown.tax * 100).round() / 100;

      subtotal += lineTotal;
      totalGst += gst;
      totalUnits += item.quantity;

      itemsJson.add({
        'order_id': _orderNumber,
        'product_id': product.id,
        'product_name': product.name,
        'sku': product.sku,
        'quantity': item.quantity,
        'unit_price': breakdown.netRate, // discount-applied per-unit rate
        'mrp': product.mrp,
        'line_total': lineTotal,
        'gst_rate': taxPercent / 100.0,
        // Discount/scheme metadata — null when no CSDS rule matched.
        if (breakdown.rule != null) 'csds_disc_per': breakdown.rule!.discPer,
        if (breakdown.rule != null) 'csds_disc_per_3': breakdown.rule!.discPer3,
        if (breakdown.rule != null) 'csds_disc_per_5': breakdown.rule!.discPer5,
        if (breakdown.freeQty > 0) 'free_qty': breakdown.freeQty,
      });
    }

    final grandTotal = subtotal + totalGst;

    try {
      // If editing, delete the old order first (order ID is reused)
      if (_isEditing) {
        await SupabaseService.instance.deleteOrder(_orderNumber);
        CartService.instance.editingOrderId = null;
      }

      // Summarise the cascade outcome for admin drilldown.
      String csdsStatus;
      if (!CsdsPricing.enabled) {
        csdsStatus = 'flag_off';
      } else if (anyScheme) {
        csdsStatus = 'scheme_matched';
      } else if (anyRuleMatched) {
        csdsStatus = 'rule_matched';
      } else if (anyMissingBrand) {
        csdsStatus = 'no_brand';
      } else {
        csdsStatus = 'no_rule';
      }

      await SupabaseService.instance.createOrder(
        orderId: _orderNumber,
        customerId: _selectedCustomer!.id,
        customerName: _selectedCustomer!.name,
        beat: resolvedBeatName,
        deliveryDate: _selectedDate,
        subtotal: subtotal,
        vat: totalGst,
        grandTotal: grandTotal,
        itemCount: cartItems.length,
        totalUnits: totalUnits,
        notes: _notesController.text,
        items: itemsJson,
        isOutOfBeat: CartService.instance.isOutOfBeat,
        csdsStatus: csdsStatus,
      );

      await SupabaseService.instance.updateCustomerLastOrder(
        _selectedCustomer!.id,
        grandTotal,
      );

      // Auto-log a visit on successful order submission so "Not Visited" badge
      // clears immediately and visit analytics count customers with orders as
      // visited. Skipped on edit — the original order already produced a visit.
      if (!_isEditing) {
        try {
          await SupabaseService.instance.logVisit(
            customerId: _selectedCustomer!.id,
            beatId: _selectedBeat?.id ?? '',
            reason: 'order_placed',
            isOutOfBeat: CartService.instance.isOutOfBeat,
          );
        } catch (_) {
          // Don't block the order success on a visit-log hiccup.
        }
      }

      if (mounted) {
        setState(() => _isSubmitting = false);
        _submitLock = false;
        _showSuccessDialog(total: grandTotal, isOffline: false);
      }
    } catch (e) {
      // Offline fallback — queue order for later sync
      try {
        await OfflineService.instance.queueOperation('order', {
          'order_id': _orderNumber,
          'customer_id': _selectedCustomer!.id,
          'customer_name': _selectedCustomer!.name,
          'beat': resolvedBeatName,
          'is_out_of_beat': CartService.instance.isOutOfBeat,
          'delivery_date': _selectedDate.toIso8601String(),
          'subtotal': subtotal,
          'vat': totalGst,
          'grand_total': grandTotal,
          'item_count': cartItems.length,
          'total_units': totalUnits,
          'notes': _notesController.text,
          'items': itemsJson,
        });
        // Also queue an auto-visit log so offline orders still count as visits
        // once sync runs. Same edit-guard as the online path.
        if (!_isEditing) {
          try {
            await OfflineService.instance.queueOperation('visit_log', {
              'customer_id': _selectedCustomer!.id,
              'beat_id': _selectedBeat?.id ?? '',
              'reason': 'order_placed',
              'is_out_of_beat': CartService.instance.isOutOfBeat,
            });
          } catch (_) {}
        }
        if (mounted) {
          setState(() => _isSubmitting = false);
          _submitLock = false;
          Fluttertoast.showToast(msg: 'Order queued offline — will sync when connected');
          _showSuccessDialog(total: grandTotal, isOffline: true);
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

  Widget _buildCustomerSummaryCard(CustomerModel customer) {
    final hasPhone = customer.phone.trim().isNotEmpty &&
        customer.phone.trim().toLowerCase() != 'no phone';
    final hasAddress = customer.address.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppTheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.storefront_rounded,
                    size: 18, color: AppTheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Billing To',
                      style: GoogleFonts.manrope(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      customer.name,
                      style: GoogleFonts.manrope(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.onSurface,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.phone_outlined,
                  size: 14, color: AppTheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hasPhone ? customer.phone : 'No phone',
                  style: GoogleFonts.manrope(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: hasPhone ? AppTheme.onSurface : Colors.red,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.location_on_outlined,
                    size: 14, color: AppTheme.onSurfaceVariant),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hasAddress ? customer.address : 'No address',
                  style: GoogleFonts.manrope(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showSuccessDialog({required double total, required bool isOffline}) {
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
              isOffline ? 'Order Saved!' : 'Order Placed!',
              style: GoogleFonts.manrope(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            // Bigger, primary-colored, tappable to copy. Reps read it
            // quickly at the shop counter and often paste it into WhatsApp.
            InkWell(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: currentOrderId));
                Fluttertoast.showToast(msg: 'Order ID copied');
              },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Order ID: $currentOrderId',
                      style: GoogleFonts.manrope(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.copy_rounded, size: 16, color: AppTheme.primary),
                  ],
                ),
              ),
            ),
            if (isOffline) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.orange.shade700, width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off_rounded, size: 16, color: Colors.orange.shade900),
                    const SizedBox(width: 6),
                    Text(
                      'Saved offline — will upload when connected',
                      style: GoogleFonts.manrope(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.orange.shade900,
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
    return PopScope(
      canPop: !_submitLock,
      child: Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text('Review Order', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        backgroundColor: AppTheme.surface,
        elevation: 0,
        centerTitle: true,
        // OOB badge — makes it obvious to the rep (and anyone looking over
        // their shoulder) that this order is tagged as out-of-beat. Prevents
        // accidentally submitting an OOB order thinking it's a normal one.
        bottom: CartService.instance.isOutOfBeat
            ? PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Container(
                  width: double.infinity,
                  color: Colors.orange.shade700,
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.add_location_alt_rounded, color: Colors.white, size: 14),
                      const SizedBox(width: 6),
                      Text(
                        'OUT OF BEAT ORDER',
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : null,
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
                    const SizedBox(height: 12),
                    if (_selectedCustomer != null)
                      _buildCustomerSummaryCard(_selectedCustomer!),
                    const SizedBox(height: 14),
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
                    // Hint appears only when the CSDS flag is ON for this
                    // team. The preview here multiplies raw unit_price ×
                    // qty; the saved order runs through CsdsPricing and
                    // can come out lower. Warn so the rep doesn't quote a
                    // pre-discount number.
                    const _CsdsPreSaveHint(),
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
    ));
  }
}

/// Shows "CSDS applies on Save" under the totals card only when the flag
/// is ON for the current team. Silently hides when OFF so the hint never
/// distracts reps on teams that aren't using the cascade yet.
class _CsdsPreSaveHint extends StatefulWidget {
  const _CsdsPreSaveHint();

  @override
  State<_CsdsPreSaveHint> createState() => _CsdsPreSaveHintState();
}

class _CsdsPreSaveHintState extends State<_CsdsPreSaveHint> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final on = await BillingRulesService.instance
        .isCsdsEnabled(AuthService.currentTeam);
    if (!mounted) return;
    setState(() => _on = on);
  }

  @override
  Widget build(BuildContext context) {
    if (_on != true) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Icon(Icons.info_outline_rounded, size: 12, color: AppTheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Pre-discount. CSDS cascade applies on Save — final invoice may be lower.',
            style: GoogleFonts.manrope(
                fontSize: 11,
                color: AppTheme.onSurfaceVariant,
                fontStyle: FontStyle.italic),
          ),
        ),
      ]),
    );
  }
}
