import 'dart:async'; // NEW: Required for the Debounce Timer
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../services/cart_service.dart';
import '../../theme/app_theme.dart';
import './widgets/cart_fab_widget.dart';
import './widgets/category_filter_chips_widget.dart';
import './widgets/product_list_item_widget.dart';
import './widgets/product_search_bar_widget.dart';
import './widgets/sync_status_banner_widget.dart';

class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen>
    with TickerProviderStateMixin {
  bool _isLoading = true;
  String? _error;
  String _selectedCategory = 'All';
  List<Product> _allProducts = [];
  bool _showSyncBanner = true;
  DateTime? _lastSynced;
  List<String> _categories = ['All'];

  // NEW: Debounce Search Variables
  String _searchQuery = ''; // Instantly updates the UI text/clear button
  String _debouncedQuery = ''; // Waits 300ms before filtering the list
  Timer? _debounce;

  CustomerModel? get _preSelectedCustomer =>
      CartService.instance.currentCustomer;
  BeatModel? get _preSelectedBeat => CartService.instance.currentBeat;

  @override
  void initState() {
    super.initState();
    _loadCategories();
    _loadProducts();
  }

  @override
  void dispose() {
    _debounce?.cancel(); // Clean up the timer when leaving the screen
    super.dispose();
  }

  Future<void> _loadCategories() async {
    try {
      final cats = await SupabaseService.instance.getProductCategories();
      if (!mounted) return;
      setState(() => _categories = ['All', ...cats.map((c) => c.name)]);
    } catch (_) {}
  }

  Future<void> _loadProducts() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final models = await SupabaseService.instance.getProducts();
      if (!mounted) return;
      final products = models.map(Product.fromModel).toList();
      products
          .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _allProducts = products;
        _isLoading = false;
        _lastSynced = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _onRefresh() async {
    setState(() => _showSyncBanner = true);
    await _loadCategories();
    await _loadProducts();
  }

  // Uses _debouncedQuery instead of _searchQuery to prevent lag
  List<Product> get _filteredProducts {
    return _allProducts.where((p) {
      final matchesCategory =
          _selectedCategory == 'All' || p.category == _selectedCategory;
      final query = _debouncedQuery.toLowerCase();
      final matchesSearch = query.isEmpty ||
          p.name.toLowerCase().contains(query) ||
          p.sku.toLowerCase().contains(query);
      return matchesCategory && matchesSearch;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<CartItem>>(
        valueListenable: CartService.instance.cartNotifier,
        builder: (context, cartItems, _) {
          return Scaffold(
            backgroundColor: AppTheme.background,
            body: SafeArea(
              child: RefreshIndicator(
                onRefresh: _onRefresh,
                color: AppTheme.primary,
                child: CustomScrollView(
                  slivers: [
                    SliverAppBar(
                      expandedHeight: 80,
                      pinned: true,
                      backgroundColor: AppTheme.surface,
                      elevation: 0,
                      centerTitle: true,
                      leading: _preSelectedCustomer != null
                          ? IconButton(
                              icon:
                                  const Icon(Icons.arrow_back_ios_new_rounded),
                              onPressed: () => Navigator.pop(context))
                          : null,
                      title: Text('Product Catalog',
                          style: GoogleFonts.manrope(
                              fontWeight: FontWeight.w700,
                              color: AppTheme.onSurface,
                              fontSize: 18)),
                    ),
                    if (_showSyncBanner)
                      SliverToBoxAdapter(
                          child: SyncStatusBannerWidget(
                              lastSynced: _lastSynced ?? DateTime.now(),
                              skuCount: _allProducts.length,
                              onDismiss: () =>
                                  setState(() => _showSyncBanner = false))),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _StickyHeaderDelegate(
                        child: Material(
                          elevation: 1,
                          color: AppTheme.background,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 12, 16, 0),
                                child: ProductSearchBarWidget(
                                    query: _searchQuery,
                                    onChanged: (val) {
                                      // Update UI instantly
                                      setState(() => _searchQuery = val);

                                      // Debounce the list filtering
                                      if (_debounce?.isActive ?? false) {
                                        _debounce!.cancel();
                                      }
                                      _debounce = Timer(
                                          const Duration(milliseconds: 300),
                                          () {
                                        setState(() => _debouncedQuery = val);
                                      });
                                    },
                                    onClear: () {
                                      if (_debounce?.isActive ?? false) {
                                        _debounce!.cancel();
                                      }
                                      setState(() {
                                        _searchQuery = '';
                                        _debouncedQuery = '';
                                      });
                                    }),
                              ),
                              CategoryFilterChipsWidget(
                                  categories: _categories,
                                  selected: _selectedCategory,
                                  onSelected: (cat) =>
                                      setState(() => _selectedCategory = cat)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_isLoading)
                      const SliverToBoxAdapter(
                          child: Padding(
                              padding: EdgeInsets.all(40),
                              child:
                                  Center(child: CircularProgressIndicator())))
                    else if (_error != null)
                      SliverToBoxAdapter(
                          child: Padding(
                              padding: const EdgeInsets.all(40),
                              child: Center(
                                  child: Column(
                                children: [
                                  const Icon(Icons.error_outline_rounded,
                                      color: AppTheme.error, size: 48),
                                  const SizedBox(height: 16),
                                  Text('Error: $_error',
                                      textAlign: TextAlign.center,
                                      style: GoogleFonts.manrope(
                                          color: AppTheme.error)),
                                  const SizedBox(height: 16),
                                  ElevatedButton(
                                      onPressed: _onRefresh,
                                      child: const Text('Retry'))
                                ],
                              ))))
                    else if (_filteredProducts.isEmpty)
                      SliverToBoxAdapter(
                          child: Padding(
                              padding: const EdgeInsets.all(40),
                              child: Center(
                                  child: Text('No products found',
                                      style: GoogleFonts.manrope(
                                          color: AppTheme.onSurfaceVariant)))))
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 100),
                        sliver: SliverList(
                          delegate:
                              SliverChildBuilderDelegate((context, index) {
                            final p = _filteredProducts[index];
                            return ProductListItemWidget(
                              product: p,
                              cartQuantity:
                                  CartService.instance.getQuantity(p.id),
                              onAddToCart: (qty) =>
                                  CartService.instance.addOrUpdateItem(p, qty),
                              onRemoveFromCart: () =>
                                  CartService.instance.removeItem(p),
                            );
                          }, childCount: _filteredProducts.length),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            floatingActionButton: CartFabWidget(
              itemCount: cartItems.fold(0, (sum, item) => sum + item.quantity),
              cartTotal: cartItems.fold(0.0,
                  (sum, item) => sum + item.product.unitPrice * item.quantity),
              onTap: () =>
                  Navigator.pushNamed(context, AppRoutes.orderCreationScreen),
            ),
          );
        });
  }
}

class _StickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  _StickyHeaderDelegate({required this.child});
  @override
  Widget build(context, double shrinkOffset, bool overlapsContent) => child;
  @override
  double get maxExtent => 155.0;
  @override
  double get minExtent => 155.0;
  @override
  bool shouldRebuild(_StickyHeaderDelegate oldDelegate) => true;
}
