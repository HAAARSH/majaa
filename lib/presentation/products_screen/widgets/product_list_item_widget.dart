import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';
import '../../../services/cart_service.dart';
import '../../../routes/app_routes.dart';

class ProductListItemWidget extends StatelessWidget {
  final Product product;
  final Function(int) onAddToCart;
  final VoidCallback onRemoveFromCart;
  final bool showStock; // ADDED: hide stock badge when false

  const ProductListItemWidget({
    super.key,
    required this.product,
    required this.onAddToCart,
    required this.onRemoveFromCart,
    this.showStock = true, // ADDED: default true (backward compatible)
  });

  bool get _canAddToCart =>
      product.status != ProductStatus.outOfStock &&
      product.status != ProductStatus.discontinued;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<CartItem>>(
      valueListenable: CartService.instance.cartNotifier,
      builder: (context, cartItems, _) {
        final cartQuantity = CartService.instance.getQuantity(product.id);
        return _buildCard(context, cartQuantity);
      },
    );
  }

  Widget _buildCard(BuildContext context, int cartQuantity) {
    final isInCart = cartQuantity > 0;
    final stockColor = product.stockQty > 50
        ? AppTheme.statusAvailable
        : product.stockQty > 0
            ? AppTheme.warning
            : AppTheme.error;
    final stockBgColor = product.stockQty > 50
        ? AppTheme.statusAvailableContainer
        : product.stockQty > 0
            ? AppTheme.warningContainer
            : AppTheme.errorContainer;

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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ─── TOP ROW: Name + Cart Action ───────────────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Name + meta (tappable for detail)
                Expanded(
                  child: InkWell(
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.productDetailScreen,
                      arguments: {'product': product},
                    ),
                    borderRadius: BorderRadius.circular(6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          product.name,
                          style: GoogleFonts.manrope(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.onSurface,
                            height: 1.25,
                          ),
                        ),
                        if (product.brand.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            product.brand,
                            style: GoogleFonts.manrope(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // ─── Cart control ───────────────────────────────────────
                if (isInCart)
                  _CartStepper(
                    quantity: cartQuantity,
                    onAdd: () {
                      HapticFeedback.lightImpact();
                      onAddToCart(product.stepSize);
                    },
                    onRemove: () {
                      HapticFeedback.lightImpact();
                      onRemoveFromCart();
                    },
                  )
                else
                  IconButton(
                    icon: Icon(
                      _canAddToCart
                          ? Icons.add_circle_outline_rounded
                          : Icons.block_rounded,
                      color: _canAddToCart
                          ? AppTheme.secondary
                          : AppTheme.outline,
                      size: 28,
                    ),
                    onPressed:
                        _canAddToCart ? () => onAddToCart(product.stepSize) : null,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),

            const SizedBox(height: 8),

            // ─── META ROW: Price, Pack, Stock ──────────────────────────────
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // Price
                Text(
                  '₹${product.unitPrice.toStringAsFixed(2)}',
                  style: GoogleFonts.manrope(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary,
                  ),
                ),
                // Unit
                Text(
                  '/ ${product.unit}',
                  style: GoogleFonts.manrope(
                    fontSize: 11,
                    color: AppTheme.onSurfaceVariant,
                  ),
                ),
                // Pack size
                if (product.packSize.isNotEmpty)
                  _MetaChip(
                    label: product.packSize,
                    color: AppTheme.onSurfaceVariant,
                    bgColor: AppTheme.surfaceVariant,
                  ),
                // SKU
                if (product.sku.isNotEmpty)
                  _MetaChip(
                    label: product.sku,
                    color: AppTheme.onSurfaceVariant,
                    bgColor: AppTheme.surfaceVariant,
                  ),
                // Stock badge — CHANGED: only show when showStock is true
                if (showStock)
                  _MetaChip(
                    icon: Icons.inventory_2_outlined,
                    label: '${product.stockQty} ${product.unit}',
                    color: stockColor,
                    bgColor: stockBgColor,
                  ),
              ],
            ),

            // ─── QUICK BULK ADD (when in cart) ─────────────────────────────
            if (isInCart && _canAddToCart) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.only(top: 10),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                        color: AppTheme.outlineVariant.withAlpha(128)),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Quick Add',
                      style: GoogleFonts.manrope(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.onSurfaceVariant,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [1, 2, 3]
                          .map((n) => Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Material(
                                  color: AppTheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(8),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: () {
                                      HapticFeedback.mediumImpact();
                                      onAddToCart(n * product.stepSize);
                                    },
                                    child: Container(
                                      width: 38,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color:
                                              AppTheme.primary.withAlpha(40),
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Center(
                                        child: Text(
                                          '+${n * product.stepSize}',
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
                              ))
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

// ─── Cart Stepper ─────────────────────────────────────────────────────────────

class _CartStepper extends StatelessWidget {
  final int quantity;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  const _CartStepper({
    required this.quantity,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: AppTheme.secondary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepButton(icon: Icons.remove_rounded, onTap: onRemove),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '$quantity',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          _StepButton(icon: Icons.add_rounded, onTap: onAdd),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _StepButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: Colors.white, size: 18),
      onPressed: onTap,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
    );
  }
}

// ─── Meta Chip ────────────────────────────────────────────────────────────────

class _MetaChip extends StatelessWidget {
  final String label;
  final Color color;
  final Color bgColor;
  final IconData? icon;

  const _MetaChip({
    required this.label,
    required this.color,
    required this.bgColor,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: GoogleFonts.manrope(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
