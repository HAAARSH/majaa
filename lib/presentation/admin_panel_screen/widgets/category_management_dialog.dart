import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/supabase_service.dart';
import '../../../services/auth_service.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/pin_dialog.dart';

class CategoryManagementDialog extends StatefulWidget {
  final List<ProductCategoryModel> categories;
  final VoidCallback onChanged;
  final bool isSuperAdmin;

  const CategoryManagementDialog({
    super.key,
    required this.categories,
    required this.onChanged,
    this.isSuperAdmin = false,
  });

  @override
  State<CategoryManagementDialog> createState() =>
      _CategoryManagementDialogState();
}

class _CategoryManagementDialogState extends State<CategoryManagementDialog> {
  late List<ProductCategoryModel> _cats;
  bool _isSaving = false;
  final Set<String> _selectedIds = {};
  Map<String, int> _productCounts = {};

  @override
  void initState() {
    super.initState();
    _cats = List.from(widget.categories);
    _loadProductCounts();
  }

  Future<void> _loadProductCounts() async {
    try {
      final products = await SupabaseService.instance.getProducts();
      final counts = <String, int>{};
      for (final p in products) {
        final catName = p.categoryName;
        counts[catName] = (counts[catName] ?? 0) + 1;
      }
      if (mounted) setState(() => _productCounts = counts);
    } catch (_) {}
  }

