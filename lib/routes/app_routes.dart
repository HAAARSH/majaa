import 'package:flutter/material.dart';

// Import all your screens
import '../presentation/login_screen/login_screen.dart';
import '../presentation/beat_selection_screen/beat_selection_screen.dart';
import '../presentation/customer_list_screen/customer_list_screen.dart';
import '../presentation/products_screen/products_screen.dart';
import '../presentation/order_creation_screen/order_creation_screen.dart';
import '../presentation/admin_panel_screen/admin_panel_screen.dart';
import '../presentation/order_history_screen/order_history_screen.dart';

// 🔴 THE FIX: We added the import for your new Order Detail Screen!
import '../presentation/order_history_screen/order_detail_screen.dart';
import '../presentation/dashboard_screen/dashboard_screen.dart';
import '../presentation/customer_list_screen/customer_detail_screen.dart';
import '../presentation/products_screen/product_detail_screen.dart';

class AppRoutes {
  // Define route names
  static const String initial = '/';
  static const String loginScreen = '/login';
  static const String beatSelectionScreen = '/beat_selection';
  static const String customerListScreen = '/customer_list_screen';
  static const String productsScreen = '/products_screen';
  static const String productDetailScreen = '/product_detail';
  static const String orderCreationScreen = '/order_creation_screen';

  static const String orderHistoryScreen = '/order_history_screen';
  static const String adminPanelScreen = '/admin_panel';
  static const String customerDetailScreen = '/customer_detail';

  // Define the new route name
  static const String orderDetailScreen = '/order_detail';
  static const String dashboardScreen = '/dashboard';

  // 🔴 THE FIX: Everything is neatly inside ONE single map now!
  static Map<String, WidgetBuilder> get routes => {
        initial: (context) => const LoginScreen(),
        loginScreen: (context) => const LoginScreen(),
        beatSelectionScreen: (context) => const BeatSelectionScreen(),
        customerListScreen: (context) => const CustomerListScreen(),
        productsScreen: (context) => const ProductsScreen(),
        productDetailScreen: (context) => const ProductDetailScreen(),
        orderCreationScreen: (context) => const OrderCreationScreen(),
        adminPanelScreen: (context) => const AdminPanelScreen(),
        orderHistoryScreen: (context) => const OrderHistoryScreen(),

        // Your new Order Detail Screen is securely mapped
        orderDetailScreen: (context) => const OrderDetailScreen(),
        dashboardScreen: (context) => const DashboardScreen(),
        customerDetailScreen: (context) => const CustomerDetailScreen(),
      };
}
