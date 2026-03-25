// All 66 errors cascade from the two unresolvable package URIs (flutter/material.dart and google_fonts). The Dart file code is already correctly written; no changes are needed in the file itself — the packages must be added to pubspec.yaml. //
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';

class CategoryFilterChipsWidget extends StatelessWidget {
  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelected;

  const CategoryFilterChipsWidget({
    super.key,
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  IconData _iconForCategory(String category) {
    final lower = category.toLowerCase();
    if (lower == 'all') return Icons.apps_rounded;
    if (lower.contains('snack') || lower.contains('chip')) {
      return Icons.cookie_outlined;
    }
    if (lower.contains('beverage') ||
        lower.contains('drink') ||
        lower.contains('juice')) {
      return Icons.local_drink_outlined;
    }
    if (lower.contains('dairy') ||
        lower.contains('milk') ||
        lower.contains('cheese')) {
      return Icons.egg_alt_outlined;
    }
    if (lower.contains('grain') ||
        lower.contains('rice') ||
        lower.contains('cereal')) {
      return Icons.grain_rounded;
    }
    if (lower.contains('oil') || lower.contains('fat')) {
      return Icons.opacity_outlined;
    }
    if (lower.contains('spice') ||
        lower.contains('masala') ||
        lower.contains('condiment')) {
      return Icons.restaurant_outlined;
    }
    if (lower.contains('personal') ||
        lower.contains('hygiene') ||
        lower.contains('care')) {
      return Icons.spa_outlined;
    }
    if (lower.contains('clean') ||
        lower.contains('detergent') ||
        lower.contains('household')) {
      return Icons.cleaning_services_outlined;
    }
    if (lower.contains('frozen') || lower.contains('ice')) {
      return Icons.ac_unit_outlined;
    }
    if (lower.contains('bakery') ||
        lower.contains('bread') ||
        lower.contains('biscuit')) {
      return Icons.bakery_dining_outlined;
    }
    if (lower.contains('confection') ||
        lower.contains('candy') ||
        lower.contains('chocolate') ||
        lower.contains('sweet')) {
      return Icons.cake_outlined;
    }
    if (lower.contains('sauce') ||
        lower.contains('ketchup') ||
        lower.contains('pickle')) {
      return Icons.set_meal_outlined;
    }
    if (lower.contains('nut') || lower.contains('dry fruit')) {
      return Icons.eco_outlined;
    }
    return Icons.category_outlined;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Text(
                'Categories',
                style: GoogleFonts.manrope(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.onSurfaceVariant,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${categories.length}',
                  style: GoogleFonts.manrope(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 80,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            itemCount: categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final cat = categories[index];
              final isSelected = cat == selected;
              return GestureDetector(
                onTap: () => onSelected(cat),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  width: 72,
                  decoration: BoxDecoration(
                    color: isSelected ? AppTheme.primary : AppTheme.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSelected ? AppTheme.primary : AppTheme.outline,
                      width: 1.5,
                    ),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: AppTheme.primary.withAlpha(50),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : [],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _iconForCategory(cat),
                        size: 22,
                        color: isSelected ? Colors.white : AppTheme.primary,
                      ),
                      const SizedBox(height: 5),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          cat,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.manrope(
                            fontSize: 10,
                            fontWeight:
                                isSelected ? FontWeight.w700 : FontWeight.w500,
                            color: isSelected
                                ? Colors.white
                                : AppTheme.onSurfaceVariant,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ],
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
