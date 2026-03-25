import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../services/cart_service.dart';
import '../../services/offline_service.dart'; // ADDED THIS IMPORT
import '../../theme/app_theme.dart';

class CustomerListScreen extends StatefulWidget {
  const CustomerListScreen({super.key});

  @override
  State<CustomerListScreen> createState() => _CustomerListScreenState();
}

class _CustomerListScreenState extends State<CustomerListScreen> {
  bool _isLoading = true;
  bool _isInitialized = false;
  List<CustomerModel> _allCustomers = [];
  List<CustomerModel> _beatCustomers = [];
  BeatModel? _selectedBeat;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (!_isInitialized) {
      // Grab the beat that was passed from the Beat Selection Screen
      final args =
          ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
      if (args != null && args['beat'] != null) {
        _selectedBeat = args['beat'] as BeatModel;
      } else {
        // Fallback in case we returned from an order
        _selectedBeat = CartService.instance.currentBeat;
      }

      _loadCustomers();
      _isInitialized = true;
    }
  }

  Future<void> _loadCustomers() async {
    // 🔴 STEP 2: TRIGGER THE OFFLINE SYNC ENGINE
    // This checks for any "Saved Offline" orders and pushes them to Supabase
    // as soon as this screen is loaded (provided the user is now online).
    try {
      await OfflineService.instance.syncOfflineOrders();
    } catch (e) {
      debugPrint('Background sync failed: $e');
    }

    try {
      final customers = await SupabaseService.instance.getCustomers();
      if (!mounted) return;

      setState(() {
        _allCustomers = customers;

        // Filter the list so the rep ONLY sees customers in this specific beat
        if (_selectedBeat != null) {
          _beatCustomers = _allCustomers
              .where((c) => c.beat == _selectedBeat!.beatName)
              .toList();
        } else {
          _beatCustomers = _allCustomers;
        }

        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  void _selectCustomer(CustomerModel customer) {
    // 1. Save this customer into the active Cart session
    CartService.instance.setCustomerSession(customer, _selectedBeat);
    // 2. Navigate straight to the Products Screen
    Navigator.pushNamed(context, AppRoutes.productsScreen);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          color: AppTheme.onSurface,
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Select Customer',
                style: GoogleFonts.manrope(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.onSurface)),
            Text(_selectedBeat?.beatName ?? 'All Beats',
                style: GoogleFonts.manrope(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.primary)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history_rounded, color: AppTheme.primary),
            onPressed: () {
              Navigator.pushNamed(
                context,
                AppRoutes.orderHistoryScreen,
                arguments: {'beat_name': _selectedBeat?.beatName},
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: AppTheme.error),
            onPressed: () {
              Navigator.pushNamedAndRemoveUntil(
                  context, AppRoutes.loginScreen, (route) => false);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _beatCustomers.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.store_mall_directory_rounded,
                            size: 64,
                            color: AppTheme.onSurfaceVariant.withAlpha(100)),
                        const SizedBox(height: 16),
                        Text(
                          'No customers found in this area.',
                          style: GoogleFonts.manrope(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _beatCustomers.length,
                    itemBuilder: (context, index) {
                      final customer = _beatCustomers[index];

                      return Card(
                        elevation: 0,
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: AppTheme.outlineVariant),
                        ),
                        color: AppTheme.surface,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          leading: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryContainer,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.storefront_rounded,
                                color: AppTheme.primary, size: 20),
                          ),
                          title: Text(customer.name,
                              style: GoogleFonts.manrope(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.onSurface)),
                          subtitle: Text(customer.address,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.manrope(
                                  fontSize: 12,
                                  color: AppTheme.onSurfaceVariant)),
                          trailing: const Icon(Icons.chevron_right_rounded,
                              color: AppTheme.outlineVariant),
                          onTap: () => _selectCustomer(customer),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