  void _addCategory() {
    final nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          'Add Category',
          style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          style: GoogleFonts.manrope(fontSize: 13),
          decoration: InputDecoration(
            labelText: 'Category Name',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(ctx);
              setState(() => _isSaving = true);
              try {
                await SupabaseService.instance.createProductCategory(
                  name,
                  _cats.length,
                );
                final updated =
                    await SupabaseService.instance.getAllProductCategories();
                setState(() {
                  _cats = updated;
                  _isSaving = false;
                });
                widget.onChanged();
              } catch (e) {
                setState(() => _isSaving = false);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error: $e', style: GoogleFonts.manrope()),
                      backgroundColor: AppTheme.error,
                    ),
                  );
                }
              }
            },
            child: Text('Add', style: GoogleFonts.manrope(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _editCategory(ProductCategoryModel cat) {
    final nameCtrl = TextEditingController(text: cat.name);
    bool isActive = cat.isActive;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDS) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          title: Text(
            'Edit Category',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                style: GoogleFonts.manrope(fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Category Name',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                dense: true,
                value: isActive,
                activeThumbColor: AppTheme.primary,
                title: Text('Active', style: GoogleFonts.manrope(fontSize: 13)),
                onChanged: (v) => setDS(() => isActive = v),
              ),
            ],
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
                setState(() => _isSaving = true);
                try {
                  await SupabaseService.instance.updateProductCategory(
                    cat.id,
                    nameCtrl.text.trim(),
                    cat.sortOrder,
                    isActive,
                  );
                  final updated =
                      await SupabaseService.instance.getAllProductCategories();
                  setState(() {
                    _cats = updated;
                    _isSaving = false;
                  });
                  widget.onChanged();
                } catch (e) {
                  setState(() => _isSaving = false);
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

  Future<void> _deleteCategory(ProductCategoryModel cat) async {
    final pinOk = await showPinDialog(
      context,
      title: 'Delete Category',
      warningMessage: 'This will delete category "${cat.name}" and all its subcategories. Products will become uncategorized.',
    );
    if (!pinOk || !mounted) return;

    setState(() => _isSaving = true);
    try {
      await SupabaseService.instance.deleteProductCategory(cat.id);
      final updated = await SupabaseService.instance.getAllProductCategories();
      setState(() { _cats = updated; _isSaving = false; });
      widget.onChanged();
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Future<void> _bulkDeleteCategories() async {
    final count = _selectedIds.length;
    final warning = 'WARNING: This will permanently delete $count category(ies) and ALL associated data:\n\n'
        '• All subcategories under these categories\n'
        '• ALL products in these categories\n'
        '• All billed items linked to these products\n\n'
        'This action CANNOT be undone.';

    final pinOk = await showPinDialog(context, title: 'Delete $count Category(ies)', warningMessage: warning, requireDouble: true);
    if (!pinOk || !mounted) return;

    setState(() => _isSaving = true);
    try {
      final client = SupabaseService.instance.client;
      for (final catId in _selectedIds) {
        // Delete subcategories
        await client.from('product_subcategories').delete().eq('category_id', catId);
        // Get products in this category
        final cat = _cats.firstWhere((c) => c.id == catId);
        final products = await client.from('products').select('id').eq('category', cat.name).eq('team_id', AuthService.currentTeam);
        for (final p in products) {
          await client.from('order_billed_items').delete().eq('product_id', p['id']);
        }
        // Delete products
        await client.from('products').delete().eq('category', cat.name).eq('team_id', AuthService.currentTeam);
        // Delete category
        await client.from('product_categories').delete().eq('id', catId);
      }
      _selectedIds.clear();
      final updated = await SupabaseService.instance.getAllProductCategories();
      setState(() { _cats = updated; _isSaving = false; });
      widget.onChanged();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deleted $count categories'), backgroundColor: Colors.red));
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Expanded(
            child: Text(
              'Manage Categories',
              style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
            ),
          ),
          if (widget.isSuperAdmin && _selectedIds.isNotEmpty)
            IconButton(
              icon: Icon(Icons.delete_forever_rounded, color: Colors.red, size: 22),
              tooltip: 'Delete ${_selectedIds.length} selected',
              onPressed: _bulkDeleteCategories,
            ),
          IconButton(
            icon: const Icon(Icons.add_circle_rounded, color: AppTheme.primary),
            tooltip: 'Add Category',
            onPressed: _addCategory,
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: _isSaving
            ? const Center(child: CircularProgressIndicator())
            : _cats.isEmpty
                ? Center(
                    child: Text(
                      'No categories yet',
                      style:
                          GoogleFonts.manrope(color: AppTheme.onSurfaceVariant),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _cats.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final cat = _cats[i];
                      final isSelected = _selectedIds.contains(cat.id);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                        child: Row(
                          children: [
                            if (widget.isSuperAdmin)
                              SizedBox(
                                width: 32,
                                child: Checkbox(
                                  value: isSelected,
                                  activeColor: Colors.red,
                                  visualDensity: VisualDensity.compact,
                                  onChanged: (v) => setState(() {
                                    if (v == true) _selectedIds.add(cat.id); else _selectedIds.remove(cat.id);
                                  }),
                                ),
                              ),
                            Expanded(
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      cat.name,
                                      style: GoogleFonts.manrope(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: AppTheme.primary.withAlpha(20),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '${_productCounts[cat.name] ?? 0}',
                                      style: GoogleFonts.manrope(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.primary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: cat.isActive
                                    ? AppTheme.success.withAlpha(25)
                                    : AppTheme.error.withAlpha(25),
                                borderRadius: BorderRadius.circular(100),
                              ),
                              child: Text(
                                cat.isActive ? 'Active' : 'Inactive',
                                style: GoogleFonts.manrope(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: cat.isActive
                                      ? AppTheme.success
                                      : AppTheme.error,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 32,
                              child: IconButton(
                                icon: const Icon(
                                  Icons.edit_rounded,
                                  size: 16,
                                  color: AppTheme.primary,
                                ),
                                padding: EdgeInsets.zero,
                                onPressed: () => _editCategory(cat),
                              ),
                            ),
                            if (widget.isSuperAdmin)
                              SizedBox(
                                width: 32,
                                child: IconButton(
                                  icon: const Icon(
                                    Icons.delete_rounded,
                                    size: 16,
                                    color: AppTheme.error,
                                  ),
                                  padding: EdgeInsets.zero,
                                  onPressed: () => _deleteCategory(cat),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Close', style: GoogleFonts.manrope()),
        ),
      ],
    );
  }
}
