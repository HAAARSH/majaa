import 'package:flutter/material.dart';
import 'admin_section_wrapper.dart';
import 'admin_customers_tab.dart';
import 'admin_beats_tab.dart';
import 'admin_user_beats_tab.dart';
import 'admin_visits_tab.dart';
import 'team_split_wrapper.dart';

class AdminFieldOpsSection extends StatelessWidget {
  final bool isSuperAdmin;

  const AdminFieldOpsSection({super.key, this.isSuperAdmin = false});

  @override
  Widget build(BuildContext context) {
    return AdminSectionWrapper(
      items: [
        AdminSectionItem(
          label: 'Beats',
          icon: Icons.route_rounded,
          child: TeamSplitWrapper(
            builder: (team) => AdminBeatsTab(
              key: ValueKey('beats_$team'),
              isSuperAdmin: isSuperAdmin,
            ),
          ),
        ),
        const AdminSectionItem(
          label: 'Customers',
          icon: Icons.people_rounded,
          child: AdminCustomersTab(),
        ),
        AdminSectionItem(
          label: 'User Beats',
          icon: Icons.person_pin_rounded,
          child: TeamSplitWrapper(
            builder: (team) => AdminUserBeatsTab(
              key: ValueKey('usrbeats_$team'),
            ),
          ),
        ),
        AdminSectionItem(
          label: 'Visits',
          icon: Icons.location_on_rounded,
          child: TeamSplitWrapper(
            builder: (team) => AdminVisitsTab(
              key: ValueKey('visits_$team'),
            ),
          ),
        ),
      ],
    );
  }
}
