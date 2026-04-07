import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';
import '../../../services/supabase_service.dart'; // ADDED: for brand access check

class CategoryFilterChipsWidget extends StatelessWidget {
  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelected;
  // ADDED: brand access filter — if non-empty, only these brands are shown
  final List<String> allowedBrands;

  const CategoryFilterChipsWidget({
    super.key,
    required this.categories,
    required this.selected,
    required this.onSelected,
    this.allowedBrands = const [], // ADDED: default empty = show all
  });

  @override
  Widget build(BuildContext context) {
    // Filter categories by brand access (empty allowedBrands = no restriction)
    final visibleCategories = allowedBrands.isEmpty
        ? categories
        : ['All', ...allowedBrands.where((b) => categories.contains(b))];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Category Header remains the same
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Categories (${visibleCategories.length})',
            style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.onSurfaceVariant),
          ),
        ),
        SizedBox(
          height: 50, // Reduced to half size
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: visibleCategories.length, // CHANGED: use filtered list
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final cat = visibleCategories[index]; // CHANGED: use filtered list
              final isSelected = cat == selected;
              return GestureDetector(
                onTap: () => onSelected(cat),
                child: Container(
                  width: 85, // Fixed width for uniformity
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: isSelected ? AppTheme.primary : AppTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: isSelected ? AppTheme.primary : AppTheme.outlineVariant),
                  ),
                  // FittedBox ensures long text gets smaller to fit
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      cat,
                      style: GoogleFonts.manrope(
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                        color: isSelected ? Colors.white : AppTheme.onSurface,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
