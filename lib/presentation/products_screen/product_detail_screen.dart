import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';
import '../../services/cart_service.dart';
import 'package:fluttertoast/fluttertoast.dart';

class ProductDetailScreen extends StatefulWidget {
  const ProductDetailScreen({super.key});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  Product? _product;
  bool _isInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      final args = ModalRoute.of(context)?.settings.arguments as Map?;
      _product = args?['product'] as Product?;
      _isInitialized = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_product == null) {
      return Scaffold(
        backgroundColor: AppTheme.surface,
        appBar: AppBar(
          title: Text('Product Details', style: GoogleFonts.manrope(fontWeight: FontWeight.bold)),
          elevation: 0,
          backgroundColor: Colors.white,
          foregroundColor: AppTheme.onSurface,
        ),
        body: Center(child: Text('Product not found', style: GoogleFonts.manrope(fontSize: 16, color: AppTheme.onSurfaceVariant))),
      );
    }
    final product = _product!;
    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        title: Text(
          'Product Details',
          style: GoogleFonts.manrope(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: AppTheme.onSurface,
      ),
      bottomNavigationBar: CartService.instance.currentCustomer != null
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: ValueListenableBuilder<List<CartItem>>(
                  valueListenable: CartService.instance.cartNotifier,
                  builder: (context, cart, _) {
                    final inCart = cart.indexWhere((ci) => ci.product.id == product.id);
                    final qty = inCart >= 0 ? cart[inCart].quantity : 0;
                    return Row(
                      children: [
                        if (qty > 0) ...[
                          IconButton.filled(
                            icon: const Icon(Icons.remove),
                            style: IconButton.styleFrom(backgroundColor: AppTheme.primaryContainer),
                            onPressed: () => CartService.instance.removeItem(product),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text('$qty', style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w800)),
                          ),
                        ],
                        Expanded(
                          child: FilledButton.icon(
                            icon: Icon(qty > 0 ? Icons.add : Icons.add_shopping_cart_rounded),
                            label: Text(qty > 0 ? 'Add More' : 'Add to Cart', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.primary,
                              minimumSize: const Size.fromHeight(52),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            // Gate on ProductModel.isBillable instead of the
                            // legacy status == outOfStock check: billable is
                            // (stockQty > 0) OR within the 2-day grace
                            // window after the product first zeroed. Drive
                            // sync still sets status='outOfStock' for qty<=0
                            // but that no longer blocks an in-grace product
                            // from being added to cart.
                            onPressed: !product.isBillable
                                ? null
                                : () {
                                    CartService.instance.addOrUpdateItem(product, product.stepSize);
                                    Fluttertoast.showToast(msg: '${product.name} added to cart');
                                  },
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            )
          : null,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Product Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(32),
                  bottomRight: Radius.circular(32),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.category.toUpperCase(),
                    style: GoogleFonts.manrope(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.onSurfaceVariant,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    product.name,
                    style: GoogleFonts.manrope(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 24),
                    Row(
                      children: [
                        Text(
                          '₹${product.unitPrice.toStringAsFixed(2)}',
                          style: GoogleFonts.manrope(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            color: AppTheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'per ${product.unit}',
                          style: GoogleFonts.manrope(
                            fontSize: 14,
                            color: AppTheme.onSurfaceVariant,
                          ),
                        ),
                        if (product.packSize.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(
                            '(${product.packSize})',
                            style: GoogleFonts.manrope(
                              fontSize: 12,
                              color: AppTheme.onSurfaceVariant,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Inventory Status
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppTheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        // Three-state colour: stocked (green) / in-grace
                        // (amber) / out-of-stock (red). Matches the grid
                        // card chip so state is consistent across the flow.
                        color: product.stockQty > 0
                            ? AppTheme.statusAvailableContainer
                            : product.isInStockGrace()
                                ? AppTheme.warningContainer
                                : AppTheme.errorContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        product.stockQty > 0
                            ? Icons.inventory_2_rounded
                            : product.isInStockGrace()
                                ? Icons.hourglass_bottom_rounded
                                : Icons.block_rounded,
                        color: product.stockQty > 0
                            ? AppTheme.statusAvailable
                            : product.isInStockGrace()
                                ? AppTheme.warning
                                : AppTheme.error,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Current Stock',
                            style: GoogleFonts.manrope(
                              fontSize: 14,
                              color: AppTheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            product.stockQty > 0
                                ? '${product.stockQty} Units Available'
                                : product.isInStockGrace()
                                    ? 'Out of stock — grace ${product.graceDaysLeft()}d left'
                                    : 'Out of stock — ask office to restock',
                            style: GoogleFonts.manrope(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: product.status == ProductStatus.available ? AppTheme.statusAvailableContainer : AppTheme.errorContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        product.status.name.toUpperCase(),
                        style: GoogleFonts.manrope(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: product.status == ProductStatus.available ? AppTheme.statusAvailable : AppTheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Additional Info
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Product Information',
                    style: GoogleFonts.manrope(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildInfoRow('Pack Size', product.packSize),
                  _buildInfoRow('Step Size', '${product.stepSize} ${product.unit}'),
                  _buildInfoRow('Tax Rate', '${(product.gstRate * 100).toStringAsFixed(0)}% GST'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: GoogleFonts.manrope(
              color: AppTheme.onSurfaceVariant,
              fontSize: 14,
            ),
          ),
          Text(
            value,
            style: GoogleFonts.manrope(
              fontWeight: FontWeight.w600,
              color: AppTheme.onSurface,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
