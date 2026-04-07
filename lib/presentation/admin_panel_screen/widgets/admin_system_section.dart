import 'package:flutter/material.dart';
import 'admin_section_wrapper.dart';
import 'admin_users_tab.dart';
import 'admin_error_management_tab.dart';
import 'admin_settings_tab.dart';

class AdminSystemSection extends StatelessWidget {
  final bool isSuperAdmin;

  const AdminSystemSection({super.key, this.isSuperAdmin = false});

  @override
  Widget build(BuildContext context) {
    return AdminSectionWrapper(
      items: [
        const AdminSectionItem(
          label: 'Errors',
          icon: Icons.error_outline_rounded,
          child: AdminErrorManagementTab(),
        ),
        AdminSectionItem(
          label: 'Settings',
          icon: Icons.settings_rounded,
          child: AdminSettingsTab(isSuperAdmin: isSuperAdmin),
        ),
        const AdminSectionItem(
          label: 'Users',
          icon: Icons.people_alt_rounded,
          child: AdminUsersTab(),
        ),
      ],
    );
  }
}
