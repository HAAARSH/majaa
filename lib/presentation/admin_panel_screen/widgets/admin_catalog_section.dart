import 'package:flutter/material.dart';
import 'admin_section_wrapper.dart';
import 'admin_products_tab.dart';
import 'admin_brand_access_tab.dart';
import 'admin_pricing_tab.dart';
import 'team_split_wrapper.dart';

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
        const AdminSectionItem(
          label: 'Pricing',
          icon: Icons.discount_rounded,
          child: AdminPricingTab(),
        ),
      ],
    );
  }
}
