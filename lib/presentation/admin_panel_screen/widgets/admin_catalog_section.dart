import 'package:flutter/material.dart';
import 'admin_section_wrapper.dart';
import 'admin_products_tab.dart';
import 'admin_brand_access_tab.dart';
import 'team_split_wrapper.dart';

// NOTE: the dedicated "Pricing" sub-tab was removed; the CSDS toggles
// it provided are now edited via Admin Panel → System → Rules →
// Pricing category (admin_rules_tab.dart). See commit removing
// admin_pricing_tab.dart for the migration.

class AdminCatalogSection extends StatelessWidget {
  final bool isSuperAdmin;

  const AdminCatalogSection({super.key, this.isSuperAdmin = false});

  @override
  Widget build(BuildContext context) {
    return AdminSectionWrapper(
      items: [
        const AdminSectionItem(
          label: 'Brand Access',
          icon: Icons.shield_rounded,
          child: AdminBrandAccessTab(),
        ),
        AdminSectionItem(
          label: 'Products',
          icon: Icons.inventory_2_rounded,
          child: TeamSplitWrapper(
            builder: (team) => AdminProductsTab(
              key: ValueKey('prod_$team'),
              isSuperAdmin: isSuperAdmin,
            ),
          ),
        ),
      ],
    );
  }
}
