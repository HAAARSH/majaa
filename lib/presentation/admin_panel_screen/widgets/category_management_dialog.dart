import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';

class CategoryManagementDialog extends StatefulWidget {
  final List<ProductCategoryModel> categories;
  final VoidCallback onChanged;

  const CategoryManagementDialog({
    super.key,
    required this.categories,
    required this.onChanged,
  });

  @override
  State<CategoryManagementDialog> createState() =>
      _CategoryManagementDialogState();
}

class _CategoryManagementDialogState extends State<CategoryManagementDialog> {
  late List<ProductCategoryModel> _cats;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _cats = List.from(widget.categories);
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

  void _deleteCategory(ProductCategoryModel cat) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          'Delete Category',
          style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Delete "${cat.name}"? Products in this category will not be deleted.',
          style: GoogleFonts.manrope(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.manrope()),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              setState(() => _isSaving = true);
              try {
                await SupabaseService.instance.deleteProductCategory(cat.id);
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
            child: Text(
              'Delete',
              style: GoogleFonts.manrope(color: Colors.white),
            ),
          ),
        ],
      ),
    );
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
                      return ListTile(
                        dense: true,
                        title: Text(
                          cat.name,
                          style: GoogleFonts.manrope(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
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
                            IconButton(
                              icon: const Icon(
                                Icons.edit_rounded,
                                size: 16,
                                color: AppTheme.primary,
                              ),
                              onPressed: () => _editCategory(cat),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete_rounded,
                                size: 16,
                                color: AppTheme.error,
                              ),
                              onPressed: () => _deleteCategory(cat),
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
