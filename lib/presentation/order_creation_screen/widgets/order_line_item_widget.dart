import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../services/cart_service.dart';
import '../../../../theme/app_theme.dart';
import '../../../../widgets/custom_image_widget.dart';

class OrderLineItemWidget extends StatefulWidget {
  final CartItem cartItem;
  final int index;
  final ValueChanged<int> onQuantityChanged;
  final VoidCallback onRemove;

  const OrderLineItemWidget({
    super.key,
    required this.cartItem,
    required this.index,
    required this.onQuantityChanged,
    required this.onRemove,
  });

  @override
  State<OrderLineItemWidget> createState() => _OrderLineItemWidgetState();
}

class _OrderLineItemWidgetState extends State<OrderLineItemWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _totalController;
  late Animation<double> _totalFade;

  @override
  void initState() {
    super.initState();
    _totalController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..value = 1.0;
    _totalFade = Tween<double>(
      begin: 0.4,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _totalController, curve: Curves.easeOut));
  }

  @override
  void didUpdateWidget(OrderLineItemWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cartItem.quantity != widget.cartItem.quantity) {
      _totalController.reset();
      _totalController.forward();
    }
  }

  @override
  void dispose() {
    _totalController.dispose();
    super.dispose();
  }

  double get _lineTotal =>
      widget.cartItem.product.unitPrice * widget.cartItem.quantity;

  @override
  Widget build(BuildContext context) {
    final product = widget.cartItem.product;

    return Dismissible(
      key: ValueKey('dismiss_${product.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: AppTheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.delete_outline_rounded,
          color: AppTheme.error,
          size: 24,
        ),
      ),
      confirmDismiss: (direction) async {
        return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: AppTheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: Text(
                  'Remove Item',
                  style: GoogleFonts.manrope(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                content: Text(
                  'Remove ${product.name} from this order?',
                  style: GoogleFonts.manrope(
                    fontSize: 14,
                    color: AppTheme.onSurfaceVariant,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(
                      'Cancel',
                      style: GoogleFonts.manrope(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.error,
                    ),
                    child: Text(
                      'Remove',
                      style: GoogleFonts.manrope(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ) ??
            false;
      },
      onDismissed: (_) => widget.onRemove(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment:
              CrossAxisAlignment.start, // Align to top so it scales well
          children: [
            // Sequence Number
            Container(
              width: 22,
              height: 22,
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                color: AppTheme.surfaceVariant,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '${widget.index + 1}',
                  style: GoogleFonts.manrope(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),

            // Product Image
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CustomImageWidget(
                imageUrl: product.imageUrl,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                semanticLabel: product.semanticLabel,
              ),
            ),
            const SizedBox(width: 10),

            // Product Details (Expanded to push right elements away)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Product Name (Allows 2 lines now)
                  Text(
                    product.name,
                    style: GoogleFonts.manrope(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),

                  // SKU and Unit Price (Wrap ensures it drops to next line if needed)
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        product.sku,
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '·',
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          color: AppTheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '₹${product.unitPrice.toStringAsFixed(2)}/unit',
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.primary,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Quantity Controls
                  Row(
                    children: [
                      _QtyButton(
                        icon: Icons.remove_rounded,
                        onTap: () => widget.onQuantityChanged(
                          widget.cartItem.quantity - 1,
                        ),
                        color: widget.cartItem.quantity <= 1
                            ? AppTheme.error
                            : AppTheme.onSurfaceVariant,
                        bgColor: widget.cartItem.quantity <= 1
                            ? AppTheme.errorContainer
                            : AppTheme.surfaceVariant,
                      ),
                      Container(
                        width: 40,
                        height: 28,
                        alignment: Alignment.center,
                        child: Text(
                          '${widget.cartItem.quantity}',
                          style: GoogleFonts.manrope(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.onSurface,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      _QtyButton(
                        icon: Icons.add_rounded,
                        onTap: () => widget.onQuantityChanged(
                          widget.cartItem.quantity + 1,
                        ),
                        color: AppTheme.secondary,
                        bgColor: AppTheme.secondaryContainer,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // Total Price Section
            FadeTransition(
              opacity: _totalFade,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '₹${_lineTotal.toStringAsFixed(2)}',
                    style: GoogleFonts.manrope(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.primary,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.cartItem.quantity} qty',
                    style: GoogleFonts.manrope(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QtyButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;
  final Color bgColor;

  const _QtyButton({
    required this.icon,
    required this.onTap,
    required this.color,
    required this.bgColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}
