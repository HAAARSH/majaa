import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/supabase_service.dart';
import '../../../services/auth_service.dart';
import '../../../services/pin_service.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/pin_dialog.dart';
import './admin_shared_widgets.dart';

class AdminBeatsTab extends StatefulWidget {
  final bool isSuperAdmin;
  const AdminBeatsTab({super.key, this.isSuperAdmin = false});

  @override
  State<AdminBeatsTab> createState() => _AdminBeatsTabState();
}

class _AdminBeatsTabState extends State<AdminBeatsTab> {
  bool _isLoading = true;
  List<BeatModel> _beats = [];
  Map<String, int> _customerCounts = {};
  String? _error;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final beats = await SupabaseService.instance.getBeats(forceRefresh: forceRefresh);
      final counts = await SupabaseService.instance.getCustomerCountsByBeat();
      beats.sort((a, b) => a.beatName.toLowerCase().compareTo(b.beatName.toLowerCase()));
      if (!mounted) return;
      setState(() { _beats = beats; _customerCounts = counts; _isLoading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  static const _allDays = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
  static const _dayLabels = {
    'monday': 'Mon', 'tuesday': 'Tue', 'wednesday': 'Wed',
    'thursday': 'Thu', 'friday': 'Fri', 'saturday': 'Sat', 'sunday': 'Sun',
  };

  // ── EDIT / ADD BEAT DIALOG ─────────────────────────────────────
  void _showEditDialog(BeatModel? beat) {
    final nameCtrl = TextEditingController(text: beat?.beatName ?? '');
    final codeCtrl = TextEditingController(text: beat?.beatCode ?? '');
    final areaCtrl = TextEditingController(text: beat?.area ?? '');
    final routeCtrl = TextEditingController(text: beat?.route ?? '');
    final selectedDays = Set<String>.from(
      (beat?.weekdays ?? []).map((d) => d.toLowerCase().trim()),
    );

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(beat == null ? 'Add Beat' : 'Edit Beat', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildAdminTextField('Beat Name', nameCtrl),
                const SizedBox(height: 10),
                buildAdminTextField('Beat Code', codeCtrl),
                const SizedBox(height: 10),
                buildAdminTextField('Area', areaCtrl),
                const SizedBox(height: 10),
                buildAdminTextField('Route', routeCtrl),
                const SizedBox(height: 14),
                Text('Schedule Days', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8, runSpacing: 8,
                  children: _allDays.map((day) {
                    final sel = selectedDays.contains(day);
                    return FilterChip(
                      label: Text(_dayLabels[day]!, style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: sel ? Colors.white : AppTheme.onSurface)),
                      selected: sel,
                      onSelected: (v) => setDialogState(() { if (v) selectedDays.add(day); else selectedDays.remove(day); }),
                      selectedColor: AppTheme.primary,
                      backgroundColor: AppTheme.surfaceVariant,
                      checkmarkColor: Colors.white,
                      side: BorderSide(color: sel ? AppTheme.primary : AppTheme.outline, width: 1),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.manrope())),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final code = codeCtrl.text.trim();
                if (name.isEmpty || code.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Beat Name and Code are required')));
                  return;
                }
                Navigator.pop(ctx);
                try {
                  await SupabaseService.instance.upsertBeat(id: beat?.id, beatName: name, beatCode: code, area: areaCtrl.text.trim(), route: routeCtrl.text.trim(), weekdays: selectedDays.toList());
                  if (beat != null) {
                    // Edit — refresh only the edited beat in-place
                    final updated = await SupabaseService.instance.getBeatById(beat.id);
                    if (updated != null && mounted) {
                      setState(() {
                        final idx = _beats.indexWhere((b) => b.id == beat.id);
                        if (idx != -1) _beats[idx] = updated;
                      });
                    }
                  } else {
                    // Create — full reload needed to get new item
                    _load(forceRefresh: true);
                  }
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Beat saved'), backgroundColor: AppTheme.success));
                } catch (e) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
                }
              },
              child: Text('Save', style: GoogleFonts.manrope(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  // ── BULLET-PROOF DELETE ────────────────────────────────────────
  Future<void> _bulkDeleteBeats() async {
    final count = _selectedIds.length;
    final totalCustomers = _selectedIds.fold<int>(0, (sum, id) => sum + (_customerCounts[id] ?? 0));

    final warning = 'WARNING: This will permanently delete $count beat(s) and ALL associated data:\n\n'
        '• $totalCustomers customers assigned\n'
        '• All orders + order items\n'
        '• All collections\n'
        '• All visit logs\n'
        '• Beat name references cleared\n\n'
        'This action CANNOT be undone.';

    final pinOk = await showPinDialog(context, title: 'Delete $count Beat(s)', warningMessage: warning, requireDouble: true);
    if (!pinOk || !mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('FINAL CONFIRMATION', style: GoogleFonts.manrope(fontWeight: FontWeight.w900, color: Colors.red)),
        content: Text('Delete $count beats, $totalCustomers customers, and ALL their data?', style: GoogleFonts.manrope(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('DELETE EVERYTHING', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _isLoading = true);
    try {
      final client = SupabaseService.instance.client;
      final teamId = AuthService.currentTeam;
      final isJa = teamId == 'JA';
      final beatCol = isJa ? 'beat_id_ja' : 'beat_id_ma';

      for (final beatId in _selectedIds) {
        // 1. Get all customers on this beat
        final profiles = await client.from('customer_team_profiles')
            .select('customer_id').eq(beatCol, beatId);
        final custIds = (profiles as List).map((p) => p['customer_id'] as String).toList();

        // 2. Delete all customer data for this team
        for (final custId in custIds) {
          final orders = await client.from('orders').select('id').eq('customer_id', custId).eq('team_id', teamId);
          for (final o in orders) {
            await client.from('order_items').delete().eq('order_id', o['id']);
          }
          await client.from('orders').delete().eq('customer_id', custId).eq('team_id', teamId);
          await client.from('collections').delete().eq('customer_id', custId).eq('team_id', teamId);
          await client.from('visit_logs').delete().eq('customer_id', custId).eq('team_id', teamId);

          // 3. Clear this team's profile data
          await client.from('customer_team_profiles').update(
            isJa
                ? {'team_ja': false, 'beat_id_ja': null, 'beat_name_ja': '', 'outstanding_ja': 0}
                : {'team_ma': false, 'beat_id_ma': null, 'beat_name_ma': '', 'outstanding_ma': 0},
          ).eq('customer_id', custId);

          // 4. If customer no longer belongs to any team, delete entirely
          final profile = await client.from('customer_team_profiles')
              .select('team_ja, team_ma').eq('customer_id', custId).maybeSingle();
          if (profile != null && profile['team_ja'] != true && profile['team_ma'] != true) {
            await client.from('customer_team_profiles').delete().eq('customer_id', custId);
            await client.from('customers').delete().eq('id', custId);
          }
        }

        // 5. Clear any remaining beat name references (safety net)
        await client.from('customer_team_profiles').update(
          isJa ? {'beat_id_ja': null, 'beat_name_ja': ''} : {'beat_id_ma': null, 'beat_name_ma': ''},
        ).eq(beatCol, beatId);

        // 6. Delete user_beats + beat itself
        await client.from('user_beats').delete().eq('beat_id', beatId);
        await client.from('beats').delete().eq('id', beatId);
      }

      _selectedIds.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deleted $count beats and all associated data'), backgroundColor: Colors.red));
        _load(forceRefresh: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    }
  }

  // ── MERGE BEAT ─────────────────────────────────────────────────
  void _showMergeDialog(BeatModel sourceBeat) {
    final otherBeats = _beats.where((b) => b.id != sourceBeat.id).toList();
    if (otherBeats.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No other beats to merge into')));
      return;
    }
    String? targetId;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Merge Beat', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                  child: Row(children: [
                    const Icon(Icons.merge_rounded, size: 16, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(child: Text(sourceBeat.beatName, style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                    Text('${_customerCounts[sourceBeat.id] ?? 0}', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.orange)),
                    const SizedBox(width: 2),
                    const Icon(Icons.people, size: 12, color: Colors.orange),
                  ]),
                ),
                const SizedBox(height: 10),
                Text('All customers, orders, collections & visits will be moved to:', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: targetId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Target Beat',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  items: otherBeats.map((b) => DropdownMenuItem(
                    value: b.id,
                    child: Text('${b.beatName} (${_customerCounts[b.id] ?? 0})', style: GoogleFonts.manrope(fontSize: 13), overflow: TextOverflow.ellipsis),
                  )).toList(),
                  onChanged: (v) => setDlg(() => targetId = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.manrope())),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: targetId == null ? null : () async {
                Navigator.pop(ctx);
                await _executeMerge(sourceBeat, targetId!);
              },
              child: Text('Merge', style: GoogleFonts.manrope(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _executeMerge(BeatModel source, String targetId) async {
    final target = _beats.firstWhere((b) => b.id == targetId);
    final pinOk = await showPinDialog(context,
      title: 'Merge Beats',
      warningMessage: 'Move all customers from "${source.beatName}" to "${target.beatName}" and delete "${source.beatName}"?',
    );
    if (!pinOk || !mounted) return;

    setState(() => _isLoading = true);
    try {
      final client = SupabaseService.instance.client;
      final teamId = AuthService.currentTeam;
      final isJa = teamId == 'JA';
      final beatIdCol = isJa ? 'beat_id_ja' : 'beat_id_ma';
      final beatNameCol = isJa ? 'beat_name_ja' : 'beat_name_ma';

      // 1. Reassign customer profiles from source beat to target beat
      await client.from('customer_team_profiles').update({
        beatIdCol: targetId,
        beatNameCol: target.beatName,
      }).eq(beatIdCol, source.id);

      // 2. Move orders — update beat_name for orders on source beat
      await client.from('orders').update({
        'beat_name': target.beatName,
      }).eq('beat_name', source.beatName).eq('team_id', teamId);

      // 3. Move visit_logs — update beat references
      await client.from('visit_logs').update({
        'beat_id': targetId,
      }).eq('beat_id', source.id).eq('team_id', teamId);

      // 4. Move user_beats associations to target (avoid duplicates)
      final sourceUserBeats = await client.from('user_beats').select('user_id').eq('beat_id', source.id);
      final targetUserBeats = await client.from('user_beats').select('user_id').eq('beat_id', targetId);
      final targetUserIds = (targetUserBeats as List).map((r) => r['user_id'] as String).toSet();
      for (final ub in sourceUserBeats as List) {
        final uid = ub['user_id'] as String;
        if (!targetUserIds.contains(uid)) {
          await client.from('user_beats').insert({'user_id': uid, 'beat_id': targetId});
        }
      }
      await client.from('user_beats').delete().eq('beat_id', source.id);

      // 5. Delete source beat
      await client.from('beats').delete().eq('id', source.id);

      if (mounted) {
        final count = _customerCounts[source.id] ?? 0;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Merged $count customers into "${target.beatName}"'),
          backgroundColor: Colors.green,
        ));
        _load(forceRefresh: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
      }
    }
  }

  // ── VIEW CUSTOMERS SHEET ───────────────────────────────────────
  void _showBeatCustomers(BeatModel beat) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BeatCustomersSheet(
        beat: beat,
        onChanged: () => _load(forceRefresh: true),
      ),
    );
  }

  // ── BUILD ──────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return AdminErrorRetry(message: _error!, onRetry: _load);

    return Scaffold(
      backgroundColor: AppTheme.background,
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.isSuperAdmin && _selectedIds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FloatingActionButton.extended(
                heroTag: 'delete_beats',
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.delete_forever_rounded),
                label: Text('Delete ${_selectedIds.length} Beat(s)', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700)),
                onPressed: _bulkDeleteBeats,
              ),
            ),
          FloatingActionButton.extended(
            heroTag: 'add_beat',
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add_rounded),
            label: Text('Add Beat', style: GoogleFonts.manrope(fontSize: 13)),
            onPressed: () => _showEditDialog(null),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(forceRefresh: true),
        color: AppTheme.primary,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
          itemCount: _beats.length,
          itemBuilder: (context, index) {
            final b = _beats[index];
            final customerCount = _customerCounts[b.id] ?? 0;
            final isSelected = _selectedIds.contains(b.id);
            return GestureDetector(
              onLongPress: widget.isSuperAdmin ? () => setState(() {
                if (isSelected) _selectedIds.remove(b.id); else _selectedIds.add(b.id);
              }) : null,
              child: Stack(
                children: [
                  _BeatCard(
                    beat: b,
                    customerCount: customerCount,
                    onEdit: () => _showEditDialog(b),
                    onView: () => _showBeatCustomers(b),
                    onMerge: () => _showMergeDialog(b),
                    isSuperAdmin: widget.isSuperAdmin,
                  ),
                  if (widget.isSuperAdmin && _selectedIds.isNotEmpty)
                    Positioned(
                      top: 8, left: 8,
                      child: Checkbox(
                        value: isSelected,
                        activeColor: Colors.red,
                        onChanged: (v) => setState(() {
                          if (v == true) _selectedIds.add(b.id); else _selectedIds.remove(b.id);
                        }),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// ── BEAT CARD ────────────────────────────────────────────────────
class _BeatCard extends StatelessWidget {
  final BeatModel beat;
  final int customerCount;
  final VoidCallback onEdit;
  final VoidCallback onView;
  final VoidCallback onMerge;
  final bool isSuperAdmin;

  const _BeatCard({
    required this.beat,
    required this.customerCount,
    required this.onEdit,
    required this.onView,
    required this.onMerge,
    required this.isSuperAdmin,
  });

  @override
  Widget build(BuildContext context) {
    final weekdayText = beat.weekdays.isEmpty ? 'No schedule set' : beat.weekdays.join(', ');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.outlineVariant),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(6), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(child: Text(beat.beatName, style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.onSurface), overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: AppTheme.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(100)),
                      child: Text(beat.beatCode, style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w600, color: AppTheme.primary)),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Icon(Icons.calendar_today_rounded, size: 12, color: AppTheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(child: Text(weekdayText, style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant), overflow: TextOverflow.ellipsis)),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Icon(Icons.people_rounded, size: 12, color: AppTheme.secondary),
                    const SizedBox(width: 4),
                    Text('$customerCount customer${customerCount == 1 ? '' : 's'}', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.secondary)),
                  ]),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // View button
                GestureDetector(
                  onTap: onView,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                    child: Text('View', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.blue)),
                  ),
                ),
                const SizedBox(height: 6),
                // Edit button
                GestureDetector(
                  onTap: onEdit,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: AppTheme.primaryContainer, borderRadius: BorderRadius.circular(8)),
                    child: Text('Edit', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primary)),
                  ),
                ),
                if (isSuperAdmin) ...[
                  const SizedBox(height: 6),
                  // Merge button
                  GestureDetector(
                    onTap: onMerge,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                      child: Text('Merge', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.orange.shade700)),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── BEAT CUSTOMERS SHEET ─────────────────────────────────────────
class _BeatCustomersSheet extends StatefulWidget {
  final BeatModel beat;
  final VoidCallback onChanged;
  const _BeatCustomersSheet({required this.beat, required this.onChanged});
  @override
  State<_BeatCustomersSheet> createState() => _BeatCustomersSheetState();
}

class _BeatCustomersSheetState extends State<_BeatCustomersSheet> {
  bool _loading = true;
  List<CustomerModel> _customers = [];
  List<CustomerModel> _filtered = [];
  final _searchCtrl = TextEditingController();
  List<BeatModel> _beatsJA = [];
  List<BeatModel> _beatsMA = [];

  @override
  void initState() {
    super.initState();
    _loadCustomers();
    _searchCtrl.addListener(_applySearch);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCustomers() async {
    setState(() => _loading = true);
    try {
      final allCustomers = await SupabaseService.instance.getCustomers(forceRefresh: true);
      final teamId = AuthService.currentTeam;
      final isJa = teamId == 'JA';
      final beatCustomers = allCustomers.where((c) {
        final beatId = isJa ? c.beatIdForTeam('JA') : c.beatIdForTeam('MA');
        return beatId == widget.beat.id;
      }).toList();
      final beatsJA = await SupabaseService.instance.getBeatsForTeam('JA');
      final beatsMA = await SupabaseService.instance.getBeatsForTeam('MA');
      if (!mounted) return;
      setState(() {
        _customers = beatCustomers;
        _filtered = beatCustomers;
        _beatsJA = beatsJA;
        _beatsMA = beatsMA;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applySearch() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filtered = _customers;
      } else {
        _filtered = _customers.where((c) =>
          c.name.toLowerCase().contains(q) ||
          c.phone.toLowerCase().contains(q) ||
          c.address.toLowerCase().contains(q)
        ).toList();
      }
    });
  }

  void _editCustomer(CustomerModel customer) {
    final nameCtrl = TextEditingController(text: customer.name);
    final phoneCtrl = TextEditingController(text: customer.phone);
    final addressCtrl = TextEditingController(text: customer.address);

    final jaBeatId = customer.beatIdForTeam('JA');
    final maBeatId = customer.beatIdForTeam('MA');
    String? selectedBeatIdJA = _beatsJA.any((b) => b.id == jaBeatId) ? jaBeatId : null;
    String? selectedBeatIdMA = _beatsMA.any((b) => b.id == maBeatId) ? maBeatId : null;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Edit Customer', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                buildAdminTextField('Name', nameCtrl),
                const SizedBox(height: 10),
                buildAdminTextField('Phone', phoneCtrl, keyboardType: TextInputType.phone),
                const SizedBox(height: 10),
                buildAdminTextField('Address', addressCtrl),
                if (customer.belongsToTeam('JA')) ...[
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    value: selectedBeatIdJA,
                    decoration: InputDecoration(labelText: 'JA Beat', border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
                    items: [
                      DropdownMenuItem<String?>(value: null, child: Text('No Beat', style: GoogleFonts.manrope(fontSize: 13))),
                      ..._beatsJA.map((b) => DropdownMenuItem<String?>(value: b.id, child: Text(b.beatName, style: GoogleFonts.manrope(fontSize: 13)))),
                    ],
                    onChanged: (v) => setDlg(() => selectedBeatIdJA = v),
                  ),
                ],
                if (customer.belongsToTeam('MA')) ...[
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    value: selectedBeatIdMA,
                    decoration: InputDecoration(labelText: 'MA Beat', border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
                    items: [
                      DropdownMenuItem<String?>(value: null, child: Text('No Beat', style: GoogleFonts.manrope(fontSize: 13))),
                      ..._beatsMA.map((b) => DropdownMenuItem<String?>(value: b.id, child: Text(b.beatName, style: GoogleFonts.manrope(fontSize: 13)))),
                    ],
                    onChanged: (v) => setDlg(() => selectedBeatIdMA = v),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.manrope())),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  await SupabaseService.instance.updateCustomer(
                    id: customer.id, name: nameCtrl.text.trim(), phone: phoneCtrl.text.trim(),
                    address: addressCtrl.text.trim(), type: customer.type,
                    beatId: null, beat: '', deliveryRoute: customer.deliveryRoute,
                  );
                  final beatNameJA = _beatsJA.where((b) => b.id == selectedBeatIdJA).map((b) => b.beatName).firstOrNull ?? '';
                  final beatNameMA = _beatsMA.where((b) => b.id == selectedBeatIdMA).map((b) => b.beatName).firstOrNull ?? '';
                  await SupabaseService.instance.client.from('customer_team_profiles').update({
                    'beat_id_ja': selectedBeatIdJA, 'beat_name_ja': beatNameJA,
                    'beat_id_ma': selectedBeatIdMA, 'beat_name_ma': beatNameMA,
                  }).eq('customer_id', customer.id);
                  _loadCustomers();
                  widget.onChanged();
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Customer updated'), backgroundColor: AppTheme.success));
                } catch (e) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
                }
              },
              child: Text('Save', style: GoogleFonts.manrope(color: Colors.white)),
            ),
          ],
        ),
      ),
    ).then((_) { nameCtrl.dispose(); phoneCtrl.dispose(); addressCtrl.dispose(); });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (ctx, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: Theme.of(ctx).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Handle bar
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(8)))),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Icon(Icons.route_rounded, color: AppTheme.primary, size: 22),
                const SizedBox(width: 10),
                Expanded(child: Text(widget.beat.beatName, style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis)),
                Text('${_customers.length}', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                const SizedBox(width: 4),
                Icon(Icons.people_rounded, size: 16, color: AppTheme.primary),
              ]),
            ),
            const SizedBox(height: 10),
            // Search
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _searchCtrl,
                style: GoogleFonts.manrope(fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search customers...',
                  hintStyle: GoogleFonts.manrope(fontSize: 13, color: Colors.grey.shade500),
                  prefixIcon: Icon(Icons.search_rounded, color: AppTheme.primary, size: 20),
                  filled: true,
                  fillColor: AppTheme.primary.withValues(alpha: 0.05),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Customer list
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _filtered.isEmpty
                      ? Center(child: Text('No customers found', style: GoogleFonts.manrope(fontSize: 14, color: Colors.grey.shade500)))
                      : ListView.builder(
                          controller: scrollCtrl,
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                          itemCount: _filtered.length,
                          itemBuilder: (_, i) {
                            final c = _filtered[i];
                            final balance = c.outstandingForTeam(AuthService.currentTeam);
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: AppTheme.surface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppTheme.outlineVariant),
                              ),
                              child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                title: Text(c.name, style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (c.phone.isNotEmpty)
                                      Text(c.phone, style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                                    if (balance > 0)
                                      Text('Balance: ₹${balance.toStringAsFixed(0)}', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.red.shade600)),
                                  ],
                                ),
                                trailing: GestureDetector(
                                  onTap: () => _editCustomer(c),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(color: AppTheme.primaryContainer, borderRadius: BorderRadius.circular(8)),
                                    child: Text('Edit', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primary)),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
