import 'package:flutter/material.dart';
import 'admin_section_wrapper.dart';
import 'admin_users_tab.dart';
import 'admin_error_management_tab.dart';
import 'admin_rules_tab.dart';
import 'admin_settings_tab.dart';
import '../../../services/drive_sync_service.dart';

class AdminSystemSection extends StatefulWidget {
  final bool isSuperAdmin;

  const AdminSystemSection({super.key, this.isSuperAdmin = false});

  @override
  State<AdminSystemSection> createState() => _AdminSystemSectionState();
}

class _AdminSystemSectionState extends State<AdminSystemSection> {
  int _initialIndex = 0;

  @override
  void initState() {
    super.initState();
    DriveSyncService.instance.authError.addListener(_onDriveAuthError);
    // If already in error state, start on Settings tab
    if (DriveSyncService.instance.authError.value != null) {
      _initialIndex = 1;
    }
  }

  void _onDriveAuthError() {
    if (DriveSyncService.instance.authError.value != null && mounted) {
      setState(() => _initialIndex = 1);
    }
  }

  @override
  void dispose() {
    DriveSyncService.instance.authError.removeListener(_onDriveAuthError);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdminSectionWrapper(
      key: ValueKey('system_$_initialIndex'),
      initialIndex: _initialIndex,
      items: [
        const AdminSectionItem(
          label: 'Errors',
          icon: Icons.error_outline_rounded,
          child: AdminErrorManagementTab(),
        ),
        AdminSectionItem(
          label: 'Settings',
          icon: Icons.settings_rounded,
          child: AdminSettingsTab(isSuperAdmin: widget.isSuperAdmin),
        ),
        AdminSectionItem(
          label: 'Rules',
          icon: Icons.rule_rounded,
          child: AdminRulesTab(isSuperAdmin: widget.isSuperAdmin),
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
