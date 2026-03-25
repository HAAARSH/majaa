import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/app_routes.dart';
import '../../theme/app_theme.dart';

// The file's Dart code is correct. All errors cascade from the Flutter/google_fonts
// packages not being resolved, which requires running 'flutter pub get' and ensuring
// pubspec.yaml includes flutter sdk and google_fonts dependencies, not a code change.

class Customer {
  final String id;
  final String name;
  final String phone;
  final String address;
  final String type;
  final String beat;
  final DateTime lastOrderDate;
  final double lastOrderValue;

  const Customer({
    required this.id,
    required this.name,
    required this.phone,
    required this.address,
    required this.type,
    required this.beat,
    required this.lastOrderDate,
    required this.lastOrderValue,
  });
}

class OrderLineItem {
  final String productName;
  final String sku;
  final int quantity;
  final double mrp;
  final double lineTotal;

  const OrderLineItem({
    required this.productName,
    required this.sku,
    required this.quantity,
    required this.mrp,
    required this.lineTotal,
  });
}

class OrderHistoryItem {
  final String orderId;
  final String status;
  final DateTime orderDate;
  final int itemCount;
  final double total;
  final String? notes;
  final List<OrderLineItem> lineItems;

  const OrderHistoryItem({
    required this.orderId,
    required this.status,
    required this.orderDate,
    required this.itemCount,
    required this.total,
    this.notes,
    required this.lineItems,
  });
}

class CustomerDetailScreen extends StatefulWidget {
  const CustomerDetailScreen({super.key});

  @override
  State<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends State<CustomerDetailScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  Customer? _customer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _customer = ModalRoute.of(context)?.settings.arguments as Customer?;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // Filter mock orders for this customer
  List<OrderHistoryItem> get _customerOrders {
    if (_customer == null) return [];
    return <OrderHistoryItem>[];
  }

