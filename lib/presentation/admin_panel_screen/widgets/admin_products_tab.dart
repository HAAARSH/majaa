import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';
import './admin_shared_widgets.dart';
import './category_management_dialog.dart';
import './product_admin_card.dart';

// All 297 errors cascade from errors 1 & 2 (unresolvable package URIs); the import statements are already syntactically correct - run `flutter pub add google_fonts` and `flutter pub get` to resolve the missing packages, as no code changes are needed in this file. //

class AdminProductsTab extends StatefulWidget {
  const AdminProductsTab({super.key});

  @override
  State<AdminProductsTab> createState() => _AdminProductsTabState();
}

class _AdminProductsTabState extends State<AdminProductsTab> {
  bool _isLoading = true;
  List<ProductModel> _products = [];
  List<ProductCategoryModel> _categories = [];
  String? _error;

  bool _bulkMode = false;
  final Set<String> _selectedIds = {};

  String _filterCategory = 'All';
  String _filterStatus = 'All';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final products = await SupabaseService.instance.getProducts();
      final categories =
          await SupabaseService.instance.getAllProductCategories();
      if (!mounted) return;
      setState(() {
        _products = products;
        _categories = categories;
        _isLoading = false;
        _selectedIds.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  List<ProductModel> get _filteredProducts {
    return _products.where((p) {
      final catMatch =
          _filterCategory == 'All' || p.category == _filterCategory;
      final statusMatch = _filterStatus == 'All' || p.status == _filterStatus;
      return catMatch && statusMatch;
    }).toList();
  }

  void _toggleBulkMode() {
    setState(() {
      _bulkMode = !_bulkMode;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _selectAll() {
    setState(() {
      if (_selectedIds.length == _filteredProducts.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(_filteredProducts.map((p) => p.id));
      }
    });
  }

  void _showBulkEditDialog() {
    if (_selectedIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Select at least one product',
            style: GoogleFonts.manrope(),
          ),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    String? bulkStatus;
    String? bulkCategory;
    final priceCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Bulk Edit',
                style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
              ),
              Text(
                '${_selectedIds.length} product(s) selected',
                style: GoogleFonts.manrope(
                  fontSize: 12,
                  color: AppTheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Leave fields blank to keep existing values',
                  style: GoogleFonts.manrope(
                    fontSize: 11,
                    color: AppTheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Stock Status',
                  style: GoogleFonts.manrope(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: ['available', 'outOfStock', 'discontinued'].map((
                    s,
                  ) {
                    final isSelected = bulkStatus == s;
                    return ChoiceChip(
                      label: Text(
                        s == 'outOfStock'
                            ? 'Out of Stock'
                            : s == 'discontinued'
                                ? 'Discontinued'
                                : 'Available',
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          color: isSelected ? Colors.white : AppTheme.onSurface,
                        ),
                      ),
                      selected: isSelected,
                      selectedColor: s == 'available'
                          ? AppTheme.success
                          : s == 'outOfStock'
                              ? AppTheme.error
                              : AppTheme.onSurfaceVariant,
                      onSelected: (_) => setDialogState(
                        () => bulkStatus = isSelected ? null : s,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                Text(
                  'Category',
                  style: GoogleFonts.manrope(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: bulkCategory,
                  decoration: InputDecoration(
                    hintText: 'Keep existing',
                    hintStyle: GoogleFonts.manrope(fontSize: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(
                        'Keep existing',
                        style: GoogleFonts.manrope(fontSize: 12),
                      ),
                    ),
                    ..._categories.map(
                      (c) => DropdownMenuItem(
                        value: c.name,
                        child: Text(
                          c.name,
                          style: GoogleFonts.manrope(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                  onChanged: (v) => setDialogState(() => bulkCategory = v),
                ),
                const SizedBox(height: 12),
                Text(
                  'Set Price (overwrite)',
                  style: GoogleFonts.manrope(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: priceCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: GoogleFonts.manrope(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Leave blank to keep',
                    hintStyle: GoogleFonts.manrope(fontSize: 12),
                    prefixText: '₹ ',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: GoogleFonts.manrope()),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () async {
                Navigator.pop(ctx);
                final newPrice = double.tryParse(priceCtrl.text.trim());
                try {
                  final selectedProducts = _products
                      .where((p) => _selectedIds.contains(p.id))
                      .toList();
                  for (final p in selectedProducts) {
                    final updated = ProductModel(
                      id: p.id,
                      name: p.name,
                      sku: p.sku,
                      category: bulkCategory ?? p.category,
                      brand: p.brand,
                      unitPrice: newPrice ?? p.unitPrice,
                      packSize: p.packSize,
                      status: bulkStatus ?? p.status,
                      stockQty: p.stockQty,
                      imageUrl: p.imageUrl,
                      semanticLabel: p.semanticLabel,
                    );
                    await SupabaseService.instance.upsertProduct(updated);
                  }
                  _load();
                  setState(() {
                    _bulkMode = false;
                    _selectedIds.clear();
                  });
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '${selectedProducts.length} products updated',
                          style: GoogleFonts.manrope(),
                        ),
                        backgroundColor: AppTheme.success,
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Error: $e',
                          style: GoogleFonts.manrope(),
                        ),
                        backgroundColor: AppTheme.error,
                      ),
                    );
                  }
                }
              },
              child: Text(
                'Apply to ${_selectedIds.length}',
                style: GoogleFonts.manrope(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showCategoryManagementDialog() {
    showDialog(
      context: context,
      builder: (ctx) => CategoryManagementDialog(
        categories: List.from(_categories),
        onChanged: _load,
      ),
    );
  }

  void _showEditDialog(ProductModel? product) {
    final nameCtrl = TextEditingController(text: product?.name ?? '');
    final skuCtrl = TextEditingController(text: product?.sku ?? '');
    final priceCtrl = TextEditingController(
      text: product?.unitPrice.toString() ?? '',
    );
    final brandCtrl = TextEditingController(text: product?.brand ?? '');
    final packCtrl = TextEditingController(text: product?.packSize ?? '');
    final stockCtrl = TextEditingController(
      text: product?.stockQty.toString() ?? '0',
    );
    String status = product?.status ?? 'available';
    String? selectedCategory =
        _categories.any((c) => c.name == product?.category)
            ? product?.category
            : null;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            product == null ? 'Add Product' : 'Edit Product',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                buildAdminTextField('Product Name', nameCtrl),
                const SizedBox(height: 10),
                buildAdminTextField('SKU', skuCtrl),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: selectedCategory,
                  decoration: InputDecoration(
                    labelText: 'Category',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                  items: _categories
                      .map(
                        (c) => DropdownMenuItem(
                          value: c.name,
                          child: Text(
                            c.name,
                            style: GoogleFonts.manrope(fontSize: 13),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setDialogState(() => selectedCategory = v),
                ),
                const SizedBox(height: 10),
                buildAdminTextField('Brand', brandCtrl),
                const SizedBox(height: 10),
                buildAdminTextField(
                  'Unit Price',
                  priceCtrl,
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 10),
                buildAdminTextField('Pack Size', packCtrl),
                const SizedBox(height: 10),
                buildAdminTextField(
                  'Stock Qty',
                  stockCtrl,
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Stock Status',
                      style: GoogleFonts.manrope(
                        fontSize: 12,
                        color: AppTheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: ['available', 'outOfStock', 'discontinued'].map(
                        (s) {
                          final isSelected = status == s;
                          return ChoiceChip(
                            label: Text(
                              s == 'outOfStock'
                                  ? 'Out of Stock'
                                  : s == 'discontinued'
                                      ? 'Discontinued'
                                      : 'Available',
                              style: GoogleFonts.manrope(
                                fontSize: 11,
                                color: isSelected
                                    ? Colors.white
                                    : AppTheme.onSurface,
                              ),
                            ),
                            selected: isSelected,
                            selectedColor: s == 'available'
                                ? AppTheme.success
                                : s == 'outOfStock'
                                    ? AppTheme.error
                                    : AppTheme.onSurfaceVariant,
                            onSelected: (_) => setDialogState(() => status = s),
                          );
                        },
                      ).toList(),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: GoogleFonts.manrope()),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  final updated = ProductModel(
                    id: product?.id ?? '',
                    name: nameCtrl.text.trim(),
                    sku: skuCtrl.text.trim(),
                    category: selectedCategory ?? nameCtrl.text.trim(),
                    brand: brandCtrl.text.trim(),
                    unitPrice: double.tryParse(priceCtrl.text.trim()) ?? 0.0,
                    packSize: packCtrl.text.trim(),
                    status: status,
                    stockQty: int.tryParse(stockCtrl.text.trim()) ?? 0,
                    imageUrl: product?.imageUrl ?? '',
                    semanticLabel: product?.semanticLabel ?? '',
                  );
                  await SupabaseService.instance.upsertProduct(updated);
                  _load();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Product saved',
                          style: GoogleFonts.manrope(),
                        ),
                        backgroundColor: AppTheme.success,
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Error: $e',
                          style: GoogleFonts.manrope(),
                        ),
                        backgroundColor: AppTheme.error,
                      ),
                    );
                  }
                }
              },
              child: Text(
                'Save',
                style: GoogleFonts.manrope(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _quickToggleStatus(ProductModel p) async {
    final nextStatus = p.status == 'available' ? 'outOfStock' : 'available';
    try {
      final updated = ProductModel(
        id: p.id,
        name: p.name,
        sku: p.sku,
        category: p.category,
        brand: p.brand,
        unitPrice: p.unitPrice,
        packSize: p.packSize,
        status: nextStatus,
        stockQty: p.stockQty,
        imageUrl: p.imageUrl,
        semanticLabel: p.semanticLabel,
      );
      await SupabaseService.instance.upsertProduct(updated);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e', style: GoogleFonts.manrope()),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return AdminErrorRetry(message: _error!, onRetry: _load);
    }

    final filtered = _filteredProducts;
    final allCategoryNames = ['All', ..._categories.map((c) => c.name)];

    return Scaffold(
      backgroundColor: AppTheme.background,
      floatingActionButton: _bulkMode
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_rounded),
              label: Text(
                'Add Product',
                style: GoogleFonts.manrope(fontSize: 13),
              ),
              onPressed: () => _showEditDialog(null),
            ),
      body: Column(
        children: [
          Container(
            color: AppTheme.surface,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 32,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: allCategoryNames.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 6),
                          itemBuilder: (_, i) {
                            final cat = allCategoryNames[i];
                            final isSelected = _filterCategory == cat;
                            return GestureDetector(
                              onTap: () =>
                                  setState(() => _filterCategory = cat),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? AppTheme.primary
                                      : AppTheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  cat,
                                  style: GoogleFonts.manrope(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: isSelected
                                        ? Colors.white
                                        : AppTheme.primary,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _showCategoryManagementDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.category_rounded,
                              size: 14,
                              color: AppTheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Manage',
                              style: GoogleFonts.manrope(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    // THIS IS THE FIX: Added Expanded & SingleChildScrollView
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            'All',
                            'available',
                            'lowStock',
                            'outOfStock',
                            'discontinued',
                          ].map((s) {
                            final isSelected = _filterStatus == s;
                            Color chipColor = AppTheme.primary;
                            if (s == 'available') {
                              chipColor = AppTheme.success;
                            }
                            if (s == 'lowStock') {
                              chipColor = AppTheme.warning;
                            }
                            if (s == 'outOfStock') {
                              chipColor = AppTheme.error;
                            }
                            if (s == 'discontinued') {
                              chipColor = AppTheme.onSurfaceVariant;
                            }
                            return Padding(
                              padding: const EdgeInsets.only(right: 6.0),
                              child: GestureDetector(
                                onTap: () => setState(() => _filterStatus = s),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? chipColor
                                        : chipColor.withAlpha(20),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    s == 'All'
                                        ? 'All Status'
                                        : s == 'outOfStock'
                                            ? 'Out of Stock'
                                            : s == 'lowStock'
                                                ? 'Low Stock'
                                                : s == 'discontinued'
                                                    ? 'Discontinued'
                                                    : 'Available',
                                    style: GoogleFonts.manrope(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color:
                                          isSelected ? Colors.white : chipColor,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _toggleBulkMode,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: _bulkMode
                              ? AppTheme.primary
                              : AppTheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.checklist_rounded,
                              size: 14,
                              color:
                                  _bulkMode ? Colors.white : AppTheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Bulk',
                              style: GoogleFonts.manrope(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color:
                                    _bulkMode ? Colors.white : AppTheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_bulkMode)
            Container(
              color: AppTheme.primary.withAlpha(15),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: _selectAll,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _selectedIds.length == filtered.length &&
                                  filtered.isNotEmpty
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 18,
                          color: AppTheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Select All',
                          style: GoogleFonts.manrope(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${_selectedIds.length} selected',
                    style: GoogleFonts.manrope(
                      fontSize: 12,
                      color: AppTheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: const Icon(Icons.edit_rounded, size: 14),
                    label: Text(
                      'Edit Selected',
                      style: GoogleFonts.manrope(fontSize: 12),
                    ),
                    onPressed: _showBulkEditDialog,
                  ),
                ],
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              color: AppTheme.primary,
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No products found',
                        style: GoogleFonts.manrope(
                          color: AppTheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final p = filtered[index];
                        final isSelected = _selectedIds.contains(p.id);
                        return ProductAdminCard(
                          product: p,
                          bulkMode: _bulkMode,
                          isSelected: isSelected,
                          onToggleSelect: () => _toggleSelect(p.id),
                          onEdit: () => _showEditDialog(p),
                          onToggleStatus: () => _quickToggleStatus(p),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
