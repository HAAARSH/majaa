import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../services/cart_service.dart';
import '../../services/auth_service.dart';
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
  // ─── Categories ───
  List<ProductCategoryModel> _categoryModels = [];
  List<String> _categories = ['All'];
  String _selectedCategory = 'All';
  String? _selectedCategoryName; // null → 'All'

  // ─── Subcategories ───
  List<ProductSubcategoryModel> _subcategories = [];
  String? _selectedSubcategoryId; // null → show all
  List<ProductModel> _allCategoryProductModels = []; // raw models for subcategory filtering

  // ─── Products ───
  List<Product> _displayedProducts = []; // active category products
  List<Product> _allProducts = []; // populated on full refresh (for banner count)

  // ─── Smart sorting: Past items first for "All" category ───
  Future<List<Product>> _applySmartSorting(List<Product> products) async {
    // Only apply smart sorting for "All" category
    if (_selectedCategory != 'All') {
      products.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return products;
    }

    // Get current customer's past purchases from Hive cache
    final customer = _preSelectedCustomer;
    if (customer == null) {
      products.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return products;
    }

    try {
      // Extract product IDs from customer's order history with frequency
      final productFrequencies = await _getCustomerPurchasedProductIds(customer.id);
      
      if (productFrequencies.isEmpty) {
        products.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        return products;
      }

      // Separate products into purchased and unpurchased with frequency data
      final purchasedProducts = <Product>[];
      final unpurchasedProducts = <Product>[];
      
      for (final product in products) {
        final frequency = productFrequencies[product.id] ?? 0;
        if (frequency > 0) {
          purchasedProducts.add(product);
        } else {
          unpurchasedProducts.add(product);
        }
      }

      // Sort purchased products by highest frequency first, then alphabetical
      purchasedProducts.sort((a, b) {
        final freqA = productFrequencies[a.id] ?? 0;
        final freqB = productFrequencies[b.id] ?? 0;
        
        if (freqA != freqB) {
          return freqB.compareTo(freqA); // Higher frequency first
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      
      // Sort unpurchased products alphabetically
      unpurchasedProducts.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      // Combine: purchased products first, then unpurchased
      return [...purchasedProducts, ...unpurchasedProducts];
    } catch (e) {
      // Fallback to alphabetical sorting if smart sorting fails
      products.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return products;
    }
  }

  /// Get product IDs that are customer has previously purchased from Hive cache
  Future<Map<String, int>> _getCustomerPurchasedProductIds(String customerId) async {
    try {
      // Try to get orders from Hive cache
      if (!Hive.isBoxOpen('orders')) {
        await Hive.openBox('orders');
      }
      
      final ordersBox = Hive.box('orders');
      final allOrders = ordersBox.values.toList();
      
      // Filter orders for this customer and extract product IDs with frequency
      final productFrequencies = <String, int>{};
      
      for (final orderData in allOrders) {
        if (orderData is Map && orderData['customer_id'] == customerId) {
          final items = orderData['items'] as List? ?? [];
          for (final item in items) {
            if (item is Map && item['product_id'] != null) {
              final productId = item['product_id'].toString();
              productFrequencies[productId] = (productFrequencies[productId] ?? 0) + 1;
            }
          }
        }
      }
      
      return productFrequencies;
    } catch (e) {
      debugPrint('Error getting customer purchase history: $e');
      return <String, int>{};
    }
  }

  // ─── Search ───
  List<Product> _searchResults = [];
  int _searchPage = 0;
  bool _hasMoreSearchResults = true;
  bool _isSearchLoading = false;
  bool _isLoadingMoreSearch = false;

  // ─── Loading states ───
  bool _isLoading = true; // initial load
  bool _isCategoryLoading = false; // category switch skeleton
  String? _error;

  // ─── Sync banner ───
  bool _showSyncBanner = false;
  DateTime? _lastSynced;

  // ADDED: Brand access control — empty means no restriction (show all)
  List<String> _allowedBrands = [];
  // ADDED: Stock visibility control — default true (show stock)
  bool _showStock = true;

  // ADDED: Computed filtered lists — hide products with stock_qty <= 0
  List<Product> get _inStockDisplayed => _displayedProducts.where((p) => p.stockQty > 0).toList();
  List<Product> get _inStockSearchResults => _searchResults.where((p) => p.stockQty > 0).toList();

  // ─── Search query ───
  String _searchQuery = '';
  String _debouncedQuery = '';
  Timer? _debounce;

  late ScrollController _scrollController;

  CustomerModel? get _preSelectedCustomer => CartService.instance.currentCustomer;

  bool get _isSearchMode => _debouncedQuery.length >= 3;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_onScroll);
    _loadCategoriesAndAutoSelect();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  // ─── Scroll listener — pagination during search ───
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (!_isSearchMode) return;
    if (_isLoadingMoreSearch || !_hasMoreSearchResults) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _searchPage++;
      _performSearch(_debouncedQuery, append: true);
    }
  }

  // ─── Initial load: categories + auto-select first ───
  Future<void> _loadCategoriesAndAutoSelect() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final userId = SupabaseService.instance.client.auth.currentUser?.id;
      final allowedBrands = userId != null
          ? await SupabaseService.instance.getUserBrandAccess(userId)
          : <String>[];
      final showStock = userId != null
          ? await SupabaseService.instance.getUserShowStock(userId)
          : true;

      // Fetch categories: own team + any cross-team allowed brands
      var cats = await SupabaseService.instance.getProductCategories();
      if (allowedBrands.isNotEmpty) {
        // Check if there are allowed brands not in current team's categories
        final ownCatNames = cats.map((c) => c.name).toSet();
        final crossBrands = allowedBrands.where((b) => !ownCatNames.contains(b)).toList();
        if (crossBrands.isNotEmpty) {
          // Fetch cross-team categories
          final crossResp = await SupabaseService.instance.client
              .from('product_categories')
              .select()
              .inFilter('name', crossBrands)
              .eq('is_active', true);
          final crossCats = (crossResp as List)
              .map((e) => ProductCategoryModel.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          cats = [...cats, ...crossCats];
        }
      }

      if (!mounted) return;

      // Filter category models by allowed brands if configured
      final visibleCats = allowedBrands.isEmpty
          ? cats
          : cats.where((c) => allowedBrands.contains(c.name)).toList();

      setState(() {
        _categoryModels = cats;
        _categories = ['All', ...cats.map((c) => c.name)];
        _allowedBrands = allowedBrands;
        _showStock = showStock;
      });

      if (visibleCats.isNotEmpty) {
        final first = visibleCats.first;
        setState(() {
          _selectedCategory = first.name;
          _selectedCategoryName = first.name;
        });
        await _loadCategoryProducts(first.name, initial: true);
        if (first.id.isNotEmpty) _loadSubcategories(first.id);
      } else {
        // All or no categories — show all allowed products
        setState(() {
          _selectedCategory = 'All';
          _selectedCategoryName = null;
        });
        await _loadAllProducts(initial: true);
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  // ─── Load products for a category ───
  Future<void> _loadCategoryProducts(String categoryId,
      {bool initial = false, bool forceRefresh = false}) async {
    setState(() {
      _error = null;
      if (initial) {
        _isLoading = true;
      } else {
        _isCategoryLoading = true;
      }
    });
    try {
      // Detect cross-team category and pass correct team_id
      final catModel = _categoryModels.where((c) => c.name == categoryId).firstOrNull;
      final teamId = catModel?.teamId;
      final models =
          await SupabaseService.instance.getProductsByCategory(categoryId, forceRefresh: forceRefresh, teamId: teamId);
      if (!mounted) return;
      final products = models.map((m) => Product.fromModel(m)).toList();
      products
          .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _allCategoryProductModels = models;
        _displayedProducts = products;
        _isLoading = false;
        _isCategoryLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
          _isCategoryLoading = false;
        });
      }
    }
  }

  // ─── Load subcategories for current category ───
  Future<void> _loadSubcategories(String categoryId) async {
    try {
      final subs = await SupabaseService.instance.getSubcategories(categoryId);
      debugPrint('📋 Subcategories loaded: ${subs.length} for category $categoryId');
      if (!mounted) return;
      setState(() {
        _subcategories = subs;
        _selectedSubcategoryId = null;
      });
    } catch (e) {
      debugPrint('❌ Error loading subcategories: $e');
      if (mounted) setState(() => _subcategories = []);
    }
  }

  // ─── Subcategory selection — local filter ───
  void _onSubcategorySelected(String? subcatId) {
    setState(() => _selectedSubcategoryId = subcatId);
    if (subcatId == null) {
      final all = _allCategoryProductModels.map((m) => Product.fromModel(m)).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() => _displayedProducts = all);
    } else {
      final filtered = _allCategoryProductModels
          .where((m) => m.subcategoryId == subcatId)
          .map((m) => Product.fromModel(m))
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() => _displayedProducts = filtered);
    }
  }

  // ─── Load ALL products (for 'All' category / refresh) ───
  Future<void> _loadAllProducts({bool initial = false, bool forceRefresh = false}) async {
    setState(() {
      _error = null;
      if (initial) {
        _isLoading = true;
      } else {
        _isCategoryLoading = true;
      }
    });
    try {
      var models = await SupabaseService.instance.getProducts(forceRefresh: forceRefresh);

      // If allowed brands include cross-team categories, fetch those products too
      if (_allowedBrands.isNotEmpty) {
        final ownCatNames = (await SupabaseService.instance.getProductCategories()).map((c) => c.name).toSet();
        final crossBrands = _allowedBrands.where((b) => !ownCatNames.contains(b)).toList();
        if (crossBrands.isNotEmpty) {
          final crossProducts = await SupabaseService.instance.client
              .from('products')
              .select()
              .inFilter('category', crossBrands)
              .order('name');
          final crossModels = (crossProducts as List)
              .map((e) => ProductModel.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          models = [...models, ...crossModels];
        }
      }

      if (!mounted) return;
      var products = models.map((m) => Product.fromModel(m)).toList();

      // Filter by allowed brands if brand access is configured
      if (_allowedBrands.isNotEmpty) {
        products = products.where((p) => _allowedBrands.contains(p.category)).toList();
      }

      // Apply smart sorting for "All" category
      final sortedProducts = await _applySmartSorting(products);
      
      setState(() {
        _allProducts = sortedProducts;
        _displayedProducts = sortedProducts;
        _isLoading = false;
        _isCategoryLoading = false;
        _lastSynced = DateTime.now();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
          _isCategoryLoading = false;
        });
      }
    }
  }

  // ─── Category chip selection ───
  void _onCategorySelected(String cat) {
    if (cat == _selectedCategory) return;
    // Clear search and subcategory when switching category
    _debounce?.cancel();
    setState(() {
      _selectedCategory = cat;
      _searchQuery = '';
      _debouncedQuery = '';
      _searchResults = [];
      _searchPage = 0;
      _error = null;
      _subcategories = [];
      _selectedSubcategoryId = null;
      _allCategoryProductModels = [];
    });

    if (cat == 'All') {
      _selectedCategoryName = null;
      _loadAllProducts();
    } else {
      final matches = _categoryModels.where((c) => c.name == cat);
      if (matches.isNotEmpty) {
        final catModel = matches.first;
        _selectedCategoryName = catModel.name; // products.category matches by name
        _loadCategoryProducts(catModel.name);
        if (catModel.id.isNotEmpty) _loadSubcategories(catModel.id);
      }
    }
  }

  // ─── Search ───
  Future<void> _performSearch(String query, {bool append = false}) async {
    if (!append) {
      setState(() {
        _isSearchLoading = true;
        _searchPage = 0;
        _hasMoreSearchResults = true;
        _searchResults = [];
      });
    } else {
      setState(() => _isLoadingMoreSearch = true);
    }

    try {
      final models = await SupabaseService.instance
          .searchProducts(query, page: _searchPage);
      if (!mounted) return;
      final products = models.map((m) => Product.fromModel(m)).toList();
      setState(() {
        if (append) {
          _searchResults = [..._searchResults, ...products];
        } else {
          _searchResults = products;
        }
        _isSearchLoading = false;
        _isLoadingMoreSearch = false;
        _hasMoreSearchResults = products.length == 50;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSearchLoading = false;
          _isLoadingMoreSearch = false;
        });
      }
    }
  }

  // ─── Pull-to-refresh ───
  Future<void> _onRefresh() async {
    setState(() => _showSyncBanner = true);
    try {
      // Clear all cached data (except photos) and re-fetch fresh
      await SupabaseService.instance.fullRefreshForSalesRep();

      // Re-load everything from scratch
      await _loadCategoriesAndAutoSelect();
      if (!mounted) return;
      setState(() => _lastSynced = DateTime.now());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final catalogName = AuthService.currentTeam == 'JA'
        ? 'JAGANNATH Catalog'
        : 'MADHAV Catalog';

    final bannerSkuCount = _allProducts.isNotEmpty
        ? _allProducts.length
        : _displayedProducts.length;

    final showSidebar = !_isLoading &&
        _error == null &&
        !_isSearchMode &&
        _subcategories.isNotEmpty;

    return Scaffold(
            backgroundColor: AppTheme.background,
            body: SafeArea(
              child: Stack(
                children: [
                  RefreshIndicator(
                    onRefresh: _onRefresh,
                    color: AppTheme.primary,
                    child: CustomScrollView(
                      controller: _scrollController,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      slivers: [
                    SliverAppBar(
                      expandedHeight: 60,
                      pinned: false,
                      backgroundColor: AppTheme.surface,
                      elevation: 0,
                      centerTitle: true,
                      leading: _preSelectedCustomer != null
                          ? IconButton(
                              icon: const Icon(
                                  Icons.arrow_back_ios_new_rounded),
                              onPressed: () => Navigator.pop(context))
                          : null,
                      title: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Product Catalog',
                              style: GoogleFonts.manrope(
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.onSurface,
                                  fontSize: 18)),
                          Text(catalogName,
                              style: GoogleFonts.manrope(
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.primary,
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                    if (_showSyncBanner)
                      SliverToBoxAdapter(
                          child: SyncStatusBannerWidget(
                              lastSynced: _lastSynced ?? DateTime.now(),
                              skuCount: bannerSkuCount,
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
                                      setState(() => _searchQuery = val);
                                      _debounce?.cancel();
                                      _debounce = Timer(
                                          const Duration(milliseconds: 300),
                                          () {
                                        setState(
                                            () => _debouncedQuery = val);
                                        if (val.length >= 3) {
                                          _performSearch(val);
                                        } else {
                                          setState(() {
                                            _searchResults = [];
                                            _searchPage = 0;
                                          });
                                        }
                                      });
                                    },
                                    onClear: () {
                                      _debounce?.cancel();
                                      setState(() {
                                        _searchQuery = '';
                                        _debouncedQuery = '';
                                        _searchResults = [];
                                        _searchPage = 0;
                                      });
                                    }),
                              ),
                              CategoryFilterChipsWidget(
                                  categories: _categories,
                                  selected: _selectedCategory,
                                  onSelected: _onCategorySelected,
                                  allowedBrands: _allowedBrands), // ADDED: brand access filter
                            ],
                          ),
                        ),
                      ),
                    ),

                    // ─── Content area ───
                    if (_isLoading)
                      const SliverToBoxAdapter(
                          child: Padding(
                              padding: EdgeInsets.all(40),
                              child: Center(
                                  child: CircularProgressIndicator())))
                    else if (_error != null)
                      SliverToBoxAdapter(
                          child: Padding(
                              padding: const EdgeInsets.all(40),
                              child: Center(
                                  child: Column(children: [
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
                              ]))))

                    // ─── Search mode ───
                    else if (_isSearchMode) ...[
                      if (_isSearchLoading)
                        const SliverToBoxAdapter(
                            child: Padding(
                                padding: EdgeInsets.all(40),
                                child: Center(
                                    child: CircularProgressIndicator())))
                      else if (_searchResults.isEmpty)
                        SliverToBoxAdapter(
                            child: Padding(
                                padding: const EdgeInsets.all(40),
                                child: Center(
                                    child: Text(
                                        'No results for "$_debouncedQuery"',
                                        style: GoogleFonts.manrope(
                                            color:
                                                AppTheme.onSurfaceVariant)))))
                      else ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Text(
                              'Search results for "$_debouncedQuery"',
                              style: GoogleFonts.manrope(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.onSurfaceVariant),
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding:
                              const EdgeInsets.fromLTRB(16, 4, 16, 100),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                // CHANGED: filter out zero-stock products
                                final p = _inStockSearchResults[index];
                                return ProductListItemWidget(
                                  product: p,
                                  showStock: _showStock, // ADDED
                                  onAddToCart: (qty) => CartService.instance
                                      .addOrUpdateItem(p, qty),
                                  onRemoveFromCart: () =>
                                      CartService.instance.removeItem(p),
                                );
                              },
                              childCount: _inStockSearchResults.length, // CHANGED
                            ),
                          ),
                        ),
                        if (_isLoadingMoreSearch)
                          const SliverToBoxAdapter(
                              child: Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  child: Center(
                                      child:
                                          CircularProgressIndicator()))),
                      ],
                    ]

                    // ─── Category mode ───
                    else ...[
                      if (_isCategoryLoading) ...[
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ] else if (_inStockDisplayed.isEmpty) ...[  // CHANGED: use filtered list
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Text('No products found',
                                style: GoogleFonts.manrope(
                                    color: AppTheme.onSurfaceVariant))),
                        ),
                      ] else ...[
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            showSidebar ? 80.0 : 16.0, 10, 16, 100),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                // CHANGED: filter out zero-stock products
                                final p = _inStockDisplayed[index];
                                return ProductListItemWidget(
                                  product: p,
                                  showStock: _showStock, // ADDED
                                  onAddToCart: (qty) => CartService
                                      .instance
                                      .addOrUpdateItem(p, qty),
                                  onRemoveFromCart: () =>
                                      CartService.instance.removeItem(p),
                                );
                              },
                              childCount: _inStockDisplayed.length, // CHANGED
                            ),
                          ),
                        ),
                      ],
                    ],
                      ],
                    ),
                  ),
                  if (showSidebar)
                    AnimatedBuilder(
                      animation: _scrollController,
                      builder: (context, child) {
                        final offset = _scrollController.hasClients
                            ? _scrollController.offset
                            : 0.0;
                        final appBarHeight =
                            (130.0 - offset).clamp(0.0, 130.0);
                        return Positioned(
                          left: 0,
                          top: appBarHeight + 139.0,
                          bottom: 0,
                          width: 76,
                          child: child!,
                        );
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppTheme.background,
                          border: Border(
                            right: BorderSide(color: Colors.grey.shade200),
                          ),
                        ),
                        child: _SubcategorySidebar(
                          subcategories: _subcategories,
                          selectedId: _selectedSubcategoryId,
                          onSelected: _onSubcategorySelected,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            floatingActionButton: ValueListenableBuilder<List<CartItem>>(
              valueListenable: CartService.instance.cartNotifier,
              builder: (context, cartItems, _) => CartFabWidget(
                itemCount: cartItems.fold(0, (sum, item) => sum + item.quantity),
                cartTotal: cartItems.fold(
                    0.0,
                    (sum, item) =>
                        sum + item.product.unitPrice * item.quantity),
                onTap: () =>
                    Navigator.pushNamed(context, AppRoutes.orderCreationScreen),
              ),
            ),
          );
  }
}