  String _formatDate(DateTime dt) {
    const months = [
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
      'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  Color get _typeColor {
    switch (_customer?.type) {
      case 'Supermarket':
        return AppTheme.primary;
      case 'Wholesale':
        return const Color(0xFF7B3FA0);
      case 'Convenience':
        return AppTheme.secondary;
      default:
        return AppTheme.warning;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_customer == null) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        body: const Center(child: Text('Customer not found')),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── AppBar ──────────────────────────────────────────────────
            Container(
              color: AppTheme.surface,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            size: 20,
                          ),
                          color: AppTheme.onSurface,
                          onPressed: () => Navigator.pop(context),
                        ),
                        // Avatar
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              _customer!.name.substring(0, 1).toUpperCase(),
                              style: GoogleFonts.manrope(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.primary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _customer!.name,
                                style: GoogleFonts.manrope(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.onSurface,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                _customer!.beat,
                                style: GoogleFonts.manrope(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: AppTheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _typeColor.withAlpha(20),
                            borderRadius: BorderRadius.circular(100),
                          ),
                          child: Text(
                            _customer!.type,
                            style: GoogleFonts.manrope(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: _typeColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  TabBar(
                    controller: _tabController,
                    labelColor: AppTheme.primary,
                    unselectedLabelColor: AppTheme.onSurfaceVariant,
                    indicatorColor: AppTheme.primary,
                    indicatorWeight: 2.5,
                    labelStyle: GoogleFonts.manrope(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                    unselectedLabelStyle: GoogleFonts.manrope(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    tabs: const [
                      Tab(text: 'Info'),
                      Tab(text: 'Orders'),
                    ],
                  ),
                ],
              ),
            ),

            // ── Tab Views ───────────────────────────────────────────────
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _InfoTab(customer: _customer!),
                  _OrdersTab(customer: _customer!, orders: _customerOrders),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Info Tab ─────────────────────────────────────────────────────────────────

class _InfoTab extends StatelessWidget {
  final Customer customer;

  const _InfoTab({required this.customer});

  String _formatDate(DateTime dt) {
    const months = [
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
      'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Contact Details Card ──────────────────────────────────────
          _SectionCard(
            title: 'Contact Details',
            icon: Icons.person_outline_rounded,
            children: [
              _InfoRow(
                icon: Icons.storefront_outlined,
                label: 'Store Name',
                value: customer.name,
              ),
              _InfoRow(
                icon: Icons.phone_outlined,
                label: 'Phone',
                value: customer.phone,
              ),
              _InfoRow(
                icon: Icons.location_on_outlined,
                label: 'Address',
                value: customer.address,
              ),
              _InfoRow(
                icon: Icons.category_outlined,
                label: 'Type',
                value: customer.type,
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ── Beat & Schedule Card ──────────────────────────────────────
          _SectionCard(
            title: 'Beat & Schedule',
            icon: Icons.route_outlined,
            children: [
              _InfoRow(
                icon: Icons.map_outlined,
                label: 'Beat',
                value: customer.beat,
              ),
              _InfoRow(
                icon: Icons.tag_rounded,
                label: 'Customer ID',
                value: customer.id.toUpperCase(),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ── Order Summary Card ────────────────────────────────────────
          _SectionCard(
            title: 'Order Summary',
            icon: Icons.receipt_long_outlined,
            children: [
              _InfoRow(
                icon: Icons.calendar_today_outlined,
                label: 'Last Order Date',
                value: _formatDate(customer.lastOrderDate),
              ),
              _InfoRow(
                icon: Icons.currency_rupee_rounded,
                label: 'Last Order Value',
                value: '₹${customer.lastOrderValue.toStringAsFixed(2)}',
                valueColor: AppTheme.primary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Icon(icon, size: 16, color: AppTheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: GoogleFonts.manrope(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          Divider(color: AppTheme.outlineVariant, height: 1),
          ...children,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: AppTheme.onSurfaceVariant),
          const SizedBox(width: 10),
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: GoogleFonts.manrope(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppTheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.manrope(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: valueColor ?? AppTheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Orders Tab ───────────────────────────────────────────────────────────────

class _OrdersTab extends StatelessWidget {
  final Customer customer;
  final List<OrderHistoryItem> orders;

  const _OrdersTab({required this.customer, required this.orders});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── New Order Button ──────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              onPressed: () {
                Navigator.pushNamed(
                  context,
                  AppRoutes.productsScreen,
                  arguments: {'customer': customer},
                );
              },
              icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
              label: Text(
                'New Order for ${customer.name.split(' ').first}',
                style: GoogleFonts.manrope(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.secondary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // ── Orders List ───────────────────────────────────────────────
        Expanded(
          child: orders.isEmpty
              ? _EmptyOrders(customer: customer)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: orders.length,
                  itemBuilder: (context, index) {
                    return _OrderCard(
                      order: orders[index],
                      onTap: () => _showOrderDetails(context, orders[index]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showOrderDetails(BuildContext context, OrderHistoryItem order) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _OrderDetailsSheet(order: order),
    );
  }
}

class _EmptyOrders extends StatelessWidget {
  final Customer customer;

  const _EmptyOrders({required this.customer});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.receipt_long_outlined,
            size: 56,
            color: AppTheme.onSurfaceVariant.withAlpha(100),
          ),
          const SizedBox(height: 12),
          Text(
            'No orders yet',
            style: GoogleFonts.manrope(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppTheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap "New Order" above to place the first order\nfor ${customer.name}',
            style: GoogleFonts.manrope(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: AppTheme.onSurfaceVariant,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final OrderHistoryItem order;
  final VoidCallback onTap;

  const _OrderCard({required this.order, required this.onTap});

  String _formatDate(DateTime dt) {
    const months = [
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
      'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  Color get _statusColor {
    switch (order.status) {
      case 'Delivered':
        return AppTheme.statusAvailable;
      case 'Cancelled':
        return AppTheme.error;
      default:
        return AppTheme.warning;
    }
  }

  Color get _statusBg {
    switch (order.status) {
      case 'Delivered':
        return AppTheme.statusAvailableContainer;
      case 'Cancelled':
        return AppTheme.errorContainer;
      default:
        return AppTheme.warningContainer;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(8),
                blurRadius: 5,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      order.orderId,
                      style: GoogleFonts.manrope(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primary,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _statusBg,
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Text(
                      order.status,
                      style: GoogleFonts.manrope(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _statusColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.calendar_today_outlined,
                    size: 12,
                    color: AppTheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatDate(order.orderDate),
                    style: GoogleFonts.manrope(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AppTheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Icon(
                    Icons.inventory_2_outlined,
                    size: 12,
                    color: AppTheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${order.itemCount} item${order.itemCount == 1 ? '' : 's'}',
                    style: GoogleFonts.manrope(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AppTheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '₹${order.total.toStringAsFixed(2)}',
                    style: GoogleFonts.manrope(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.onSurface,
                    ),
                  ),
                ],
              ),
              if (order.notes != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.notes_rounded,
                      size: 12,
                      color: AppTheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        order.notes!,
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: AppTheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    'View details',
                    style: GoogleFonts.manrope(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primary,
                    ),
                  ),
                  const SizedBox(width: 3),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 14,
                    color: AppTheme.primary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Order Details Bottom Sheet ───────────────────────────────────────────────

class _OrderDetailsSheet extends StatelessWidget {
  final OrderHistoryItem order;

  const _OrderDetailsSheet({required this.order});

  String _formatDate(DateTime dt) {
    const months = [
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
      'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final double subtotal = order.lineItems.fold(0, (s, i) => s + i.lineTotal);
    final double gst = subtotal * 0.18;
    final double grandTotal = subtotal + gst;

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Handle
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          order.orderId,
                          style: GoogleFonts.manrope(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.primary,
                          ),
                        ),
                        Text(
                          _formatDate(order.orderDate),
                          style: GoogleFonts.manrope(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: AppTheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                    color: AppTheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
            Divider(color: AppTheme.outlineVariant, height: 1),
            // Line items
            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  // Table header
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 4,
                          child: Text(
                            'Product',
                            style: GoogleFonts.manrope(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.primary,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 36,
                          child: Text(
                            'Qty',
                            style: GoogleFonts.manrope(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.primary,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        SizedBox(
                          width: 52,
                          child: Text(
                            'MRP',
                            style: GoogleFonts.manrope(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.primary,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        SizedBox(
                          width: 64,
                          child: Text(
                            'Total',
                            style: GoogleFonts.manrope(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.primary,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Items
                  Container(
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.outlineVariant),
                    ),
                    child: ListView.separated(
                      physics: const NeverScrollableScrollPhysics(),
                      shrinkWrap: true,
                      itemCount: order.lineItems.length,
                      separatorBuilder: (_, __) =>
                          Divider(color: AppTheme.outlineVariant, height: 1),
                      itemBuilder: (_, i) {
                        final item = order.lineItems[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 4,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.productName,
                                      style: GoogleFonts.manrope(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: AppTheme.onSurface,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      item.sku,
                                      style: GoogleFonts.manrope(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w400,
                                        color: AppTheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: 36,
                                child: Text(
                                  '${item.quantity}',
                                  style: GoogleFonts.manrope(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.onSurface,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              SizedBox(
                                width: 52,
                                child: Text(
                                  '₹${item.mrp.toStringAsFixed(2)}',
                                  style: GoogleFonts.manrope(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w400,
                                    color: AppTheme.onSurfaceVariant,
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                              SizedBox(
                                width: 64,
                                child: Text(
                                  '₹${item.lineTotal.toStringAsFixed(2)}',
                                  style: GoogleFonts.manrope(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.onSurface,
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Totals
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        _TotalRow(
                          label: 'Subtotal',
                          value: '₹${subtotal.toStringAsFixed(2)}',
                        ),
                        const SizedBox(height: 6),
                        _TotalRow(
                          label: 'GST (18%)',
                          value: '₹${gst.toStringAsFixed(2)}',
                        ),
                        Divider(
                          color: AppTheme.primary.withAlpha(40),
                          height: 16,
                        ),
                        _TotalRow(
                          label: 'Grand Total',
                          value: '₹${grandTotal.toStringAsFixed(2)}',
                          isBold: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isBold;

  const _TotalRow({
    required this.label,
    required this.value,
    this.isBold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.manrope(
              fontSize: isBold ? 14 : 12,
              fontWeight: isBold ? FontWeight.w700 : FontWeight.w500,
              color: isBold ? AppTheme.onSurface : AppTheme.onSurfaceVariant,
            ),
          ),
        ),
        Text(
          value,
          style: GoogleFonts.manrope(
            fontSize: isBold ? 15 : 12,
            fontWeight: isBold ? FontWeight.w700 : FontWeight.w500,
            color: isBold ? AppTheme.primary : AppTheme.onSurface,
          ),
        ),
      ],
    );
  }
}
