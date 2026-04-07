import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';
import './widgets/admin_beats_tab.dart';
import './widgets/admin_customers_tab.dart';
import './widgets/admin_dashboard_tab.dart';
import './widgets/admin_orders_tab.dart';
import './widgets/admin_products_tab.dart';
import './widgets/admin_settings_tab.dart';
import './widgets/admin_user_beats_tab.dart';

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  AppUserModel? _currentUser;
  StreamSubscription? _orderSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    _setupOrderListener();
  }

  void _setupOrderListener() {
    _orderSubscription =
        SupabaseService.instance.getOrdersStream().listen((orders) {
      if (orders.isNotEmpty) {
        final latestOrder = orders.first;
        final orderTime = DateTime.parse(latestOrder.orderDate);
        if (DateTime.now().difference(orderTime).inSeconds < 10) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.shopping_cart_checkout_rounded,
                        color: Colors.white),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'New Order from ${latestOrder.customerName}!',
                        style: GoogleFonts.manrope(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                backgroundColor: AppTheme.primary,
                behavior: SnackBarBehavior.floating,
                action: SnackBarAction(
                  label: 'VIEW',
                  textColor: Colors.white,
                  onPressed: () => _tabController.animateTo(5), // Orders tab
                ),
              ),
            );
          }
        }
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map<String, dynamic> && args['user'] is AppUserModel) {
      _currentUser = args['user'] as AppUserModel;
    }
    // Route guard: redirect non-admin users back to login
    if (_currentUser != null && _currentUser!.role != 'admin') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushNamedAndRemoveUntil(
            context, AppRoutes.loginScreen, (route) => false);
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _orderSubscription?.cancel();
    super.dispose();
  }

  void _logout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Logout',
          style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Are you sure you want to logout?',
          style: GoogleFonts.manrope(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.manrope()),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () {
              // Clear session data on logout
              SupabaseService.instance.isOfflineMode = false;
              SupabaseService.instance.currentUserId = null;
              Navigator.pop(ctx);
              Navigator.pushNamedAndRemoveUntil(
                context,
                AppRoutes.loginScreen,
                (route) => false,
              );
            },
            child: Text('Logout', style: GoogleFonts.manrope()),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Admin Panel',
              style: GoogleFonts.manrope(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            if (_currentUser != null)
              Text(
                _currentUser!.fullName.isNotEmpty
                    ? _currentUser!.fullName
                    : _currentUser!.email,
                style: GoogleFonts.manrope(fontSize: 11, color: Colors.white70),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: Colors.white),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          labelStyle: GoogleFonts.manrope(
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelStyle: GoogleFonts.manrope(
            fontSize: 11,
            fontWeight: FontWeight.w400,
          ),
          isScrollable: true,
          tabs: const [
            Tab(
              icon: Icon(Icons.dashboard_rounded, size: 18),
              text: 'Dashboard',
            ),
            Tab(
              icon: Icon(Icons.inventory_2_rounded, size: 18),
              text: 'Products',
            ),
            Tab(icon: Icon(Icons.people_rounded, size: 18), text: 'Customers'),
            Tab(icon: Icon(Icons.route_rounded, size: 18), text: 'Beats'),
            Tab(
              icon: Icon(Icons.person_pin_rounded, size: 18),
              text: 'User Beats',
            ),
            Tab(
              icon: Icon(Icons.receipt_long_rounded, size: 18),
              text: 'Orders',
            ),
            Tab(
              icon: Icon(Icons.settings_rounded, size: 18),
              text: 'Settings',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          AdminDashboardTab(),
          AdminProductsTab(),
          AdminCustomersTab(),
          AdminBeatsTab(),
          AdminUserBeatsTab(),
          AdminOrdersTab(),
          AdminSettingsTab(),
        ],
      ),
    );
  }
}
