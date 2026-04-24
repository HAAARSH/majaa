import 'package:flutter/material.dart';
import '../admin_panel_screen/widgets/admin_section_wrapper.dart';
import 'widgets/alias_manager_tab.dart';
import 'widgets/manual_order_tab.dart';
import 'widgets/smart_import_tab.dart';

/// Admin "New Order" — top-level section in the admin panel.
///
/// Two sub-tabs:
///   * Manual       — admin builds the order by hand (team / beat / customer /
///                    rep attribution / cart / price overrides).
///   * Smart Import — admin pastes text / uploads image-PDF, Gemini parses it
///                    into a draft order (Phase 2+, placeholder for now).
///
/// Both paths save with `source = 'office'` and attribute the order to the
/// picked rep (NOT the admin) via the overrideUserId param on createOrder.
class AdminNewOrderSection extends StatelessWidget {
  final bool isSuperAdmin;

  const AdminNewOrderSection({super.key, required this.isSuperAdmin});

  @override
  Widget build(BuildContext context) {
    return AdminSectionWrapper(
      items: [
        AdminSectionItem(
          label: 'Manual',
          icon: Icons.edit_rounded,
          child: ManualOrderTab(isSuperAdmin: isSuperAdmin),
        ),
        AdminSectionItem(
          label: 'Smart Import',
          icon: Icons.auto_awesome_rounded,
          child: SmartImportTab(isSuperAdmin: isSuperAdmin),
        ),
        const AdminSectionItem(
          label: 'Aliases',
          icon: Icons.translate_rounded,
          child: AliasManagerTab(),
        ),
      ],
    );
  }
}
