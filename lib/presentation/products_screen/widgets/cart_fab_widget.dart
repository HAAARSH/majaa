import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';

class CartFabWidget extends StatefulWidget {
  final int itemCount;
  final double cartTotal;
  final VoidCallback onTap;

  const CartFabWidget({
    super.key,
    required this.itemCount,
    required this.cartTotal,
    required this.onTap,
  });

  @override
  State<CartFabWidget> createState() => _CartFabWidgetState();
}

class _CartFabWidgetState extends State<CartFabWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _badgeController;
  late Animation<double> _badgeScale;
  int _prevCount = 0;

  @override
  void initState() {
    super.initState();
    _badgeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _badgeScale = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _badgeController, curve: Curves.easeOutBack),
    );
  }

  @override
  void didUpdateWidget(CartFabWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.itemCount != _prevCount) {
      _badgeController.reset();
      _badgeController.forward();
      _prevCount = widget.itemCount;
    }
  }

  @override
  void dispose() {
    _badgeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) return const SizedBox.shrink();

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        height: 56,
        constraints: const BoxConstraints(minWidth: 160),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: AppTheme.secondary,
          borderRadius: BorderRadius.circular(100),
          boxShadow: [
            BoxShadow(
              color: AppTheme.secondary.withAlpha(89),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.shopping_cart_rounded,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(width: 10),
            ScaleTransition(
              scale: _badgeScale,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(56),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  '${widget.itemCount} item${widget.itemCount == 1 ? '' : 's'}',
                  style: GoogleFonts.manrope(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '₹${widget.cartTotal.toStringAsFixed(2)}',
              style: GoogleFonts.manrope(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.arrow_forward_rounded,
              color: Colors.white,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}
