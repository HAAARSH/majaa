import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';
import 'category_management_dialog.dart';

class AdminProductsTab extends StatefulWidget {
  final bool isSuperAdmin;
  const AdminProductsTab({super.key, this.isSuperAdmin = false});

  @override
  State<AdminProductsTab> createState() => _AdminProductsTabState();
}

class _AdminProductsTabState extends State<AdminProductsTab>
    with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  List<ProductModel> _products = [];
  List<ProductModel> _filtered = [];
  final TextEditingController _searchController = TextEditingController();
  String _selectedCategory = 'All';
  List<String> _categories = ['All'];
  List<ProductCategoryModel> _categoryModels = [];

  // Subcategory state
  List<ProductSubcategoryModel> _allSubcategories = [];

  // Pagination
  int _displayLimit = 200;

  // Multi-select state
  bool _isSelectMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _loadCategories();
    _loadProducts();
    _loadAllSubcategories();
    _searchController.addListener(_onSearch);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    try {
      final cats = await SupabaseService.instance.getProductCategories();
      if (!mounted) return;
      setState(() {
        _categoryModels = cats;
        _categories = ['All', ...cats.map((c) => c.name)];
      });
    } catch (e) {
      debugPrint('_loadCategories error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load categories: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Future<void> _loadAllSubcategories() async {
    try {
      final subs = await SupabaseService.instance.getAllSubcategoriesForTeam();
      if (!mounted) return;
      setState(() => _allSubcategories = subs);
    } catch (e) {
      debugPrint('_loadAllSubcategories error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load subcategories: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Future<void> _loadProducts({bool forceRefresh = false}) async {
    setState(() => _isLoading = true);
    try {
      final products = await SupabaseService.instance.getProducts(forceRefresh: forceRefresh);
      products.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (mounted) {
        setState(() {
          _products = products;
          _filtered = products;
          _isLoading = false;
        });
        _applyFilters();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load products: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  void _onSearch() => _applyFilters();

  void _applyFilters() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _displayLimit = 500;
      _filtered = _products.where((p) {
        final matchesSearch = p.name.toLowerCase().contains(query);
        final matchesCat = _selectedCategory == 'All' ||
            (p.categoryName) == _selectedCategory;
        return matchesSearch && matchesCat;
      }).toList();
    });
  }

  void _enterSelectMode(String productId) {
    setState(() {
      _isSelectMode = true;
      _selectedIds.add(productId);
    });
  }

  void _exitSelectMode() {
    setState(() {
      _isSelectMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String productId) {
    setState(() {
      if (_selectedIds.contains(productId)) {
        _selectedIds.remove(productId);
        if (_selectedIds.isEmpty) _isSelectMode = false;
      } else {
        _selectedIds.add(productId);
      }
    });
  }

  void _showBulkStockUpdate() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Update Stock for ${_selectedIds.length} product${_selectedIds.length == 1 ? '' : 's'}',
          style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 15),
        ),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'New Stock Quantity',
            prefixIcon: const Icon(Icons.warehouse_outlined),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              final qty = int.tryParse(ctrl.text.trim());
              if (qty == null) return;
              Navigator.pop(ctx);
              try {
                for (final id in _selectedIds) {
                  await SupabaseService.instance.updateProduct(id, {'stock_qty': qty});
                }
                _exitSelectMode();
                _loadProducts(forceRefresh: true);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Stock updated to $qty for ${_selectedIds.length} product(s)'),
                    backgroundColor: AppTheme.success,
                  ));
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Error: $e'),
                    backgroundColor: AppTheme.error,
                  ));
                }
              }
            },
            child: Text('Update', style: GoogleFonts.manrope(color: Colors.white)),
          ),
        ],
      ),
    ).then((_) => ctrl.dispose());
  }

  // ── Stock badge ──────────────────────────────────────────────
  Color _stockColor(int qty) {
    if (qty <= 0) return Colors.red.shade600;
    if (qty <= 10) return Colors.orange.shade600;
    return Colors.green.shade600;
  }

  String _stockLabel(int qty) {
    if (qty <= 0) return 'Out of Stock';
    if (qty <= 10) return 'Low Stock';
    return 'In Stock';
  }

  IconData _stockIcon(int qty) {
    if (qty <= 0) return Icons.remove_shopping_cart_outlined;
    if (qty <= 10) return Icons.warning_amber_rounded;
    return Icons.check_circle_outline;
  }

  // ── Delete Product ───────────────────────────────────────────
  void _confirmDeleteProduct(ProductModel product) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete Product', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Text('Delete "${product.name}"?\n\nThis cannot be undone.',
            style: GoogleFonts.manrope(fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.manrope(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await SupabaseService.instance.deleteProduct(product.id);
                if (!mounted) return;
                setState(() {
                  _products.removeWhere((p) => p.id == product.id);
                  _filtered.removeWhere((p) => p.id == product.id);
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Product deleted'), backgroundColor: Colors.green),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                );
              }
            },
            child: Text('Delete', style: GoogleFonts.manrope(color: Colors.red, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  // ── Bottom Sheet: Add / Edit ─────────────────────────────────
  void _openProductSheet({ProductModel? existing}) {
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final billingNameCtrl = TextEditingController(text: existing?.billingName ?? '');
    final printNameCtrl = TextEditingController(text: existing?.printName ?? '');
    final priceCtrl = TextEditingController(
        text: existing != null ? existing.unitPrice.toString() : '');
    final mrpCtrl = TextEditingController(
        text: existing != null && existing.mrp > 0 ? existing.mrp.toString() : '');
    final stockCtrl = TextEditingController(
        text: existing != null ? existing.stockQty.toString() : '');
    final stepSizeCtrl = TextEditingController(
        text: existing != null ? existing.stepSize.toString() : '1');
    // Pre-select the existing category if it matches a known one
    String? selectedCategoryName = _categoryModels
        .where((c) => c.name == (existing?.categoryName ?? ''))
        .map((c) => c.name)
        .firstOrNull;
    // Pre-select existing subcategory
    String? selectedSubcategoryId = existing?.subcategoryId;
    final formKey = GlobalKey<FormState>();
    bool saving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheet) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.85,
              ),
              decoration: BoxDecoration(
                color: Theme.of(ctx).scaffoldBackgroundColor,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            isEdit
                                ? Icons.edit_rounded
                                : Icons.add_box_rounded,
                            color: AppTheme.primary,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          isEdit ? 'Edit Product' : 'Add New Product',
                          style: GoogleFonts.manrope(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _buildField(nameCtrl, 'App Display Name', Icons.inventory_2_outlined,
                        validator: (v) =>
                            v == null || v.isEmpty ? 'Required' : null),
                    const SizedBox(height: 14),
                    _buildField(billingNameCtrl, 'Billing Software Name', Icons.receipt_long_rounded),
                    const SizedBox(height: 14),
                    _buildField(printNameCtrl, 'Print Name (Invoice)', Icons.print_rounded),
                    const SizedBox(height: 14),
                    // Category dropdown sourced from product_categories table
                    DropdownButtonFormField<String>(
                      initialValue: selectedCategoryName,
                      decoration: InputDecoration(
                        labelText: 'Category',
                        labelStyle: GoogleFonts.manrope(
                            fontSize: 13, color: Colors.grey.shade600),
                        prefixIcon: Icon(Icons.category_outlined,
                            size: 18, color: AppTheme.primary),
                        filled: true,
                        fillColor: AppTheme.primary.withOpacity(0.04),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide:
                              BorderSide(color: AppTheme.primary, width: 1.5),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                      ),
                      style: GoogleFonts.manrope(
                          fontSize: 14, color: Colors.black87),
                      items: _categoryModels
                          .map((c) => DropdownMenuItem(
                                value: c.name,
                                child: Text(c.name,
                                    style: GoogleFonts.manrope(fontSize: 14)),
                              ))
                          .toList(),
                      onChanged: (val) {
                        selectedCategoryName = val;
                        selectedSubcategoryId = null; // reset subcategory when category changes
                        setSheet(() {});
                      },
                      validator: (v) =>
                          v == null || v.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 14),
                    // Subcategory dropdown (optional, depends on selected category)
                    Builder(builder: (ctx) {
                      final catModel = _categoryModels
                          .where((c) => c.name == selectedCategoryName)
                          .firstOrNull;
                      final subcats = catModel != null
                          ? _allSubcategories
                              .where((s) => s.categoryId == catModel.id)
                              .toList()
                          : <ProductSubcategoryModel>[];
                      if (subcats.isEmpty) return const SizedBox.shrink();
                      return Column(
                        children: [
                          DropdownButtonFormField<String?>(
                            value: subcats.any((s) => s.id == selectedSubcategoryId)
                                ? selectedSubcategoryId
                                : null,
                            decoration: InputDecoration(
                              labelText: 'Subcategory (optional)',
                              labelStyle: GoogleFonts.manrope(
                                  fontSize: 13, color: Colors.grey.shade600),
                              prefixIcon: Icon(Icons.label_outline,
                                  size: 18, color: AppTheme.primary),
                              filled: true,
                              fillColor: AppTheme.primary.withOpacity(0.04),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                    color: AppTheme.primary, width: 1.5),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 14),
                            ),
                            style: GoogleFonts.manrope(
                                fontSize: 14, color: Colors.black87),
                            items: [
                              DropdownMenuItem<String?>(
                                value: null,
                                child: Text('— None —',
                                    style: GoogleFonts.manrope(
                                        fontSize: 14,
                                        color: Colors.grey.shade500)),
                              ),
                              ...subcats.map((s) => DropdownMenuItem<String?>(
                                    value: s.id,
                                    child: Text(s.name,
                                        style: GoogleFonts.manrope(fontSize: 14)),
                                  )),
                            ],
                            onChanged: (val) {
                              selectedSubcategoryId = val;
                              setSheet(() {});
                            },
                          ),
                          const SizedBox(height: 14),
                        ],
                      );
                    }),
                    Row(
                      children: [
                        Expanded(
                          child: _buildField(
                            priceCtrl,
                            'Unit Price (₹)',
                            Icons.currency_rupee_rounded,
                            keyboardType: TextInputType.number,
                            validator: (v) {
                              if (v == null || v.isEmpty) return 'Required';
                              if (double.tryParse(v) == null) return 'Invalid';
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildField(
                            mrpCtrl,
                            'MRP (₹)',
                            Icons.sell_outlined,
                            keyboardType: TextInputType.number,
                            validator: (v) {
                              if (v != null && v.isNotEmpty && double.tryParse(v) == null) return 'Invalid';
                              return null;
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: _buildField(
                            stockCtrl,
                            'Stock Qty',
                            Icons.warehouse_outlined,
                            keyboardType: TextInputType.number,
                            validator: (v) {
                              if (v == null || v.isEmpty) return 'Required';
                              if (int.tryParse(v) == null) return 'Invalid';
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildField(
                            stepSizeCtrl,
                            'Step Size',
                            Icons.linear_scale_rounded,
                            keyboardType: TextInputType.number,
                            validator: (v) {
                              if (v == null || v.isEmpty) return 'Required';
                              final n = int.tryParse(v);
                              if (n == null || n < 1) return 'Min 1';
                              return null;
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: saving
                            ? null
                            : () async {
                                if (!formKey.currentState!.validate()) return;
                                setSheet(() => saving = true);
                                // Capture contexts before async gap
                                final nav = Navigator.of(ctx);
                                final messenger = ScaffoldMessenger.of(ctx);
                                try {
                                  final data = {
                                    'name': nameCtrl.text.trim(),
                                    'billing_name': billingNameCtrl.text.trim().isEmpty ? nameCtrl.text.trim() : billingNameCtrl.text.trim(),
                                    'print_name': printNameCtrl.text.trim().isEmpty ? nameCtrl.text.trim() : printNameCtrl.text.trim(),
                                    'category': selectedCategoryName ?? '',
                                    'unit_price':
                                        double.parse(priceCtrl.text.trim()),
                                    'mrp': mrpCtrl.text.trim().isNotEmpty
                                        ? double.parse(mrpCtrl.text.trim())
                                        : 0,
                                    'stock_qty':
                                        int.parse(stockCtrl.text.trim()),
                                    'step_size':
                                        int.parse(stepSizeCtrl.text.trim()),
                                    'subcategory_id': selectedSubcategoryId,
                                  };
                                  if (isEdit) {
                                    await SupabaseService.instance
                                        .updateProduct(existing.id, data);
                                  } else {
                                    await SupabaseService.instance
                                        .addProduct(data);
                                  }
                                  nav.pop();
                                  // Wait for bottom sheet dismiss animation to complete
                                  // before updating parent state to avoid _dependents.isEmpty assertion
                                  await Future.delayed(const Duration(milliseconds: 300));
                                  if (!mounted) return;
                                  if (isEdit) {
                                    // Refresh only the edited product in-place
                                    final updated = await SupabaseService.instance.getProductById(existing.id);
                                    if (updated != null && mounted) {
                                      setState(() {
                                        final idx = _products.indexWhere((p) => p.id == existing.id);
                                        if (idx != -1) _products[idx] = updated;
                                        final fIdx = _filtered.indexWhere((p) => p.id == existing.id);
                                        if (fIdx != -1) _filtered[fIdx] = updated;
                                      });
                                    }
                                  } else {
                                    _loadProducts(forceRefresh: true);
                                  }
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(isEdit
                                          ? 'Product updated!'
                                          : 'Product added!'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                } catch (e) {
                                  setSheet(() => saving = false);
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text('Error: $e'),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 0,
                        ),
                        child: saving
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                ),
                              )
                            : Text(
                                isEdit ? 'Save Changes' : 'Add Product',
                                style: GoogleFonts.manrope(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
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
        });
      },
    ).then((_) {
      nameCtrl.dispose();
      billingNameCtrl.dispose();
      printNameCtrl.dispose();
      priceCtrl.dispose();
      mrpCtrl.dispose();
      stockCtrl.dispose();
      stepSizeCtrl.dispose();
    });
  }

  Widget _buildField(
    TextEditingController ctrl,
    String label,
    IconData icon, {
    TextInputType keyboardType = TextInputType.text,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: ctrl,
      keyboardType: keyboardType,
      validator: validator,
      style: GoogleFonts.manrope(fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:
            GoogleFonts.manrope(fontSize: 13, color: Colors.grey.shade600),
        prefixIcon: Icon(icon, size: 18, color: AppTheme.primary),
        filled: true,
        fillColor: AppTheme.primary.withOpacity(0.04),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppTheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.red, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }

  Widget _buildBulkBar() {
    return SafeArea(
      child: Container(
        color: AppTheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            GestureDetector(
              onTap: _exitSelectMode,
              child: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 8),
            Text(
              '${_selectedIds.length}',
              style: GoogleFonts.manrope(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const Spacer(),
            SizedBox(
              height: 34,
              child: ElevatedButton.icon(
                onPressed: _showBulkSubcategoryAssign,
                icon: const Icon(Icons.label_outline, size: 14),
                label: Text('Subcat', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppTheme.primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  elevation: 0,
                ),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              height: 34,
              child: ElevatedButton.icon(
                onPressed: _showBulkStockUpdate,
                icon: const Icon(Icons.edit_rounded, size: 14),
                label: Text('Stock', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppTheme.primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showBulkSubcategoryAssign() {
    String? selectedSubcatId;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            'Assign Subcategory to ${_selectedIds.length} product${_selectedIds.length == 1 ? '' : 's'}',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          content: DropdownButtonFormField<String?>(
            value: selectedSubcatId,
            decoration: InputDecoration(
              labelText: 'Subcategory',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            items: [
              DropdownMenuItem<String?>(
                value: null,
                child: Text('— None (unlink) —',
                    style: GoogleFonts.manrope(color: Colors.grey.shade500)),
              ),
              ..._allSubcategories.map((s) {
                final catName = _categoryModels
                    .where((c) => c.id == s.categoryId)
                    .map((c) => c.name)
                    .firstOrNull ?? '';
                return DropdownMenuItem<String?>(
                  value: s.id,
                  child: Text('$catName › ${s.name}',
                      style: GoogleFonts.manrope(fontSize: 14)),
                );
              }),
            ],
            onChanged: (val) => setDialog(() => selectedSubcatId = val),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: GoogleFonts.manrope()),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  for (final id in _selectedIds) {
                    await SupabaseService.instance
                        .updateProduct(id, {'subcategory_id': selectedSubcatId});
                  }
                  _exitSelectMode();
                  _loadProducts(forceRefresh: true);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(
                          'Subcategory updated for ${_selectedIds.length} product(s)'),
                      backgroundColor: AppTheme.success,
                    ));
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Error: $e'),
                      backgroundColor: AppTheme.error,
                    ));
                  }
                }
              },
              child: Text('Assign', style: GoogleFonts.manrope(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  void _showManageSubcategoriesSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ManageSubcategoriesSheet(
        categoryModels: _categoryModels,
        subcategories: _allSubcategories,
        onChanged: () async {
          await _loadAllSubcategories();
        },
      ),
    );
  }

  // ── Stock CSV Upload ─────────────────────────────────────────
  Future<void> _uploadStockCsv() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) return;

      // Read CSV content
      String csvString;
      if (kIsWeb) {
        csvString = utf8.decode(result.files.first.bytes!);
      } else {
        csvString = await File(result.files.first.path!).readAsString(encoding: latin1);
      }

      // Parse CSV
      final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
          .convert(csvString);
      if (rows.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('CSV file is empty'), backgroundColor: Colors.orange),
          );
        }
        return;
      }

      // Parse dBASE headers: "FIELDNAME,TYPE,SIZE" → extract FIELDNAME
      final rawHeaders = rows.first.map((h) {
        final s = h.toString().trim();
        // dBASE format: field name is before first comma inside quotes
        if (s.contains(',')) return s.split(',').first.trim();
        return s;
      }).toList();

      final itemNameIdx = rawHeaders.indexWhere(
          (h) => h.toString().toUpperCase() == 'ITEMNAME');
      final cfQtyIdx = rawHeaders.indexWhere(
          (h) => h.toString().toUpperCase() == 'CFQUANTITY');
      final mrpIdx = rawHeaders.indexWhere(
          (h) => h.toString().toUpperCase() == 'MRP');

      if (itemNameIdx < 0 || cfQtyIdx < 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('CSV missing required columns. Found: ${rawHeaders.join(", ")}'),
              backgroundColor: AppTheme.error,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      // Build lookup from products (by name and billing_name, case-insensitive)
      final Map<String, ProductModel> nameLookup = {};
      for (final p in _products) {
        nameLookup[p.name.toLowerCase().trim()] = p;
        if (p.billingName != null && p.billingName!.isNotEmpty) {
          nameLookup[p.billingName!.toLowerCase().trim()] = p;
        }
      }

      // First pass: collect all CSV rows per item name, pick highest stock
      final Map<String, _CsvRow> bestRows = {};
      for (int i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.length <= itemNameIdx || row.length <= cfQtyIdx) continue;

        final itemName = row[itemNameIdx].toString().trim();
        if (itemName.isEmpty) continue;

        final cfQtyRaw = row[cfQtyIdx].toString().trim();
        final cfQty = int.tryParse(cfQtyRaw.split('.').first) ?? 0;

        double? mrp;
        if (mrpIdx >= 0 && row.length > mrpIdx) {
          mrp = double.tryParse(row[mrpIdx].toString().trim());
        }

        final key = itemName.toLowerCase().trim();
        final existing = bestRows[key];
        if (existing == null || cfQty > existing.qty) {
          bestRows[key] = _CsvRow(itemName: itemName, qty: cfQty, mrp: mrp);
        }
      }

      // Second pass: match to products
      final List<_StockUpdate> updates = [];
      final List<String> unmatched = [];
      for (final entry in bestRows.entries) {
        final csvRow = entry.value;
        final product = nameLookup[entry.key];
        if (product != null) {
          final mrpChanged = csvRow.mrp != null && csvRow.mrp != product.unitPrice;
          if (product.stockQty != csvRow.qty || mrpChanged) {
            updates.add(_StockUpdate(
              product: product,
              csvName: csvRow.itemName,
              oldQty: product.stockQty,
              newQty: csvRow.qty,
              newMrp: mrpChanged ? csvRow.mrp : null,
            ));
          }
        } else {
          unmatched.add(csvRow.itemName);
        }
      }

      if (!mounted) return;

      // Show preview dialog
      _showStockPreviewDialog(updates, unmatched);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error reading CSV: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  void _showStockPreviewDialog(List<_StockUpdate> updates, List<String> unmatched) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.upload_file_rounded, color: AppTheme.primary, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Stock Update Preview',
                  style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(context).size.height * 0.45,
          child: DefaultTabController(
            length: 2,
            child: Column(
              children: [
                TabBar(
                  labelStyle: GoogleFonts.manrope(fontWeight: FontWeight.w600, fontSize: 12),
                  unselectedLabelStyle: GoogleFonts.manrope(fontSize: 12),
                  labelColor: AppTheme.primary,
                  unselectedLabelColor: Colors.grey,
                  indicatorColor: AppTheme.primary,
                  tabs: [
                    Tab(text: 'Matched (${updates.length})'),
                    Tab(text: 'Unmatched (${unmatched.length})'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      // Matched tab
                      updates.isEmpty
                          ? Center(child: Text('No stock changes needed',
                              style: GoogleFonts.manrope(color: Colors.grey)))
                          : ListView.separated(
                              itemCount: updates.length,
                              separatorBuilder: (_, __) =>
                                  Divider(height: 1, color: Colors.grey.shade200),
                              itemBuilder: (_, i) {
                                final u = updates[i];
                                final diff = u.newQty - u.oldQty;
                                final diffColor = diff > 0 ? Colors.green : Colors.red;
                                return ListTile(
                                  dense: true,
                                  title: Text(u.product.name,
                                      style: GoogleFonts.manrope(
                                          fontSize: 12, fontWeight: FontWeight.w600)),
                                  subtitle: Text(
                                      [
                                        if (u.csvName != u.product.name) 'CSV: ${u.csvName}',
                                        if (u.newMrp != null) 'MRP: ₹${u.product.unitPrice.toStringAsFixed(0)} → ₹${u.newMrp!.toStringAsFixed(0)}',
                                      ].join('  '),
                                      style: GoogleFonts.manrope(fontSize: 10, color: u.newMrp != null ? Colors.blue : Colors.grey)),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text('${u.oldQty}',
                                          style: GoogleFonts.manrope(
                                              fontSize: 12, color: Colors.grey,
                                              decoration: TextDecoration.lineThrough)),
                                      const SizedBox(width: 4),
                                      Icon(Icons.arrow_forward, size: 12, color: Colors.grey),
                                      const SizedBox(width: 4),
                                      Text('${u.newQty}',
                                          style: GoogleFonts.manrope(
                                              fontSize: 12, fontWeight: FontWeight.w700,
                                              color: diffColor)),
                                    ],
                                  ),
                                );
                              },
                            ),
                      // Unmatched tab
                      unmatched.isEmpty
                          ? Center(child: Text('All items matched!',
                              style: GoogleFonts.manrope(color: Colors.green)))
                          : ListView.builder(
                              itemCount: unmatched.length,
                              itemBuilder: (_, i) => ListTile(
                                dense: true,
                                leading: Icon(Icons.help_outline,
                                    size: 16, color: Colors.orange.shade600),
                                title: Text(unmatched[i],
                                    style: GoogleFonts.manrope(fontSize: 12)),
                              ),
                            ),
                    ],
                  ),
                ),
              ],
            ),
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: updates.isEmpty
                ? null
                : () async {
                    Navigator.pop(ctx);
                    await _applyStockUpdates(updates);
                  },
            child: Text('Update ${updates.length} products',
                style: GoogleFonts.manrope(color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Future<void> _applyStockUpdates(List<_StockUpdate> updates) async {
    int success = 0;
    int failed = 0;
    for (final u in updates) {
      try {
        final data = <String, dynamic>{'stock_qty': u.newQty};
        if (u.newMrp != null) data['unit_price'] = u.newMrp;
        await SupabaseService.instance.updateProduct(u.product.id, data);
        success++;
      } catch (_) {
        failed++;
      }
    }
    if (success > 0) {
      await SupabaseService.instance.invalidateCache('products');
    }
    await _loadProducts(forceRefresh: true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Stock updated: $success success${failed > 0 ? ', $failed failed' : ''}'),
        backgroundColor: failed > 0 ? Colors.orange : AppTheme.success,
      ));
    }
  }

  // ── Main Build ───────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Group ALL filtered products by category (for accurate counts)
    final Map<String, List<ProductModel>> fullGrouped = {};
    for (final p in _filtered) {
      fullGrouped.putIfAbsent(p.categoryName, () => []).add(p);
    }
    // Paginate for rendering
    final displayList = _filtered.length <= _displayLimit
        ? _filtered
        : _filtered.sublist(0, _displayLimit);
    final Map<String, List<ProductModel>> grouped = {};
    for (final p in displayList) {
      grouped.putIfAbsent(p.categoryName, () => []).add(p);
    }

    // Build scrollable header widgets (count/actions row only)
    final headerWidgets = <Widget>[];

    // Count + action buttons row
    headerWidgets.add(
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Text(
              _displayLimit < _filtered.length
                  ? 'Showing ${_displayLimit} of ${_filtered.length}'
                  : '${_filtered.length} product${_filtered.length == 1 ? '' : 's'}',
              style: GoogleFonts.manrope(fontSize: 11, color: Colors.grey.shade500, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
            if (_isSelectMode) ...[
              const SizedBox(width: 8),
              Text('Long-press to select more', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.primary)),
            ] else ...[
              const SizedBox(width: 8),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => showDialog(
                          context: context,
                          builder: (_) => CategoryManagementDialog(
                            categories: _categoryModels,
                            onChanged: _loadCategories,
                            isSuperAdmin: widget.isSuperAdmin,
                          ),
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.08), borderRadius: BorderRadius.circular(20)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.category_rounded, size: 13, color: AppTheme.primary),
                            const SizedBox(width: 4),
                            Text('Categories', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primary)),
                          ]),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _showManageSubcategoriesSheet,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.08), borderRadius: BorderRadius.circular(20)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.label_outline, size: 13, color: AppTheme.primary),
                            const SizedBox(width: 4),
                            Text('Subcategories', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primary)),
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      bottomNavigationBar: _isSelectMode ? _buildBulkBar() : null,
      body: Column(
        children: [
          // ── Pinned: Search + Category filter ───────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  style: GoogleFonts.manrope(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Search products...',
                    hintStyle: GoogleFonts.manrope(
                        fontSize: 13, color: Colors.grey.shade500),
                    prefixIcon: Icon(Icons.search_rounded,
                        color: AppTheme.primary, size: 20),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close_rounded,
                                size: 18, color: Colors.grey),
                            onPressed: () {
                              _searchController.clear();
                              _applyFilters();
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: AppTheme.primary.withOpacity(0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 34,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _categories.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final cat = _categories[i];
                      final selected = _selectedCategory == cat;
                      return GestureDetector(
                        onTap: () {
                          setState(() => _selectedCategory = cat);
                          _applyFilters();
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: selected
                                ? AppTheme.primary
                                : AppTheme.primary.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            cat,
                            style: GoogleFonts.manrope(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color:
                                  selected ? Colors.white : AppTheme.primary,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),

          // ── Scrollable: Everything else ─────────────────────
          Expanded(
            child: _filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.inventory_2_outlined,
                            size: 56, color: Colors.grey.shade300),
                        const SizedBox(height: 12),
                        Text(
                          'No products found',
                          style: GoogleFonts.manrope(
                              fontSize: 15, color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                  )
                : NotificationListener<ScrollNotification>(
                    onNotification: (scroll) {
                      if (scroll.metrics.pixels > scroll.metrics.maxScrollExtent - 200 &&
                          _displayLimit < _filtered.length) {
                        setState(() => _displayLimit += 200);
                      }
                      return false;
                    },
                    child: RefreshIndicator(
                    onRefresh: () => _loadProducts(forceRefresh: true),
                    color: AppTheme.primary,
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                      itemCount: headerWidgets.length + grouped.keys.length,
                      itemBuilder: (_, index) {
                        // Render header widgets first
                        if (index < headerWidgets.length) {
                          return headerWidgets[index];
                        }
                        final catIndex = index - headerWidgets.length;
                        final category =
                            grouped.keys.elementAt(catIndex);
                        final items = grouped[category]!;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 10),
                              child: Row(
                                children: [
                                  Container(
                                    width: 4,
                                    height: 16,
                                    decoration: BoxDecoration(
                                      color: AppTheme.primary,
                                      borderRadius:
                                          BorderRadius.circular(4),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    category,
                                    style: GoogleFonts.manrope(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.grey.shade700,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppTheme.primary
                                          .withOpacity(0.1),
                                      borderRadius:
                                          BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      '${fullGrouped[category]?.length ?? items.length}',
                                      style: GoogleFonts.manrope(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.primary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            ...items.map((product) => _ProductCard(
                                  product: product,
                                  stockColor:
                                      _stockColor(product.stockQty),
                                  stockLabel:
                                      _stockLabel(product.stockQty),
                                  stockIcon:
                                      _stockIcon(product.stockQty),
                                  isSelected:
                                      _selectedIds.contains(product.id),
                                  isSelectMode: _isSelectMode,
                                  onEdit: () =>
                                      _openProductSheet(existing: product),
                                  onDelete: () =>
                                      _confirmDeleteProduct(product),
                                  onLongPress: () =>
                                      _enterSelectMode(product.id),
                                  onSelect: () =>
                                      _toggleSelect(product.id),
                                )),
                            const SizedBox(height: 4),
                          ],
                        );
                      },
                    ),
                  ),
                  ),
          ),
        ],
      ),
      floatingActionButton: _isSelectMode
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.isSuperAdmin) ...[
                  FloatingActionButton.small(
                    heroTag: 'upload_stock',
                    onPressed: _uploadStockCsv,
                    backgroundColor: Colors.green.shade600,
                    foregroundColor: Colors.white,
                    elevation: 2,
                    tooltip: 'Upload Stock CSV',
                    child: const Icon(Icons.upload_file_rounded, size: 20),
                  ),
                  const SizedBox(height: 12),
                ],
                FloatingActionButton.small(
                  heroTag: 'add_product',
                  onPressed: () => _openProductSheet(),
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  elevation: 2,
                  tooltip: 'Add Product',
                  child: const Icon(Icons.add_rounded, size: 20),
                ),
              ],
            ),
    );
  }
}

// ── Product Card Widget ──────────────────────────────────────────
class _ProductCard extends StatelessWidget {
  final ProductModel product;
  final Color stockColor;
  final String stockLabel;
  final IconData stockIcon;
  final bool isSelected;
  final bool isSelectMode;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onLongPress;
  final VoidCallback onSelect;

  const _ProductCard({
    required this.product,
    required this.stockColor,
    required this.stockLabel,
    required this.stockIcon,
    required this.isSelected,
    required this.isSelectMode,
    required this.onEdit,
    required this.onDelete,
    required this.onLongPress,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: isSelectMode ? null : onLongPress,
      onTap: isSelectMode ? onSelect : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primary.withOpacity(0.08)
              : Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected
                ? AppTheme.primary
                : stockColor.withOpacity(0.2),
            width: isSelected ? 2 : 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              if (isSelectMode)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Icon(
                    isSelected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: isSelected
                        ? AppTheme.primary
                        : Colors.grey.shade400,
                    size: 22,
                  ),
                ),
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withOpacity(0.09),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.inventory_2_outlined,
                    color: AppTheme.primary, size: 22),
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
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          '₹${product.unitPrice.toStringAsFixed(2)}',
                          style: GoogleFonts.manrope(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('•',
                            style:
                                TextStyle(color: Colors.grey.shade400)),
                        const SizedBox(width: 8),
                        Text(
                          'Qty: ${product.stockQty}',
                          style: GoogleFonts.manrope(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(stockIcon, size: 13, color: stockColor),
                        const SizedBox(width: 4),
                        Text(
                          stockLabel,
                          style: GoogleFonts.manrope(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: stockColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!isSelectMode) ...[
                IconButton(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  color: Colors.grey.shade500,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.grey.shade100,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  color: Colors.red.shade400,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.red.shade50,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Stock Summary Widget ─────────────────────────────────────────
class _StockBadgeSummary extends StatelessWidget {
  final List<ProductModel> products;
  const _StockBadgeSummary({required this.products});

  @override
  Widget build(BuildContext context) {
    final outOfStock = products.where((p) => p.stockQty <= 0).length;
    final lowStock =
        products.where((p) => p.stockQty > 0 && p.stockQty <= 10).length;

    if (outOfStock == 0 && lowStock == 0) return const SizedBox.shrink();

    return Row(
      children: [
        if (outOfStock > 0) _badge('$outOfStock Out', Colors.red.shade600),
        if (outOfStock > 0 && lowStock > 0) const SizedBox(width: 6),
        if (lowStock > 0) _badge('$lowStock Low', Colors.orange.shade600),
      ],
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: GoogleFonts.manrope(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

// ── Manage Subcategories Sheet ────────────────────────────────────────────────

class _ManageSubcategoriesSheet extends StatefulWidget {
  final List<ProductCategoryModel> categoryModels;
  final List<ProductSubcategoryModel> subcategories;
  final VoidCallback onChanged;

  const _ManageSubcategoriesSheet({
    required this.categoryModels,
    required this.subcategories,
    required this.onChanged,
  });

  @override
  State<_ManageSubcategoriesSheet> createState() =>
      _ManageSubcategoriesSheetState();
}

class _ManageSubcategoriesSheetState extends State<_ManageSubcategoriesSheet> {
  late List<ProductSubcategoryModel> _subcategories;
  bool _saving = false;

  // Add-new form
  final _nameCtrl = TextEditingController();
  final _sortCtrl = TextEditingController(text: '1');
  String? _selectedCategoryId;

  @override
  void initState() {
    super.initState();
    _subcategories = List.from(widget.subcategories);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _sortCtrl.dispose();
    super.dispose();
  }

  Future<void> _addSubcategory() async {
    final name = _nameCtrl.text.trim();
    final sortOrder = int.tryParse(_sortCtrl.text.trim()) ?? 1;
    if (name.isEmpty || _selectedCategoryId == null) return;
    setState(() => _saving = true);
    try {
      await SupabaseService.instance
          .createProductSubcategory(name, _selectedCategoryId!, sortOrder);
      final refreshed = await SupabaseService.instance.getAllSubcategoriesForTeam();
      if (!mounted) return;
      setState(() {
        _subcategories = refreshed;
        _nameCtrl.clear();
        _sortCtrl.text = '1';
        _saving = false;
      });
      widget.onChanged();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _deleteSubcategory(ProductSubcategoryModel sub) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Delete "${sub.name}"?',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Text(
            'Products in this subcategory will remain but become unlinked.',
            style: GoogleFonts.manrope(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: GoogleFonts.manrope())),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete',
                style: GoogleFonts.manrope(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await SupabaseService.instance
          .deleteProductSubcategory(sub.id, sub.categoryId);
      final refreshed = await SupabaseService.instance.getAllSubcategoriesForTeam();
      if (!mounted) return;
      setState(() => _subcategories = refreshed);
      widget.onChanged();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    }
  }

  void _showEditDialog(ProductSubcategoryModel sub) {
    final nameCtrl = TextEditingController(text: sub.name);
    final sortCtrl = TextEditingController(text: sub.sortOrder.toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Edit Subcategory',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                labelText: 'Name',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              style: GoogleFonts.manrope(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: sortCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Sort Order',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              style: GoogleFonts.manrope(),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: GoogleFonts.manrope())),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final sort = int.tryParse(sortCtrl.text.trim()) ?? sub.sortOrder;
              if (name.isEmpty) return;
              Navigator.pop(ctx);
              try {
                await SupabaseService.instance.updateProductSubcategory(
                    sub.id, name, sub.categoryId, sort);
                final refreshed = await SupabaseService.instance
                    .getAllSubcategoriesForTeam();
                if (!mounted) return;
                setState(() => _subcategories = refreshed);
                widget.onChanged();
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Error: $e'),
                      backgroundColor: Colors.red));
                }
              }
            },
            child: Text('Save', style: GoogleFonts.manrope(color: Colors.white)),
          ),
        ],
      ),
    ).then((_) {
      nameCtrl.dispose();
      sortCtrl.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Group subcategories by category
    final Map<String, List<ProductSubcategoryModel>> grouped = {};
    for (final s in _subcategories) {
      grouped.putIfAbsent(s.categoryId, () => []).add(s);
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Handle
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.label_outline,
                        color: AppTheme.primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Text('Manage Subcategories',
                      style: GoogleFonts.manrope(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                ],
              ),
            ),

            // Existing subcategories list
            Expanded(
              child: _subcategories.isEmpty
                  ? Center(
                      child: Text('No subcategories yet',
                          style: GoogleFonts.manrope(
                              color: Colors.grey.shade500)))
                  : ListView(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      children: grouped.entries.map((entry) {
                        final catName = widget.categoryModels
                            .where((c) => c.id == entry.key)
                            .map((c) => c.name)
                            .firstOrNull ?? entry.key;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                children: [
                                  Container(
                                    width: 4,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: AppTheme.primary,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(catName,
                                      style: GoogleFonts.manrope(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.grey.shade700)),
                                ],
                              ),
                            ),
                            ...entry.value.map((sub) => Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: AppTheme.primary.withOpacity(0.04),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: AppTheme.primary.withOpacity(0.1)),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(sub.name,
                                            style: GoogleFonts.manrope(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600)),
                                        Text('Sort: ${sub.sortOrder}',
                                            style: GoogleFonts.manrope(
                                                fontSize: 11,
                                                color: Colors.grey.shade500)),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.edit_rounded,
                                        size: 18),
                                    color: AppTheme.primary,
                                    onPressed: () => _showEditDialog(sub),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        size: 18),
                                    color: Colors.red.shade400,
                                    onPressed: () => _deleteSubcategory(sub),
                                  ),
                                ],
                              ),
                            )),
                          ],
                        );
                      }).toList(),
                    ),
            ),

            // Add new subcategory form
            Container(
              padding: EdgeInsets.only(
                left: 16, right: 16, top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                border: Border(
                    top: BorderSide(color: Colors.grey.shade200, width: 1)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Add Subcategory',
                      style: GoogleFonts.manrope(
                          fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _nameCtrl,
                          style: GoogleFonts.manrope(fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'Name',
                            hintStyle: GoogleFonts.manrope(
                                fontSize: 13, color: Colors.grey.shade400),
                            filled: true,
                            fillColor: AppTheme.primary.withOpacity(0.04),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 1,
                        child: TextField(
                          controller: _sortCtrl,
                          keyboardType: TextInputType.number,
                          style: GoogleFonts.manrope(fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'Order',
                            hintStyle: GoogleFonts.manrope(
                                fontSize: 13, color: Colors.grey.shade400),
                            filled: true,
                            fillColor: AppTheme.primary.withOpacity(0.04),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _selectedCategoryId,
                          decoration: InputDecoration(
                            hintText: 'Category',
                            hintStyle: GoogleFonts.manrope(
                                fontSize: 13, color: Colors.grey.shade400),
                            filled: true,
                            fillColor: AppTheme.primary.withOpacity(0.04),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                          ),
                          style: GoogleFonts.manrope(
                              fontSize: 14, color: Colors.black87),
                          items: widget.categoryModels
                              .map((c) => DropdownMenuItem(
                                    value: c.id,
                                    child: Text(c.name,
                                        style: GoogleFonts.manrope(
                                            fontSize: 14)),
                                  ))
                              .toList(),
                          onChanged: (val) =>
                              setState(() => _selectedCategoryId = val),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _saving ? null : _addSubcategory,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            elevation: 0,
                          ),
                          child: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                              : Text('Add',
                                  style: GoogleFonts.manrope(
                                      fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
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

// ── CSV row helper (dedup by highest stock) ────────────────────────────────
class _CsvRow {
  final String itemName;
  final int qty;
  final double? mrp;
  const _CsvRow({required this.itemName, required this.qty, this.mrp});
}

// ── Stock Update helper ─────────────────────────────────────────────────────
class _StockUpdate {
  final ProductModel product;
  final String csvName;
  final int oldQty;
  final int newQty;
  final double? newMrp;

  const _StockUpdate({
    required this.product,
    required this.csvName,
    required this.oldQty,
    required this.newQty,
    this.newMrp,
  });
}
