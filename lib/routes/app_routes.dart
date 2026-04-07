import 'package:flutter/material.dart';

import '../services/supabase_service.dart';

// Import all your screens
import '../presentation/login_screen/login_screen.dart';
import '../presentation/beat_selection_screen/beat_selection_screen.dart';
import '../presentation/customer_list_screen/customer_list_screen.dart';
import '../presentation/products_screen/products_screen.dart';
import '../presentation/order_creation_screen/order_creation_screen.dart';
import '../presentation/admin_panel_screen/admin_panel_screen.dart';
import '../presentation/dashboard_screen/dashboard_screen.dart';
import '../presentation/customer_detail_screen/customer_detail_screen.dart';
import '../presentation/products_screen/product_detail_screen.dart';

// Your Delivery Dashboard import
import '../presentation/delivery_screen/delivery_dashboard_screen.dart';

class AppRoutes {
  // Define route names
  static const String initial = '/';
  static const String loginScreen = '/login';
  static const String beatSelectionScreen = '/beat_selection';
  static const String customerListScreen = '/customer_list_screen';
  static const String productsScreen = '/products_screen';
  static const String productDetailScreen = '/product_detail';
  static const String orderCreationScreen = '/order_creation_screen';
  static const String adminPanelScreen = '/admin_panel';
  static const String customerDetailScreen = '/customer_detail';
  static const String dashboardScreen = '/dashboard';
  static const String deliveryDashboardScreen = '/delivery_dashboard';
  static const String customerDetails = '/customer-details';

  static Map<String, WidgetBuilder> get routes => {
    initial: (context) => const LoginScreen(),
    loginScreen: (context) => const LoginScreen(),
    beatSelectionScreen: (context) => const BeatSelectionScreen(),
    customerListScreen: (context) => const CustomerListScreen(),
    productsScreen: (context) => const ProductsScreen(),
    productDetailScreen: (context) => const ProductDetailScreen(),
    orderCreationScreen: (context) => const OrderCreationScreen(),
    adminPanelScreen: (context) => const _AdminGuard(),
    dashboardScreen: (context) => const DashboardScreen(),
    customerDetailScreen: (context) => const CustomerDetailScreen(),
    deliveryDashboardScreen: (context) => const DeliveryDashboardScreen(),
    customerDetails: (context) => const CustomerDetailScreen(),
  };
}

// Route-level guard — blocks direct navigation to /admin_panel by non-admins.
// AdminPanelScreen also performs its own check in initState as a second layer.
class _AdminGuard extends StatefulWidget {
  const _AdminGuard();

  @override
  State<_AdminGuard> createState() => _AdminGuardState();
}

class _AdminGuardState extends State<_AdminGuard> {
  late final Future<String?> _roleFuture;

  @override
  void initState() {
    super.initState();
    _roleFuture = SupabaseService.instance.getUserRole();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _roleFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        const allowedRoles = ['admin', 'super_admin'];
        final role = snapshot.data ?? 'sales_rep';

        if (!allowedRoles.contains(role)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Access denied. Admin privileges required.'),
                backgroundColor: Colors.red,
              ),
            );
            Navigator.pushReplacementNamed(context, AppRoutes.beatSelectionScreen);
          });
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        return const AdminPanelScreen();
      },
    );
  }
}