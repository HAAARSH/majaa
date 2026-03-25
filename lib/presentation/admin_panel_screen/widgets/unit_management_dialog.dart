import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';

class UnitManagementDialog extends StatefulWidget {
  final List<ProductUnitModel> units;
  final VoidCallback onChanged;

  const UnitManagementDialog({
    super.key,
    required this.units,
    required this.onChanged,
  });

  @override
  State<UnitManagementDialog> createState() => _UnitManagementDialogState();
}

class _UnitManagementDialogState extends State<UnitManagementDialog> {
  late List<ProductUnitModel> _units;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _units = List.from(widget.units);
  }

  void _addUnit() {
    final nameCtrl = TextEditingController();
    final abbrCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          'Add Unit',
          style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              style: GoogleFonts.manrope(fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Unit Name (e.g., Kilogram)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: abbrCtrl,
              style: GoogleFonts.manrope(fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Abbreviation (e.g., kg)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
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
              final name = nameCtrl.text.trim();
              final abbr = abbrCtrl.text.trim();
              if (name.isEmpty || abbr.isEmpty) return;
              Navigator.pop(ctx);
              setState(() => _isSaving = true);
              try {
                await SupabaseService.instance.upsertProductUnit(
                  ProductUnitModel(id: '', name: name, abbreviation: abbr),
                );
                final updated = await SupabaseService.instance.getProductUnits();
                setState(() {
                  _units = updated;
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

  void _editUnit(ProductUnitModel unit) {
    final nameCtrl = TextEditingController(text: unit.name);
    final abbrCtrl = TextEditingController(text: unit.abbreviation);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          'Edit Unit',
          style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              style: GoogleFonts.manrope(fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Unit Name',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: abbrCtrl,
              style: GoogleFonts.manrope(fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Abbreviation',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
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
              final name = nameCtrl.text.trim();
              final abbr = abbrCtrl.text.trim();
              if (name.isEmpty || abbr.isEmpty) return;
              Navigator.pop(ctx);
              setState(() => _isSaving = true);
              try {
                await SupabaseService.instance.upsertProductUnit(
                  ProductUnitModel(id: unit.id, name: name, abbreviation: abbr),
                );
                final updated = await SupabaseService.instance.getProductUnits();
                setState(() {
                  _units = updated;
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
            child: Text('Save', style: GoogleFonts.manrope(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _deleteUnit(ProductUnitModel unit) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          'Delete Unit',
          style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Delete "${unit.name}" (${unit.abbreviation})?',
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
                await SupabaseService.instance.deleteProductUnit(unit.id);
                final updated = await SupabaseService.instance.getProductUnits();
                setState(() {
                  _units = updated;
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
            child: Text('Delete', style: GoogleFonts.manrope(color: Colors.white)),
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
              'Manage Units',
              style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_rounded, color: AppTheme.primary),
            tooltip: 'Add Unit',
            onPressed: _addUnit,
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: _isSaving
            ? const Center(child: CircularProgressIndicator())
            : _units.isEmpty
                ? Center(
                    child: Text(
                      'No units yet',
                      style: GoogleFonts.manrope(color: AppTheme.onSurfaceVariant),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _units.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final unit = _units[i];
                      return ListTile(
                        dense: true,
                        title: Text(
                          unit.name,
                          style: GoogleFonts.manrope(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          unit.abbreviation,
                          style: GoogleFonts.manrope(
                            fontSize: 11,
                            color: AppTheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.edit_rounded,
                                size: 16,
                                color: AppTheme.primary,
                              ),
                              onPressed: () => _editUnit(unit),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete_rounded,
                                size: 16,
                                color: AppTheme.error,
                              ),
                              onPressed: () => _deleteUnit(unit),
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
