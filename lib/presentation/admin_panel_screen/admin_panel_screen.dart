import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';

import './widgets/admin_dashboard_tab.dart';
import './widgets/admin_catalog_section.dart';
import './widgets/admin_field_ops_section.dart';
import './widgets/admin_orders_section.dart';
import './widgets/admin_system_section.dart';
import './widgets/team_split_wrapper.dart';
import '../../services/drive_sync_service.dart';
import '../../widgets/hero_selfie_modal.dart';

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  StreamSubscription? _orderSubscription;
  bool _isSuperAdmin = false;
  bool _isCheckingRole = true;
  final Set<String> _notifiedOrderIds = {};
  bool _streamInitialized = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _checkRoleAndInit();
  }

  Future<void> _checkRoleAndInit() async {
    try {
      final user = SupabaseService.instance.client.auth.currentUser;
      if (user == null) {
        _redirectUnauthorized();
        return;
      }

      final role = await SupabaseService.instance.getUserRole();
      const allowedRoles = ['admin', 'super_admin'];

      if (!allowedRoles.contains(role)) {
        _redirectUnauthorized();
        return;
      }

      if (mounted) {
        setState(() {
          _isSuperAdmin = role == 'super_admin';
          _isCheckingRole = false;
        });
        _setupOrderListener();
        // Auto-sync bill photos to Google Drive on admin login
        DriveSyncService.instance.syncAll();
        // Check if admin needs selfie
        _checkHeroSelfie();
      }
    } catch (e) {
      debugPrint('Error checking admin role: $e');
      _redirectUnauthorized();
    }
  }

  Future<void> _checkHeroSelfie() async {
    try {
      final user = await SupabaseService.instance.getCurrentUser();
      if (user != null && (user.heroImageUrl == null || user.heroImageUrl!.isEmpty) && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => HeroSelfieModal(
              userId: user.id,
              fullName: user.fullName,
              onSuccess: () => Navigator.pop(context),
            ),
          );
        });
      }
    } catch (e) {
      debugPrint('Hero selfie check error: $e');
    }
  }

  void _redirectUnauthorized() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Access denied. Admin privileges required.'),
          backgroundColor: Colors.red,
        ),
      );
      Navigator.pushReplacementNamed(context, AppRoutes.beatSelectionScreen);
    });
  }

  void _setupOrderListener() {
    _streamInitialized = false;
    _orderSubscription =
        SupabaseService.instance.getOrdersStream().listen((dynamic streamData) {
          final List<Map<String, dynamic>> rawOrders = List<Map<String, dynamic>>.from(streamData);

          // Skip the first emission — it's the initial snapshot, not a new order
          if (!_streamInitialized) {
            _streamInitialized = true;
            // Seed known IDs so we don't notify for existing orders
            for (final raw in rawOrders) {
              final id = raw['id']?.toString();
              if (id != null) _notifiedOrderIds.add(id);
            }
            return;
          }

          if (rawOrders.isNotEmpty) {
            final latestOrder = OrderModel.fromJson(rawOrders.first);
            if (!_notifiedOrderIds.contains(latestOrder.id)) {
              _notifiedOrderIds.add(latestOrder.id);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('🔔 New order received from ${latestOrder.customerName}!'),
                      backgroundColor: AppTheme.success,
                      duration: const Duration(seconds: 4),
                    )
                );
              }
            }
          }
        });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _orderSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isCheckingRole) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.primary,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Admin Control Panel',
              style: GoogleFonts.manrope(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white),
            ),
            if (_isSuperAdmin)
              Text(
                  'Super Admin Mode',
                  style: TextStyle(fontSize: 10, color: Colors.amber.shade300, fontWeight: FontWeight.bold)
              ),
          ],
        ),
        // CHANGED: removed global team switcher — each split tab has its own JA/MA toggle
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: Colors.white),
            tooltip: 'Log Out',
            onPressed: () async {
              final navigator = Navigator.of(context);
              await SupabaseService.instance.signOut();
              navigator.pushReplacementNamed(AppRoutes.loginScreen);
            },
          )
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: Colors.white,
          indicatorWeight: 4,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          labelStyle: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 13),
          tabs: const [
            Tab(icon: Icon(Icons.dashboard_rounded), text: 'Dashboard'),
            Tab(icon: Icon(Icons.inventory_2_rounded), text: 'Catalog'),
            Tab(icon: Icon(Icons.groups_rounded), text: 'Field Ops'),
            Tab(icon: Icon(Icons.receipt_long_rounded), text: 'Orders'),
            Tab(icon: Icon(Icons.admin_panel_settings_rounded), text: 'System'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          TeamSplitWrapper(builder: (team) => AdminDashboardTab(key: ValueKey('dash_$team'))),
          AdminCatalogSection(isSuperAdmin: _isSuperAdmin),
          AdminFieldOpsSection(isSuperAdmin: _isSuperAdmin),
          const AdminOrdersSection(),
          AdminSystemSection(isSuperAdmin: _isSuperAdmin),
        ],
      ),
    );
  }
}