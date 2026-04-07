import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';

class AdminSectionItem {
  final String label;
  final IconData icon;
  final Widget child;

  const AdminSectionItem({
    required this.label,
    required this.icon,
    required this.child,
  });
}

/// Wraps multiple admin sub-tabs with a chip bar at the top.
/// Uses IndexedStack to preserve state across sub-tab switches.
class AdminSectionWrapper extends StatefulWidget {
  final List<AdminSectionItem> items;

  const AdminSectionWrapper({super.key, required this.items});

  @override
  State<AdminSectionWrapper> createState() => _AdminSectionWrapperState();
}

class _AdminSectionWrapperState extends State<AdminSectionWrapper> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(widget.items.length, (i) {
                final item = widget.items[i];
                final selected = _selectedIndex == i;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () {
                      if (_selectedIndex != i) {
                        setState(() => _selectedIndex = i);
                      }
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? AppTheme.primary
                            : AppTheme.primary.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: selected
                              ? AppTheme.primary
                              : AppTheme.primary.withValues(alpha: 0.2),
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            item.icon,
                            size: 16,
                            color: selected
                                ? Colors.white
                                : AppTheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            item.label,
                            style: GoogleFonts.manrope(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: selected
                                  ? Colors.white
                                  : AppTheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: IndexedStack(
            index: _selectedIndex,
            children: widget.items.map((e) => e.child).toList(),
          ),
        ),
      ],
    );
  }
}
