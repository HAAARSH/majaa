// All errors cascade from unresolved package URIs; the import statements are already syntactically correct and no code changes are needed in the Dart file itself - the resolution requires ensuring flutter and google_fonts packages are listed in pubspec.yaml. //

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';

class OrderHistoryScreen extends StatefulWidget {
  const OrderHistoryScreen({super.key});

  @override
  State<OrderHistoryScreen> createState() => _OrderHistoryScreenState();
}

class _OrderHistoryScreenState extends State<OrderHistoryScreen> {
  bool _isLoading = true;
  bool _isInitialized = false;
  String? _error;
  List<OrderModel> _orders = [];
  List<OrderModel> _filteredOrders = [];
  String? _contextBeatName;
  final TextEditingController _searchController = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      final args =
          ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
      _contextBeatName = args?['beat_name'] as String?;
      _loadOrders();
      _isInitialized = true;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadOrders() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      // Fetches orders filtered by Current User, Current Month, and (if applicable) Current Beat
      final orders = await SupabaseService.instance
          .getContextualOrders(beatName: _contextBeatName);
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _filteredOrders = orders;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _filterOrders(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredOrders = _orders;
      } else {
        _filteredOrders = _orders.where((order) {
          final customerName = order.customerName.toLowerCase();
          final orderId = order.id.toLowerCase();
          final searchLower = query.toLowerCase();
          return customerName.contains(searchLower) ||
              orderId.contains(searchLower);
        }).toList();
      }
    });
  }

  String _formatDate(DateTime date) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final titleText = _contextBeatName != null
        ? '$_contextBeatName Orders'
        : 'My Monthly Sales';

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          color: AppTheme.onSurface,
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          children: [
            Text(titleText,
                style: GoogleFonts.manrope(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.onSurface)),
            Text('Current Month',
                style: GoogleFonts.manrope(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.primary)),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!_isLoading && _error == null && _orders.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: TextField(
                  controller: _searchController,
                  onChanged: _filterOrders,
                  decoration: InputDecoration(
                    hintText: 'Search by Customer or Order ID',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: () {
                              _searchController.clear();
                              _filterOrders('');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.outlineVariant),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.outlineVariant),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Text('Error: $_error',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.red)),
                        ))
                      : _filteredOrders.isEmpty
                          ? Center(
                              child: Text(
                                  _searchController.text.isEmpty
                                      ? 'No orders found for this period.'
                                      : 'No orders match your search.',
                                  style: GoogleFonts.manrope(
                                      color: AppTheme.onSurfaceVariant)))
                          : RefreshIndicator(
                              onRefresh: _loadOrders,
                              child: ListView.builder(
                                padding: const EdgeInsets.all(16),
                                itemCount: _filteredOrders.length,
                                itemBuilder: (context, index) {
                                  final order = _filteredOrders[index];
                                  return Card(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16),
                                        side: BorderSide(
                                            color: AppTheme.outlineVariant)),
                                    child: ListTile(
                                      contentPadding: const EdgeInsets.all(16),
                                      onTap: () => Navigator.pushNamed(
                                          context, AppRoutes.orderDetailScreen,
                                          arguments: {'order': order}),
                                      title: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(order.id,
                                              style: GoogleFonts.manrope(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w800,
                                                  color: AppTheme.primary)),
                                          Text(
                                              '₹${order.grandTotal.toStringAsFixed(2)}',
                                              style: GoogleFonts.manrope(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w800)),
                                        ],
                                      ),
                                      subtitle: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const SizedBox(height: 8),
                                          Text(order.customerName,
                                              style: GoogleFonts.manrope(
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w700,
                                                  color: AppTheme.onSurface)),
                                          const SizedBox(height: 4),
                                          Text(
                                              '${_formatDate(order.orderDate)} • ${order.itemCount} items',
                                              style: GoogleFonts.manrope(
                                                  fontSize: 12)),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }
}