// ─── Subcategory Sidebar ─────────────────────────────────────────────────────

class _SubcategorySidebar extends StatelessWidget {
  final List<ProductSubcategoryModel> subcategories;
  final String? selectedId;
  final ValueChanged<String?> onSelected;

  const _SubcategorySidebar({
    required this.subcategories,
    required this.selectedId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: subcategories.length + 1, // +1 for "All"
        itemBuilder: (_, i) {
          if (i == 0) {
            return _SidebarButton(
              label: 'All',
              isSelected: selectedId == null,
              onTap: () => onSelected(null),
            );
          }
          final sub = subcategories[i - 1];
          return _SidebarButton(
            label: sub.name,
            isSelected: selectedId == sub.id,
            onTap: () => onSelected(sub.id),
          );
        },
      ),
    );
  }
}

class _SidebarButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarButton({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 5),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppTheme.primary : Colors.grey.shade200,
            width: 1,
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 3,
              softWrap: true,
              style: GoogleFonts.manrope(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? Colors.white : AppTheme.onSurfaceVariant,
                height: 1.3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  _StickyHeaderDelegate({required this.child});

  @override
  Widget build(context, double shrinkOffset, bool overlapsContent) => child;

  @override
  double get maxExtent => 139.0;

  @override
  double get minExtent => 139.0;

  @override
  bool shouldRebuild(_StickyHeaderDelegate oldDelegate) => true;
}

