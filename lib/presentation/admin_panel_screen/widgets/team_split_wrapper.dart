import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../services/auth_service.dart';
import '../../../theme/app_theme.dart';

/// Wraps any admin tab with JA/MA sub-tabs at the top.
/// Sets AuthService.currentTeam when a sub-tab is selected and rebuilds the child.
class TeamSplitWrapper extends StatefulWidget {
  /// Builder that receives the selected teamId and returns the tab widget.
  /// Use ValueKey(teamId) on the returned widget to force rebuild.
  final Widget Function(String teamId) builder;

  const TeamSplitWrapper({super.key, required this.builder});

  @override
  State<TeamSplitWrapper> createState() => _TeamSplitWrapperState();
}

class _TeamSplitWrapperState extends State<TeamSplitWrapper> {
  String _selectedTeam = AuthService.currentTeam;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // JA / MA toggle bar
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            children: [
              _buildTeamChip('JA', 'Jagannath', Colors.blue),
              const SizedBox(width: 10),
              _buildTeamChip('MA', 'Madhav', Colors.orange),
            ],
          ),
        ),
        const Divider(height: 1),
        // Tab content — rebuilds when team changes
        Expanded(
          child: KeyedSubtree(
            key: ValueKey('split_$_selectedTeam'),
            child: widget.builder(_selectedTeam),
          ),
        ),
      ],
    );
  }

  Widget _buildTeamChip(String teamId, String label, Color color) {
    final selected = _selectedTeam == teamId;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          if (_selectedTeam != teamId) {
            setState(() {
              _selectedTeam = teamId;
              AuthService.currentTeam = teamId;
            });
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? color : color.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? color : color.withValues(alpha: 0.2),
              width: selected ? 2 : 1,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: GoogleFonts.manrope(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
