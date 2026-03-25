// All 114 errors cascade from the 3 unresolvable package imports; the import statements and all code are syntactically correct for a properly configured Flutter project — no changes needed in the Dart file itself. //

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';
import '../../../services/cart_service.dart';

class ProductListItemWidget extends StatelessWidget {
  final Product product;
  final int cartQuantity;
  final Function(int) onAddToCart;
  final VoidCallback onRemoveFromCart;

  const ProductListItemWidget({
    super.key,
    required this.product,
    required this.cartQuantity,
    required this.onAddToCart,
    required this.onRemoveFromCart,
  });

  bool get _canAddToCart =>
      product.status != ProductStatus.outOfStock &&
      product.status != ProductStatus.discontinued;

  @override
  Widget build(BuildContext context) {
    final isInCart = cartQuantity > 0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isInCart ? AppTheme.primary.withAlpha(12) : AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isInCart
              ? AppTheme.primary.withAlpha(150)
              : AppTheme.outlineVariant,
          width: isInCart ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ─── TOP ROW: Always Visible (SKU, Name, Price, Stock, Action) ───
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 46,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    product.sku.length > 5
                        ? product.sku.substring(0, 5)
                        : product.sku,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.manrope(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product.name,
                        style: GoogleFonts.manrope(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.onSurface,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Text(
                            '₹${product.unitPrice.toStringAsFixed(2)}',
                            style: GoogleFonts.manrope(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.primary,
                            ),
                          ),
                          Text(
                            '• ${product.packSize}',
                            style: GoogleFonts.manrope(
                              fontSize: 11,
                              color: AppTheme.onSurfaceVariant,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: product.stockQty > 50
                                  ? AppTheme.statusAvailableContainer
                                  : product.stockQty > 0
                                      ? AppTheme.warningContainer
                                      : AppTheme.errorContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.inventory_2_outlined,
                                  size: 10,
                                  color: product.stockQty > 50
                                      ? AppTheme.statusAvailable
                                      : product.stockQty > 0
                                          ? AppTheme.warning
                                          : AppTheme.error,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  '${product.stockQty} pcs',
                                  style: GoogleFonts.manrope(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: product.stockQty > 50
                                        ? AppTheme.statusAvailable
                                        : product.stockQty > 0
                                            ? AppTheme.warning
                                            : AppTheme.error,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isInCart)
                  Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.secondary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.remove_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            onRemoveFromCart();
                          },
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32),
                        ),
                        Text(
                          '$cartQuantity',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.add_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            onAddToCart(1);
                          },
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32),
                        ),
                      ],
                    ),
                  )
                else
                  IconButton(
                    icon: Icon(
                      _canAddToCart
                          ? Icons.add_circle_outline_rounded
                          : Icons.block_rounded,
                      color:
                          _canAddToCart ? AppTheme.secondary : AppTheme.outline,
                      size: 28,
                    ),
                    onPressed: _canAddToCart ? () => onAddToCart(1) : null,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),

            // ─── BOTTOM ROW: Quick Add (+1, +2, +3) ───
            if (isInCart && _canAddToCart) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.only(top: 12),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: AppTheme.outlineVariant.withAlpha(128),
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Quick Bulk Add',
                      style: GoogleFonts.manrope(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.onSurfaceVariant,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [1, 2, 3]
                          .map(
                            (n) => Padding(
                              padding: const EdgeInsets.only(left: 8),
                              // FIXED: Replaced GestureDetector with Material & InkWell to guarantee taps
                              child: Material(
                                color: AppTheme.primaryContainer,
                                borderRadius: BorderRadius.circular(8),
                                clipBehavior: Clip
                                    .antiAlias, // Ensures the ripple stays inside the border
                                child: InkWell(
                                  onTap: () {
                                    HapticFeedback.mediumImpact();
                                    onAddToCart(n);
                                  },
                                  child: Container(
                                    width: 38,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: AppTheme.primary.withAlpha(40),
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Center(
                                      child: Text(
                                        '+$n',
                                        style: GoogleFonts.manrope(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w800,
                                          color: AppTheme.primary,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
