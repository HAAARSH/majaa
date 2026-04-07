import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/auth_service.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';
import '../../routes/app_routes.dart';
import '../../utils/loading_helper.dart';
import '../../widgets/hero_avatar_widget.dart';
import '../../widgets/hero_selfie_modal.dart';

class DeliveryDashboardScreen extends StatefulWidget {
  const DeliveryDashboardScreen({super.key});

  @override
  State<DeliveryDashboardScreen> createState() => _DeliveryDashboardScreenState();
}

class _DeliveryDashboardScreenState extends State<DeliveryDashboardScreen> {
  final _service = SupabaseService.instance;
  bool _isLoading = true;
  List<Map<String, dynamic>> _allDeliveries = [];

  String _selectedRoute = 'All Routes';
  List<String> _availableRoutes = ['All Routes'];

  // Track completed orders for success animation
  final Set<String> _completedOrderIds = {};

  // Search
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // User info for hero badge
  String? _heroImageUrl;
  String _userInitials = '';

  // One GlobalKey per order so we can reset the slider on cancel/retake
  final Map<String, GlobalKey<_SwipeToCompleteSliderState>> _sliderKeys = {};

  @override
  void initState() {
    super.initState();
    _loadDeliveries();
    _loadUserInfo();
  }

  Future<void> _loadUserInfo() async {
    final user = await _service.getCurrentUser();
    if (user != null && mounted) {
      final parts = user.fullName.trim().split(' ');
      setState(() {
        _heroImageUrl = user.heroImageUrl;
        _userInitials = parts.length >= 2
            ? '${parts.first[0]}${parts.last[0]}'.toUpperCase()
            : (parts.first.isNotEmpty ? parts.first[0].toUpperCase() : '?');
      });

      // Force selfie if no avatar
      if ((user.heroImageUrl == null || user.heroImageUrl!.isEmpty) && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => HeroSelfieModal(
              userId: user.id,
              fullName: user.fullName,
              onSuccess: () {
                Navigator.pop(context);
                _loadUserInfo(); // Reload to show new avatar
              },
            ),
          );
        });
      }
    }
  }

  Future<void> _loadDeliveries() async {
    setState(() => _isLoading = true);
    try {
      final data = await _service.getActiveDeliveries();
      if (!mounted) return;

      final Set<String> routesSet = {'All Routes'};
      final validDeliveries = data.where((order) {
        final String status = (order['status'] ?? '').toString().trim().toLowerCase();
        final routeName = order['delivery_route']?.toString() ??
            order['customers']?['delivery_route']?.toString() ??
            'Unassigned';

        if (status == 'pending') {
          routesSet.add(routeName);
          return true;
        }
        return false;
      }).toList();

      // Clean up slider keys for deliveries that are no longer active
      final currentDeliveryIds = validDeliveries.map((order) => order['id'].toString()).toSet();
      final keysToRemove = _sliderKeys.keys.where((key) => !currentDeliveryIds.contains(key)).toList();
      
      for (final key in keysToRemove) {
        _sliderKeys.remove(key);
      }

      // Sort by delivery route for logical route order
      validDeliveries.sort((a, b) {
        final routeA = a['delivery_route']?.toString() ?? a['customers']?['delivery_route']?.toString() ?? 'ZZZ';
        final routeB = b['delivery_route']?.toString() ?? b['customers']?['delivery_route']?.toString() ?? 'ZZZ';
        return routeA.compareTo(routeB);
      });

      setState(() {
        _allDeliveries = validDeliveries;
        _availableRoutes = routesSet.toList()..sort();
        if (!_availableRoutes.contains(_selectedRoute)) {
          _selectedRoute = 'All Routes';
        }
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error loading deliveries: $e')));
    }
  }

  void _confirmLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Log out?', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: Text(
          'You will need to sign in again to access the delivery dashboard.',
          style: GoogleFonts.manrope(fontSize: 14, color: AppTheme.onSurfaceVariant),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () async {
              Navigator.pop(ctx);
              final navigator = Navigator.of(context);
              await _service.signOut();
              navigator.pushReplacementNamed(AppRoutes.loginScreen);
            },
            child: Text('Log out', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> get _filteredDeliveries {
    var list = _allDeliveries.toList();

    // Route filter
    if (_selectedRoute != 'All Routes') {
      list = list.where((order) {
        final routeName = order['delivery_route']?.toString() ??
            order['customers']?['delivery_route']?.toString() ??
            'Unassigned';
        return routeName == _selectedRoute;
      }).toList();
    }

    // Search filter
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((order) {
        final name = (order['customer_name'] ?? '').toString().toLowerCase();
        final id = (order['id'] ?? '').toString().toLowerCase();
        final route = (order['delivery_route'] ?? order['customers']?['delivery_route'] ?? '').toString().toLowerCase();
        return name.contains(q) || id.contains(q) || route.contains(q);
      }).toList();
    }

    // Sort alphabetically by customer name
    list.sort((a, b) {
      final nameA = (a['customer_name'] ?? '').toString().toLowerCase();
      final nameB = (b['customer_name'] ?? '').toString().toLowerCase();
      return nameA.compareTo(nameB);
    });

    return list;
  }

  Future<void> _updateStatus(String orderId, String newStatus) async {
    await LoadingHelper.withLoading(
      context: context,
      errorMessage: 'Could not update order status.',
      task: () async {
        await _service.updateOrderStatus(orderId, newStatus);
        await _loadDeliveries();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Order marked as $newStatus'), backgroundColor: AppTheme.success),
          );
        }
      },
    );
  }

  // --- THE NEW ONE-SWIPE WORKFLOW ---
  Future<void> _handleDeliveryComplete(
      Map<String, dynamic> order,
      GlobalKey<_SwipeToCompleteSliderState> sliderKey,
      ) async {
    final orderId = order['id'] as String;

    // 1. Swipe immediately opens the camera with compression settings
    final picker = ImagePicker();
    final XFile? photo = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 50,
      maxWidth: 1200,
      maxHeight: 1200,
      preferredCameraDevice: CameraDevice.rear,
    );

    // 2. If user cancels camera (hits back), reset slider and abort
    if (photo == null) {
      sliderKey.currentState?.reset();
      return;
    }

    if (!mounted) return;

    // 3. Show success state on the card (green checkmark) for 2 seconds, then remove
    setState(() => _completedOrderIds.add(orderId));

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Delivery confirmed! Bill processing in background.'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );

    // Remove the card after 2 seconds
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _completedOrderIds.remove(orderId);
          _allDeliveries.removeWhere((delivery) => delivery['id'] == orderId);
        });
      }
    });

    // 4. FIRE-AND-FORGET: Run background pipeline without awaiting
    _processDeliveryInBackground(orderId, photo.path);
  }

  /// TRUE FIRE-AND-FORGET: Runs completely independently
  Future<void> _processDeliveryInBackground(String orderId, String imagePath) async {
    try {
      // FIX: Removed the void assignment error.
      await _service.updateOrderStatus(orderId, 'Pending Verification');

      // The pipeline handles Google Drive upload and OCR silently
      await _service.processDeliveryBillWithBackgroundPipeline(
        orderId: orderId,
        imagePath: imagePath,
        extractedBillNo: null,
        extractedAmount: null,
      );
    } catch (e, stackTrace) {
      // Silently log to error table - NEVER show UI errors to delivery rep
      await _logBackgroundProcessingError(orderId, e.toString(), stackTrace.toString());
    }
  }

  /// Log background processing errors safely to Supabase
  Future<void> _logBackgroundProcessingError(String orderId, String errorMessage, [String? stackTrace]) async {
    // Tag the error type so admin tab color coding works correctly
    String errorType = 'background_processing';
    final msg = errorMessage.toLowerCase();
    if (msg.contains('drive') || msg.contains('upload')) {
      errorType = 'drive_upload';
    } else if (msg.contains('ocr') || msg.contains('gemini') || msg.contains('invoice')) {
      errorType = 'ocr_processing';
    }

    try {
      await SupabaseService.instance.client.from('app_error_logs').insert({
        'order_id': orderId,
        'team_id': AuthService.currentTeam,
        'error_type': errorType,
        'error_message': errorMessage,
        'stack_trace': stackTrace,
        'resolved': false,
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (logError) {
      debugPrint('Critical: Failed to log background processing error: $logError');
      debugPrint('Original error: $errorMessage');
    }
  }

  // --- Quick Actions ---
  String? _extractPhoneNumber(Map<String, dynamic> order) {
    return order['phone']?.toString() ??
        order['customers']?['phone']?.toString() ??
        order['customer_phone']?.toString();
  }

  Future<void> _makePhoneCall(String? phoneNumber) async {
    if (phoneNumber == null || phoneNumber.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No phone number available.')));
      return;
    }
    final cleanNumber = phoneNumber.replaceAll(RegExp(r'[^0-9+]'), '');
    final Uri launchUri = Uri(scheme: 'tel', path: cleanNumber);
    try {
      if (await canLaunchUrl(launchUri)) await launchUrl(launchUri);
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  Future<void> _openWhatsApp(String? phoneNumber, String customerName) async {
    if (phoneNumber == null || phoneNumber.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No phone number available.')));
      return;
    }
    String cleanNumber = phoneNumber.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleanNumber.length == 10) cleanNumber = '91$cleanNumber';

    final message = "Hello $customerName, I am out for your delivery from Madhav & Jagannath Associates.";
    final whatsappUrl = Uri.parse("whatsapp://send?phone=$cleanNumber&text=${Uri.encodeComponent(message)}");

    try {
      if (await canLaunchUrl(whatsappUrl)) {
        await launchUrl(whatsappUrl);
      } else {
        await launchUrl(Uri.parse("https://wa.me/$cleanNumber?text=${Uri.encodeComponent(message)}"), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Widget _actionIcon(IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }

  void _markReturned(String orderId, String customerName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Mark as Returned?', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: Text(
          'Order for $customerName will be marked as returned.',
          style: GoogleFonts.manrope(fontSize: 14, color: AppTheme.onSurfaceVariant),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await _service.updateOrderStatus(orderId, 'Returned', isSuperAdmin: true);
                if (mounted) {
                  setState(() => _allDeliveries.removeWhere((d) => d['id'] == orderId));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Order marked as Returned'), backgroundColor: Colors.orange),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
                  );
                }
              }
            },
            child: Text('Returned', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Future<void> _openGoogleMaps(String address, String customerName) async {
    if (address.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No address available for this customer.')));
      return;
    }
    final query = Uri.encodeComponent('$address $customerName');
    final mapsUrl = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$query');
    try {
      await launchUrl(mapsUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open maps: $e')));
      }
    }
  }

  void _showTripManifest() {
    final list = _filteredDeliveries;
    final int orderCount = list.length;
    final double totalValue = list.fold(0.0, (sum, order) => sum + ((order['grand_total'] as num?)?.toDouble() ?? 0.0));

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.inventory_2_rounded, color: AppTheme.primary, size: 28),
                const SizedBox(width: 12),
                Text('Trip Manifest', style: GoogleFonts.manrope(fontSize: 22, fontWeight: FontWeight.w900)),
              ],
            ),
            const SizedBox(height: 8),
            Text('Route: $_selectedRoute', style: GoogleFonts.manrope(color: AppTheme.onSurfaceVariant, fontWeight: FontWeight.bold)),
            const Divider(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total Deliveries:', style: GoogleFonts.manrope(fontSize: 16)),
                Text('$orderCount', style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Route Value (Approx):', style: GoogleFonts.manrope(fontSize: 16)),
                Text('₹${totalValue.toStringAsFixed(2)}', style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w900, color: AppTheme.primary)),
              ],
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => Navigator.pop(context),
                child: Text('Close Manifest', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
              ),
            )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userName = AuthService.currentUserName;
    final hour = DateTime.now().hour;
    final greeting = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        elevation: 0,
        titleSpacing: 16,
        title: Row(
          children: [
            HeroAvatarWidget(radius: 18, imageUrl: _heroImageUrl, initials: _userInitials),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$greeting,', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant, fontWeight: FontWeight.w500)),
                  Text(userName, style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800, color: AppTheme.onSurface)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded, color: AppTheme.primary, size: 24), onPressed: _loadDeliveries, tooltip: 'Refresh'),
          IconButton(
            icon: const Icon(Icons.logout_rounded, size: 22, color: AppTheme.error),
            tooltip: 'Log out',
            onPressed: () => _confirmLogout(context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadDeliveries,
        color: AppTheme.primary,
        child: Column(
        children: [
          // ─── Route Filter Bar ───
          if (!_isLoading && _availableRoutes.length > 1)
            Container(
              height: 48,
              decoration: BoxDecoration(color: AppTheme.surface, border: Border(bottom: BorderSide(color: AppTheme.outlineVariant))),
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                itemCount: _availableRoutes.length,
                itemBuilder: (context, index) {
                  final route = _availableRoutes[index];
                  final isSelected = route == _selectedRoute;
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(route, style: GoogleFonts.manrope(fontSize: 11)),
                      selected: isSelected,
                      onSelected: (selected) {
                        if (selected) setState(() => _selectedRoute = route);
                      },
                      selectedColor: AppTheme.primary,
                      backgroundColor: AppTheme.surface,
                      labelStyle: GoogleFonts.manrope(
                        fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                        fontSize: 11,
                        color: isSelected ? Colors.white : AppTheme.onSurfaceVariant,
                      ),
                      visualDensity: VisualDensity.compact,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: isSelected ? AppTheme.primary : AppTheme.outlineVariant)),
                    ),
                  );
                },
              ),
            ),

          // ─── Search Bar ───
          if (!_isLoading)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                controller: _searchController,
                onChanged: (v) => setState(() => _searchQuery = v),
                style: GoogleFonts.manrope(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search customer, order ID, route...',
                  hintStyle: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant),
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(icon: const Icon(Icons.clear_rounded, size: 18), onPressed: () { _searchController.clear(); setState(() => _searchQuery = ''); })
                      : null,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  filled: true,
                  fillColor: AppTheme.surface,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppTheme.outlineVariant)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppTheme.outlineVariant)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primary)),
                ),
              ),
            ),

          // ─── Count badge ───
          if (!_isLoading)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(children: [
                Text('${_filteredDeliveries.length} deliveries', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.onSurfaceVariant)),
                const Spacer(),
                Text('A → Z', style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant)),
              ]),
            ),

          // ─── Deliveries List ───
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredDeliveries.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
              itemCount: _filteredDeliveries.length,
              itemBuilder: (context, index) => _buildDeliveryCard(_filteredDeliveries[index]),
            ),
          ),
        ],
      ),
      ),
      floatingActionButton: _filteredDeliveries.isNotEmpty
          ? FloatingActionButton.extended(
        onPressed: _showTripManifest,
        backgroundColor: AppTheme.secondary,
        icon: const Icon(Icons.assignment_rounded, color: Colors.white),
        label: Text('Trip Manifest', style: GoogleFonts.manrope(fontWeight: FontWeight.w800, color: Colors.white)),
      )
          : null,
    );
  }

  Widget _buildMetricsRow() {
    final list = _filteredDeliveries;
    final double totalValue = list.fold(0.0, (sum, order) => sum + ((order['grand_total'] as num?)?.toDouble() ?? 0.0));
    final int itemCount = list.fold(0, (sum, order) => sum + ((order['item_count'] as num?)?.toInt() ?? 0));

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        children: [
          Expanded(child: _MetricCard(title: 'Pending', value: '${list.length}', subtitle: 'Stops remaining', icon: Icons.storefront_rounded)),
          const SizedBox(width: 12),
          Expanded(child: _MetricCard(title: 'Est. Value', value: '₹${(totalValue / 1000).toStringAsFixed(1)}k', subtitle: '$itemCount total items', icon: Icons.account_balance_wallet_rounded, isPrimary: true)),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: AppTheme.success.withAlpha(20), shape: BoxShape.circle),
            child: const Icon(Icons.celebration_rounded, size: 64, color: AppTheme.success),
          ),
          const SizedBox(height: 24),
          Text('ROUTE CLEAR!', style: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.w900, color: AppTheme.onSurface)),
          Text('No pending deliveries for $_selectedRoute.', style: GoogleFonts.manrope(color: AppTheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildDeliveryCard(Map<String, dynamic> order) {
    final orderId = order['id'].toString();
    final isCompleted = _completedOrderIds.contains(orderId);
    final phoneToUse = _extractPhoneNumber(order);
    final routeName = order['delivery_route']?.toString() ?? order['customers']?['delivery_route']?.toString() ?? 'Unassigned';
    final double grandTotal = (order['grand_total'] as num?)?.toDouble() ?? 0.0;
    final int itemCount = (order['item_count'] as num?)?.toInt() ?? 0;
    final address = order['customers']?['address']?.toString() ?? '';
    final customerName = order['customer_name'] ?? 'Store';

    // ── Success overlay ──
    if (isCompleted) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.green.shade300, width: 2),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_rounded, size: 28, color: Colors.green.shade700),
            const SizedBox(width: 10),
            Flexible(child: Text('Delivered — $customerName', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.green.shade700), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Row 1: Name + Amount ──
            Row(
              children: [
                Expanded(child: Text(customerName, style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800, color: AppTheme.onSurface), maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                Text('\u20B9${grandTotal.toStringAsFixed(0)}', style: GoogleFonts.manrope(fontWeight: FontWeight.w800, color: AppTheme.primary, fontSize: 14)),
              ],
            ),
            const SizedBox(height: 4),
            // ── Row 2: Route + Items ──
            Row(
              children: [
                Icon(Icons.route_rounded, size: 12, color: AppTheme.secondary),
                const SizedBox(width: 3),
                Flexible(child: Text(routeName, style: GoogleFonts.manrope(color: AppTheme.secondary, fontWeight: FontWeight.w700, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 10),
                Text('$itemCount items', style: GoogleFonts.manrope(color: AppTheme.onSurfaceVariant, fontSize: 11)),
                if (address.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  Icon(Icons.location_on_rounded, size: 12, color: AppTheme.onSurfaceVariant),
                  const SizedBox(width: 2),
                  Expanded(child: Text(address, style: GoogleFonts.manrope(color: AppTheme.onSurfaceVariant, fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
              ],
            ),
            const SizedBox(height: 10),
            // ── Row 3: Action buttons ──
            Row(
              children: [
                _actionIcon(Icons.wechat_rounded, Colors.green, () => _openWhatsApp(phoneToUse, customerName)),
                const SizedBox(width: 6),
                _actionIcon(Icons.phone_rounded, AppTheme.primary, () => _makePhoneCall(phoneToUse)),
                const SizedBox(width: 6),
                _actionIcon(Icons.directions_rounded, Colors.blue.shade600, () => _openGoogleMaps(address, customerName)),
                const SizedBox(width: 6),
                _actionIcon(Icons.assignment_return_rounded, Colors.orange.shade700, () => _markReturned(orderId, customerName)),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 8),
            // ── Swipe to Complete ──
            SwipeToCompleteSlider(
              key: _sliderKeys.putIfAbsent(orderId, () => GlobalKey<_SwipeToCompleteSliderState>()),
              text: 'SWIPE TO CAPTURE >>>',
              onCompleted: () => _handleDeliveryComplete(order, _sliderKeys[orderId]!),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Custom UI Components ───

class _MetricCard extends StatelessWidget {
  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final bool isPrimary;

  const _MetricCard({required this.title, required this.value, required this.subtitle, required this.icon, this.isPrimary = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isPrimary ? AppTheme.primary : AppTheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: isPrimary ? null : Border.all(color: AppTheme.outlineVariant),
        boxShadow: [if (isPrimary) BoxShadow(color: AppTheme.primary.withAlpha(50), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: isPrimary ? Colors.white.withAlpha(200) : AppTheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(title, style: GoogleFonts.manrope(color: isPrimary ? Colors.white.withAlpha(220) : AppTheme.onSurfaceVariant, fontWeight: FontWeight.w700, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          Text(value, style: GoogleFonts.manrope(color: isPrimary ? Colors.white : AppTheme.onSurface, fontWeight: FontWeight.w900, fontSize: 24)),
          Text(subtitle, style: GoogleFonts.manrope(color: isPrimary ? Colors.white.withAlpha(180) : AppTheme.onSurfaceVariant, fontWeight: FontWeight.w500, fontSize: 11)),
        ],
      ),
    );
  }
}

class SwipeToCompleteSlider extends StatefulWidget {
  final VoidCallback onCompleted;
  final String text;

  const SwipeToCompleteSlider({super.key, required this.onCompleted, this.text = 'SWIPE TO DELIVER >>>'});

  @override
  State<SwipeToCompleteSlider> createState() => _SwipeToCompleteSliderState();
}

class _SwipeToCompleteSliderState extends State<SwipeToCompleteSlider> {
  double _position = 0.0;
  bool _isCompleted = false;

  void reset() {
    setState(() {
      _position = 0.0;
      _isCompleted = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final maxDrag = constraints.maxWidth - 56;
      return Container(
        height: 52,
        decoration: BoxDecoration(
          color: _isCompleted ? AppTheme.statusAvailable : AppTheme.surface,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: _isCompleted ? AppTheme.statusAvailable : AppTheme.primary.withAlpha(50), width: 1.5),
        ),
        child: Stack(
          children: [
            Center(
              child: Text(
                _isCompleted ? 'DELIVERED!' : widget.text,
                style: GoogleFonts.manrope(fontWeight: FontWeight.w800, color: _isCompleted ? Colors.white : AppTheme.primary, letterSpacing: 1.2, fontSize: 12),
              ),
            ),
            Positioned(
              left: _position,
              top: 2,
              bottom: 2,
              child: GestureDetector(
                onHorizontalDragUpdate: (details) {
                  if (_isCompleted) return;
                  setState(() {
                    _position += details.delta.dx;
                    if (_position < 0) _position = 0;
                    if (_position > maxDrag) _position = maxDrag;
                  });
                },
                onHorizontalDragEnd: (details) {
                  if (_isCompleted) return;
                  if (_position > maxDrag * 0.75) {
                    setState(() {
                      _position = maxDrag;
                      _isCompleted = true;
                    });
                    widget.onCompleted();
                  } else {
                    setState(() => _position = 0.0);
                  }
                },
                child: Container(
                  width: 46,
                  decoration: BoxDecoration(color: _isCompleted ? Colors.white : AppTheme.primary, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black.withAlpha(20), blurRadius: 4)]),
                  child: Icon(Icons.local_shipping_rounded, color: _isCompleted ? AppTheme.statusAvailable : Colors.white, size: 22),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}