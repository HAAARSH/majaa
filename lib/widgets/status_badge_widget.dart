import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

enum ProductStatus { available, lowStock, outOfStock, discontinued }

enum OrderStatus { draft, submitted, confirmed, fulfilled }

class StatusBadgeWidget extends StatelessWidget {
  final String label;
  final Color backgroundColor;
  final Color textColor;
  final double fontSize;

  const StatusBadgeWidget({
    super.key,
    required this.label,
    required this.backgroundColor,
    required this.textColor,
    this.fontSize = 11,
  });

  factory StatusBadgeWidget.productStatus(ProductStatus status) {
    switch (status) {
      case ProductStatus.available:
        return StatusBadgeWidget(
          label: 'Available',
          backgroundColor: AppTheme.statusAvailableContainer,
          textColor: AppTheme.statusAvailable,
        );
      case ProductStatus.lowStock:
        return StatusBadgeWidget(
          label: 'Low Stock',
          backgroundColor: AppTheme.statusLowStockContainer,
          textColor: AppTheme.statusLowStock,
        );
      case ProductStatus.outOfStock:
        return StatusBadgeWidget(
          label: 'Out of Stock',
          backgroundColor: AppTheme.statusOutOfStockContainer,
          textColor: AppTheme.statusOutOfStock,
        );
      case ProductStatus.discontinued:
        return StatusBadgeWidget(
          label: 'Discontinued',
          backgroundColor: const Color(0xFFF3F4F6),
          textColor: const Color(0xFF6B7280),
        );
    }
  }

  factory StatusBadgeWidget.orderStatus(OrderStatus status) {
    switch (status) {
      case OrderStatus.draft:
        return const StatusBadgeWidget(
          label: 'Draft',
          backgroundColor: Color(0xFFF3F4F6),
          textColor: Color(0xFF6B7280),
        );
      case OrderStatus.submitted:
        return StatusBadgeWidget(
          label: 'Submitted',
          backgroundColor: AppTheme.primaryContainer,
          textColor: AppTheme.primary,
        );
      case OrderStatus.confirmed:
        return StatusBadgeWidget(
          label: 'Confirmed',
          backgroundColor: AppTheme.statusAvailableContainer,
          textColor: AppTheme.statusAvailable,
        );
      case OrderStatus.fulfilled:
        return const StatusBadgeWidget(
          label: 'Fulfilled',
          backgroundColor: Color(0xFFE0F2F1),
          textColor: Color(0xFF00574B),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        label,
        style: GoogleFonts.manrope(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: textColor,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
