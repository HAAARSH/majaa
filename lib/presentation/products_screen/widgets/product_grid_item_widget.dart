import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/cart_service.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/custom_image_widget.dart';

class ProductGridItemWidget extends StatefulWidget {
  final Product product;
  final int cartQuantity;
  final VoidCallback onAddToCart;

  const ProductGridItemWidget({
    super.key,
    required this.product,
    required this.cartQuantity,
    required this.onAddToCart,
  });

  @override
  State<ProductGridItemWidget> createState() => _ProductGridItemWidgetState();
}

class _ProductGridItemWidgetState extends State<ProductGridItemWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 100),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.93).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  bool get _canAdd =>
      widget.product.status != ProductStatus.outOfStock &&
      widget.product.status != ProductStatus.discontinued;

  String get _statusLabel {
    switch (widget.product.status) {
      case ProductStatus.available:
        return 'Available';
      case ProductStatus.lowStock:
        return 'Low Stock';
      case ProductStatus.outOfStock:
        return 'Out of Stock';
      case ProductStatus.discontinued:
        return 'Discontinued';
    }
    return '';
  }

  Color get _statusColor {
    switch (widget.product.status) {
      case ProductStatus.available:
        return AppTheme.statusAvailable;
      case ProductStatus.lowStock:
        return AppTheme.statusLowStock;
      case ProductStatus.outOfStock:
        return AppTheme.statusOutOfStock;
      case ProductStatus.discontinued:
        return AppTheme.onSurfaceVariant;
    }
  }

  Color get _statusBg {
    switch (widget.product.status) {
      case ProductStatus.available:
        return AppTheme.statusAvailableContainer;
      case ProductStatus.lowStock:
        return AppTheme.statusLowStockContainer;
      case ProductStatus.outOfStock:
        return AppTheme.statusOutOfStockContainer;
      case ProductStatus.discontinued:
        return const Color(0xFFF3F4F6);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.outlineVariant, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(13),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          splashColor: AppTheme.primaryContainer,
          onTap: () {},
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CustomImageWidget(
                    imageUrl: widget.product.imageUrl,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    semanticLabel: widget.product.semanticLabel,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        widget.product.name,
                        style: GoogleFonts.manrope(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.onSurface,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.category_outlined,
                                  size: 9,
                                  color: AppTheme.primary,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  widget.product.category,
                                  style: GoogleFonts.manrope(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.primary,
                                    letterSpacing: 0.2,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            widget.product.sku,
                            style: GoogleFonts.manrope(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'MRP',
                                style: GoogleFonts.manrope(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.onSurfaceVariant,
                                  letterSpacing: 0.4,
                                ),
                              ),
                              Text(
                                '₹${widget.product.unitPrice.toStringAsFixed(2)}',
                                style: GoogleFonts.manrope(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.primary,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: widget.product.stockQty > 50
                                  ? AppTheme.statusAvailableContainer
                                  : widget.product.stockQty > 0
                                      ? AppTheme.warningContainer
                                      : AppTheme.errorContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.inventory_2_outlined,
                                  size: 10,
                                  color: widget.product.stockQty > 50
                                      ? AppTheme.statusAvailable
                                      : widget.product.stockQty > 0
                                          ? AppTheme.warning
                                          : AppTheme.error,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  '${widget.product.stockQty} pcs',
                                  style: GoogleFonts.manrope(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                    color: widget.product.stockQty > 50
                                        ? AppTheme.statusAvailable
                                        : widget.product.stockQty > 0
                                            ? AppTheme.warning
                                            : AppTheme.error,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: _statusBg,
                              borderRadius: BorderRadius.circular(100),
                            ),
                            child: Text(
                              _statusLabel,
                              style: GoogleFonts.manrope(
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                color: _statusColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ScaleTransition(
                  scale: _scaleAnim,
                  child: GestureDetector(
                    onTapDown: (_) =>
                        _canAdd ? _scaleController.forward() : null,
                    onTapUp: (_) {
                      if (_canAdd) {
                        _scaleController.reverse();
                        widget.onAddToCart();
                      }
                    },
                    onTapCancel: () => _scaleController.reverse(),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _canAdd ? AppTheme.secondary : AppTheme.outline,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _canAdd ? Icons.add_rounded : Icons.block_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
