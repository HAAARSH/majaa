import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';

class OrderTotalsCardWidget extends StatelessWidget {
  final double subtotal;
  final double totalGst;
  final double grandTotal;
  final int totalUnits;
  final int totalLines;

  const OrderTotalsCardWidget({
    super.key,
    required this.subtotal,
    required this.totalGst,
    required this.grandTotal,
    required this.totalUnits,
    required this.totalLines,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.outlineVariant, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(10),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                const Icon(
                  Icons.calculate_outlined,
                  size: 18,
                  color: AppTheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Order Summary',
                  style: GoogleFonts.manrope(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: AppTheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    _StatPill(
                      label: '$totalLines lines',
                      icon: Icons.list_alt_rounded,
                    ),
                    const SizedBox(width: 8),
                    _StatPill(
                      label: '$totalUnits units',
                      icon: Icons.inventory_2_outlined,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _TotalsRow(
                  label: 'Subtotal',
                  value: '₹${subtotal.toStringAsFixed(2)}',
                  isHeader: false,
                ),
                const SizedBox(height: 8),
                _TotalsRow(
                  label: 'GST Total',
                  value: '₹${totalGst.toStringAsFixed(2)}',
                  isHeader: false,
                ),
                const SizedBox(height: 12),
                Divider(height: 1, color: AppTheme.outlineVariant),
                const SizedBox(height: 12),
                _TotalsRow(
                  label: 'Grand Total',
                  value: '₹${grandTotal.toStringAsFixed(2)}',
                  isHeader: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalsRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isHeader;
  const _TotalsRow({
    required this.label,
    required this.value,
    required this.isHeader,
  });
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: GoogleFonts.manrope(
            fontSize: isHeader ? 15 : 13,
            fontWeight: isHeader ? FontWeight.w700 : FontWeight.w500,
            color: isHeader ? AppTheme.onSurface : AppTheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: GoogleFonts.manrope(
            fontSize: isHeader ? 20 : 14,
            fontWeight: isHeader ? FontWeight.w800 : FontWeight.w600,
            color: isHeader ? AppTheme.primary : AppTheme.onSurface,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _StatPill extends StatelessWidget {
  final String label;
  final IconData icon;
  const _StatPill({required this.label, required this.icon});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.primaryContainer,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppTheme.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.manrope(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
