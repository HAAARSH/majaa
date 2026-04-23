import 'package:flutter/material.dart';
import 'admin_section_wrapper.dart';
import 'admin_orders_tab.dart';
import 'admin_beat_orders_tab.dart';
import 'admin_bill_verification_tab.dart';
import 'admin_recent_exports_tab.dart';

class AdminOrdersSection extends StatelessWidget {
  const AdminOrdersSection({super.key});

  @override
  Widget build(BuildContext context) {
    return const AdminSectionWrapper(
      items: [
        AdminSectionItem(
          label: 'Bill Verify',
          icon: Icons.fact_check_rounded,
          child: AdminBillVerificationTab(),
        ),
        AdminSectionItem(
          label: 'Orders',
          icon: Icons.receipt_long_rounded,
          child: AdminOrdersTab(),
        ),
        AdminSectionItem(
          label: 'Beat Orders',
          icon: Icons.map_rounded,
          child: AdminBeatOrdersTab(),
        ),
        AdminSectionItem(
          label: 'Recent Exports',
          icon: Icons.history_rounded,
          child: AdminRecentExportsTab(),
        ),
      ],
    );
  }
}
