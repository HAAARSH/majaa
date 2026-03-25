import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';
import './admin_shared_widgets.dart';

class AdminBeatsTab extends StatefulWidget {
  const AdminBeatsTab({super.key});

  @override
  State<AdminBeatsTab> createState() => _AdminBeatsTabState();
}

class _AdminBeatsTabState extends State<AdminBeatsTab> {
  bool _isLoading = true;
  List<BeatModel> _beats = [];
  String? _error;

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
      final beats = await SupabaseService.instance.getBeats();
      if (!mounted) return;
      setState(() {
        _beats = beats;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _showEditDialog(BeatModel? beat) {
    final nameCtrl = TextEditingController(text: beat?.beatName ?? '');
    final codeCtrl = TextEditingController(text: beat?.beatCode ?? '');
    final areaCtrl = TextEditingController(text: beat?.area ?? '');
    final routeCtrl = TextEditingController(text: beat?.route ?? '');
    final weekdaysCtrl = TextEditingController(
      text: beat?.weekdays.join(', ') ?? '',
    );

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          beat == null ? 'Add Beat' : 'Edit Beat',
          style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              buildAdminTextField('Beat Name', nameCtrl),
              const SizedBox(height: 10),
              buildAdminTextField('Beat Code', codeCtrl),
              const SizedBox(height: 10),
              buildAdminTextField('Area', areaCtrl),
              const SizedBox(height: 10),
              buildAdminTextField('Route', routeCtrl),
              const SizedBox(height: 10),
              buildAdminTextField('Weekdays (comma separated)', weekdaysCtrl),
              const SizedBox(height: 6),
              Text(
                'e.g. Monday, Wednesday, Friday',
                style: GoogleFonts.manrope(
                  fontSize: 11,
                  color: AppTheme.onSurfaceVariant,
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
              try {
                final weekdays = weekdaysCtrl.text
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList();
                await SupabaseService.instance.upsertBeat(
                  id: beat?.id,
                  beatName: nameCtrl.text.trim(),
                  beatCode: codeCtrl.text.trim(),
                  area: areaCtrl.text.trim(),
                  route: routeCtrl.text.trim(),
                  weekdays: weekdays,
                );
                _load();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Beat saved', style: GoogleFonts.manrope()),
                      backgroundColor: AppTheme.success,
                    ),
                  );
                }
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
            },
            child: Text(
              'Save',
              style: GoogleFonts.manrope(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return AdminErrorRetry(message: _error!, onRetry: _load);
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: Text('Add Beat', style: GoogleFonts.manrope(fontSize: 13)),
        onPressed: () => _showEditDialog(null),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppTheme.primary,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
          itemCount: _beats.length,
          itemBuilder: (context, index) {
            final b = _beats[index];
            return AdminCard(
              title: b.beatName,
              subtitle: b.weekdays.join(', '),
              trailing: b.beatCode,
              onEdit: () => _showEditDialog(b),
            );
          },
        ),
      ),
    );
  }
}
