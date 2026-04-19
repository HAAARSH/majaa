import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/search_utils.dart';
import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';
import './admin_shared_widgets.dart';

class AdminUserBeatsTab extends StatefulWidget {
  const AdminUserBeatsTab({super.key});

  @override
  State<AdminUserBeatsTab> createState() => _AdminUserBeatsTabState();
}

class _AdminUserBeatsTabState extends State<AdminUserBeatsTab> {
  bool _isLoading = true;
  List<BeatModel> _beats = [];
  List<BeatModel> _filteredBeats = [];
  Map<String, List<AppUserModel>> _assignments = {};
  Map<String, List<String>> _userBeatWeekdays = {}; // key: beatId_userId
  List<AppUserModel> _allReps = [];
  String? _error;
  String _repFilter = 'All';
  String _searchQuery = '';
  bool _repCentricView = false;
  AppUserModel? _selectedRep; // for rep-centric view

  static const _allDays = [
    'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'
  ];
  static const _dayShort = {
    'monday': 'M', 'tuesday': 'T', 'wednesday': 'W',
    'thursday': 'Th', 'friday': 'F', 'saturday': 'S', 'sunday': 'Su'
  };

  // Role colors
  static const _salesRepColor = Color(0xFF2196F3); // blue
  static const _brandRepColor = Color(0xFFFF9800); // orange

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final results = await Future.wait([
        SupabaseService.instance.getBeats(),
        SupabaseService.instance.getBeatAssignments(allTeams: true),
        SupabaseService.instance.getUserBeatWeekdays(),
        SupabaseService.instance.getAppUsers(allTeams: true),
      ]);
      final beats = results[0] as List<BeatModel>;
      final assignments = results[1] as Map<String, List<AppUserModel>>;
      final weekdaysMap = results[2] as Map<String, List<String>>;
      final allUsers = results[3] as List<AppUserModel>;
      final reps = allUsers
          .where((u) => (u.role == 'sales_rep' || u.role == 'brand_rep') && u.isActive)
          .toList();
      beats.sort((a, b) => a.beatName.toLowerCase().compareTo(b.beatName.toLowerCase()));
      reps.sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _beats = beats;
        _assignments = assignments;
        _userBeatWeekdays = weekdaysMap;
        _allReps = reps;
        _isLoading = false;
      });
      _applyFilter();
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  void _applyFilter() {
    setState(() {
      var list = _beats.toList();
      // Tokenized text search
      if (_searchQuery.trim().isNotEmpty) {
        list = list
            .where((b) => tokenMatch(_searchQuery, [b.beatName, b.beatCode]))
            .toList();
      }
      // Rep filter
      if (_repFilter == 'Unassigned') {
        list = list.where((b) => (_assignments[b.id] ?? []).isEmpty).toList();
      } else if (_repFilter != 'All') {
        list = list.where((b) {
          final reps = _assignments[b.id] ?? [];
          return reps.any((r) => (r.fullName.isNotEmpty ? r.fullName : r.email) == _repFilter);
        }).toList();
      }
      _filteredBeats = list;
    });
  }

  // ── Optimistic add ──────────────────────────────────────────
  Future<void> _addRepToBeat(AppUserModel rep, BeatModel beat, List<String> weekdays) async {
    // Optimistic update
    setState(() {
      _assignments.putIfAbsent(beat.id, () => []);
      _assignments[beat.id]!.add(rep);
      if (weekdays.isNotEmpty) {
        _userBeatWeekdays['${beat.id}_${rep.id}'] = weekdays;
      }
    });
    _applyFilter();
    try {
      await SupabaseService.instance.addUserToBeat(rep.id, beat.id,
          weekdays: weekdays.isNotEmpty ? weekdays : null);
    } catch (e) {
      // Rollback
      setState(() {
        _assignments[beat.id]?.removeWhere((r) => r.id == rep.id);
        _userBeatWeekdays.remove('${beat.id}_${rep.id}');
      });
      _applyFilter();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  // ── Optimistic remove ───────────────────────────────────────
  Future<void> _removeRepFromBeat(String userId, String beatId) async {
    final removedRep = _assignments[beatId]?.firstWhere((r) => r.id == userId);
    final removedWeekdays = _userBeatWeekdays['${beatId}_$userId'];
    // Optimistic
    setState(() {
      _assignments[beatId]?.removeWhere((r) => r.id == userId);
      _userBeatWeekdays.remove('${beatId}_$userId');
    });
    _applyFilter();
    try {
      await SupabaseService.instance.removeUserFromBeat(userId, beatId);
    } catch (e) {
      // Rollback
      if (removedRep != null) {
        setState(() {
          _assignments.putIfAbsent(beatId, () => []);
          _assignments[beatId]!.add(removedRep);
          if (removedWeekdays != null) {
            _userBeatWeekdays['${beatId}_$userId'] = removedWeekdays;
          }
        });
        _applyFilter();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  // ── Optimistic weekday update ───────────────────────────────
  Future<void> _updateWeekdays(String userId, String beatId, List<String> weekdays) async {
    final key = '${beatId}_$userId';
    final old = _userBeatWeekdays[key];
    setState(() { _userBeatWeekdays[key] = weekdays; });
    try {
      await SupabaseService.instance.updateUserBeatWeekdays(userId, beatId, weekdays);
    } catch (e) {
      setState(() {
        if (old != null) { _userBeatWeekdays[key] = old; } else { _userBeatWeekdays.remove(key); }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  // ── Combined Add Rep + Weekday Modal ────────────────────────
  void _showAddRepSheet(BeatModel beat) {
    final assignedIds = (_assignments[beat.id] ?? []).map((u) => u.id).toSet();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AddRepWithWeekdaySheet(
        beat: beat,
        allReps: _allReps,
        assignedIds: assignedIds,
        onAdd: (rep, weekdays) => _addRepToBeat(rep, beat, weekdays),
      ),
    );
  }

  void _showWeekdayPicker(BeatModel beat, AppUserModel rep) {
    final key = '${beat.id}_${rep.id}';
    final current = _userBeatWeekdays[key] ?? List<String>.from(beat.weekdays);
    final selected = Set<String>.from(current);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                _roleIndicator(rep.role, size: 8),
                const SizedBox(width: 6),
                Expanded(child: Text(rep.fullName, style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 14))),
              ]),
              const SizedBox(height: 2),
              Text(beat.beatName, style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
            ],
          ),
          content: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _allDays.map((day) {
              final isSelected = selected.contains(day);
              return FilterChip(
                label: Text(
                  day[0].toUpperCase() + day.substring(1),
                  style: GoogleFonts.manrope(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isSelected ? Colors.white : AppTheme.primary,
                  ),
                ),
                selected: isSelected,
                backgroundColor: Colors.white,
                selectedColor: AppTheme.primary,
                checkmarkColor: Colors.white,
                side: BorderSide(
                  color: isSelected ? AppTheme.primary : AppTheme.primary.withValues(alpha: 0.5),
                  width: 1.2,
                ),
                onSelected: (v) => setDialogState(() => v ? selected.add(day) : selected.remove(day)),
              );
            }).toList(),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: GoogleFonts.manrope())),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
              onPressed: () {
                Navigator.pop(ctx);
                _updateWeekdays(rep.id, beat.id, selected.toList());
              },
              child: Text('Save', style: GoogleFonts.manrope(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Role indicator dot ──────────────────────────────────────
  static Widget _roleIndicator(String role, {double size = 8}) {
    final color = role == 'brand_rep' ? _brandRepColor : _salesRepColor;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }

  static Color _roleColor(String role) =>
      role == 'brand_rep' ? _brandRepColor : _salesRepColor;

  // ── Filter chip ─────────────────────────────────────────────
  Widget _buildRepChip(String label) {
    final selected = _repFilter == label;
    final isUnassigned = label == 'Unassigned';
    final unassignedCount = isUnassigned
        ? _beats.where((b) => (_assignments[b.id] ?? []).isEmpty).length
        : 0;
    final chipColor = isUnassigned ? Colors.red : AppTheme.primary;
    final displayLabel = isUnassigned && unassignedCount > 0 ? '$label ($unassignedCount)' : label;

    return GestureDetector(
      onTap: () { _repFilter = label; _applyFilter(); },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? chipColor : chipColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? chipColor : chipColor.withValues(alpha: 0.3), width: 1),
        ),
        child: Text(displayLabel,
          style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w700,
              color: selected ? Colors.white : chipColor)),
      ),
    );
  }

  // ── Rep-centric view: toggle beats for selected rep ─────────
  Widget _buildRepCentricView() {
    if (_selectedRep == null) {
      return Column(
        children: [
          _buildSearchAndViewToggle(),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Select a rep to manage their beats',
              style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _allReps.length,
              itemBuilder: (_, i) {
                final rep = _allReps[i];
                final assignedCount = _beats.where((b) =>
                    (_assignments[b.id] ?? []).any((r) => r.id == rep.id)).length;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _roleColor(rep.role).withValues(alpha: 0.15),
                    child: Text(
                      rep.fullName.isNotEmpty ? rep.fullName[0].toUpperCase() : '?',
                      style: GoogleFonts.manrope(fontWeight: FontWeight.w700, color: _roleColor(rep.role)),
                    ),
                  ),
                  title: Row(children: [
                    _roleIndicator(rep.role),
                    const SizedBox(width: 6),
                    Expanded(child: Text(rep.fullName.isNotEmpty ? rep.fullName : rep.email,
                      style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600))),
                  ]),
                  subtitle: Text(
                    '${rep.role == 'brand_rep' ? 'Brand Rep' : 'Sales Rep'} · $assignedCount beat${assignedCount == 1 ? '' : 's'} · ${rep.teamId}',
                    style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded, size: 20),
                  onTap: () => setState(() => _selectedRep = rep),
                );
              },
            ),
          ),
        ],
      );
    }

    // Show beats as checkboxes for selected rep
    final rep = _selectedRep!;
    final assignedBeatIds = <String>{};
    for (final entry in _assignments.entries) {
      if (entry.value.any((r) => r.id == rep.id)) assignedBeatIds.add(entry.key);
    }

    var beatsToShow = _beats.toList();
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      beatsToShow = beatsToShow.where((b) =>
          b.beatName.toLowerCase().contains(q) ||
          b.beatCode.toLowerCase().contains(q)).toList();
    }

    return Column(
      children: [
        _buildSearchAndViewToggle(),
        // Rep header
        Container(
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _roleColor(rep.role).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _roleColor(rep.role).withValues(alpha: 0.3)),
          ),
          child: Row(children: [
            CircleAvatar(
              backgroundColor: _roleColor(rep.role).withValues(alpha: 0.2),
              child: Text(rep.fullName.isNotEmpty ? rep.fullName[0].toUpperCase() : '?',
                style: GoogleFonts.manrope(fontWeight: FontWeight.w700, color: _roleColor(rep.role))),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(rep.fullName.isNotEmpty ? rep.fullName : rep.email,
                  style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700)),
                Text('${rep.role == 'brand_rep' ? 'Brand Rep' : 'Sales Rep'} · ${assignedBeatIds.length} beats · ${rep.teamId}',
                  style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
              ],
            )),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () => setState(() => _selectedRep = null),
            ),
          ]),
        ),
        // Beat checkboxes
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            itemCount: beatsToShow.length,
            itemBuilder: (_, i) {
              final beat = beatsToShow[i];
              final isAssigned = assignedBeatIds.contains(beat.id);
              final wKey = '${beat.id}_${rep.id}';
              final repWeekdays = _userBeatWeekdays[wKey] ?? beat.weekdays;
              final dayLabel = repWeekdays.map((d) => _dayShort[d.toLowerCase()] ?? d[0].toUpperCase()).join(', ');

              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: isAssigned ? _roleColor(rep.role).withValues(alpha: 0.04) : AppTheme.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isAssigned ? _roleColor(rep.role).withValues(alpha: 0.3) : AppTheme.outlineVariant,
                  ),
                ),
                child: CheckboxListTile(
                  value: isAssigned,
                  activeColor: _roleColor(rep.role),
                  title: Text(beat.beatName,
                    style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600)),
                  subtitle: Row(children: [
                    Text(beat.beatCode, style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant)),
                    if (isAssigned) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => _showWeekdayPicker(beat, rep),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.secondary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.edit_calendar_rounded, size: 10, color: AppTheme.secondary),
                            const SizedBox(width: 3),
                            Text(dayLabel, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w700, color: AppTheme.secondary)),
                          ]),
                        ),
                      ),
                    ],
                  ]),
                  onChanged: (v) async {
                    if (v == true) {
                      await _addRepToBeat(rep, beat, []);
                    } else {
                      await _removeRepFromBeat(rep.id, beat.id);
                    }
                  },
                  controlAffinity: ListTileControlAffinity.trailing,
                  dense: true,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ── Search bar + view toggle ────────────────────────────────
  Widget _buildSearchAndViewToggle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 38,
              child: TextField(
                onChanged: (v) { _searchQuery = v; _applyFilter(); },
                style: GoogleFonts.manrope(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search beats...',
                  hintStyle: GoogleFonts.manrope(fontSize: 12, color: Colors.grey.shade400),
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.grey.shade50,
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppTheme.outlineVariant),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppTheme.outlineVariant),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppTheme.primary, width: 1.5),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            decoration: BoxDecoration(
              color: _repCentricView ? AppTheme.primary.withValues(alpha: 0.1) : Colors.grey.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _repCentricView ? AppTheme.primary : AppTheme.outlineVariant),
            ),
            child: IconButton(
              icon: Icon(
                _repCentricView ? Icons.person_rounded : Icons.route_rounded,
                size: 18,
                color: _repCentricView ? AppTheme.primary : AppTheme.onSurfaceVariant,
              ),
              constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
              padding: EdgeInsets.zero,
              tooltip: _repCentricView ? 'Switch to beat view' : 'Switch to rep view',
              onPressed: () => setState(() {
                _repCentricView = !_repCentricView;
                _selectedRep = null;
              }),
            ),
          ),
        ],
      ),
    );
  }

  // ── Legend ───────────────────────────────────────────────────
  Widget _buildLegend() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Row(children: [
        _roleIndicator('sales_rep'),
        const SizedBox(width: 4),
        Text('Sales Rep', style: GoogleFonts.manrope(fontSize: 10, color: _salesRepColor, fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        _roleIndicator('brand_rep'),
        const SizedBox(width: 4),
        Text('Brand Rep', style: GoogleFonts.manrope(fontSize: 10, color: _brandRepColor, fontWeight: FontWeight.w600)),
        const Spacer(),
        Text('Tap rep chip to edit schedule',
          style: GoogleFonts.manrope(fontSize: 9, color: Colors.grey.shade400, fontStyle: FontStyle.italic)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return AdminErrorRetry(message: _error!, onRetry: _load);

    if (_repCentricView) return _buildRepCentricView();

    // Beat-centric view
    final repNames = <String>{};
    for (final reps in _assignments.values) {
      for (final r in reps) {
        repNames.add(r.fullName.isNotEmpty ? r.fullName : r.email);
      }
    }
    final chipLabels = ['All', ...repNames.toList()..sort(), 'Unassigned'];

    return Column(
      children: [
        _buildSearchAndViewToggle(),
        _buildLegend(),
        // Filter chips
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
            itemCount: chipLabels.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) => _buildRepChip(chipLabels[i]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${_filteredBeats.length} beat${_filteredBeats.length == 1 ? '' : 's'}',
              style: GoogleFonts.manrope(fontSize: 11, color: Colors.grey.shade500, fontWeight: FontWeight.w500),
            ),
          ),
        ),
        // Beat list
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            color: AppTheme.primary,
            child: _filteredBeats.isEmpty
                ? Center(child: Text(
                    _beats.isEmpty ? 'No beats found. Add beats first.' : 'No beats match this filter.',
                    style: GoogleFonts.manrope(fontSize: 14, color: AppTheme.onSurfaceVariant)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: _filteredBeats.length,
                    itemBuilder: (context, index) {
                      final beat = _filteredBeats[index];
                      final assignedReps = _assignments[beat.id] ?? [];
                      return _BeatRepCard(
                        beat: beat,
                        assignedReps: assignedReps,
                        userBeatWeekdays: _userBeatWeekdays,
                        onAddRep: () => _showAddRepSheet(beat),
                        onRemoveRep: (userId) => _removeRepFromBeat(userId, beat.id),
                        onEditWeekdays: (rep) => _showWeekdayPicker(beat, rep),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Combined Add Rep + Weekday Bottom Sheet
// ═══════════════════════════════════════════════════════════════

class _AddRepWithWeekdaySheet extends StatefulWidget {
  final BeatModel beat;
  final List<AppUserModel> allReps;
  final Set<String> assignedIds;
  final Future<void> Function(AppUserModel rep, List<String> weekdays) onAdd;

  const _AddRepWithWeekdaySheet({
    required this.beat,
    required this.allReps,
    required this.assignedIds,
    required this.onAdd,
  });

  @override
  State<_AddRepWithWeekdaySheet> createState() => _AddRepWithWeekdaySheetState();
}

class _AddRepWithWeekdaySheetState extends State<_AddRepWithWeekdaySheet> {
  static const _allDays = [
    'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'
  ];
  static const _dayShort = {
    'monday': 'M', 'tuesday': 'T', 'wednesday': 'W',
    'thursday': 'Th', 'friday': 'F', 'saturday': 'S', 'sunday': 'Su'
  };

  AppUserModel? _pickedRep;
  Set<String> _selectedDays = {};
  String _repSearch = '';

  @override
  void initState() {
    super.initState();
    _selectedDays = Set<String>.from(widget.beat.weekdays);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: Container(
            width: 40, height: 4,
            decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(8)),
          )),
          const SizedBox(height: 16),
          Text('Add Rep to ${widget.beat.beatName}',
            style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(_pickedRep == null
              ? 'Step 1: Select a rep'
              : 'Step 2: Set schedule for ${_pickedRep!.fullName}',
            style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
          const SizedBox(height: 12),

          if (_pickedRep == null) ...[
            // Rep search
            SizedBox(
              height: 36,
              child: TextField(
                onChanged: (v) => setState(() => _repSearch = v),
                style: GoogleFonts.manrope(fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'Search reps...',
                  hintStyle: GoogleFonts.manrope(fontSize: 11, color: Colors.grey.shade400),
                  prefixIcon: const Icon(Icons.search_rounded, size: 16),
                  isDense: true, filled: true, fillColor: Colors.grey.shade50,
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.outlineVariant)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.outlineVariant)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Rep list
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.allReps.length,
                itemBuilder: (_, i) {
                  final rep = widget.allReps[i];
                  if (_repSearch.isNotEmpty) {
                    final q = _repSearch.toLowerCase();
                    if (!rep.fullName.toLowerCase().contains(q) && !rep.email.toLowerCase().contains(q)) {
                      return const SizedBox.shrink();
                    }
                  }
                  final alreadyAssigned = widget.assignedIds.contains(rep.id);
                  final roleColor = rep.role == 'brand_rep'
                      ? _AdminUserBeatsTabState._brandRepColor
                      : _AdminUserBeatsTabState._salesRepColor;
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: alreadyAssigned ? Colors.grey.shade200 : roleColor.withValues(alpha: 0.15),
                      child: Text(
                        rep.fullName.isNotEmpty ? rep.fullName[0].toUpperCase() : rep.email[0].toUpperCase(),
                        style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 12,
                          color: alreadyAssigned ? Colors.grey.shade400 : roleColor),
                      ),
                    ),
                    title: Row(children: [
                      _AdminUserBeatsTabState._roleIndicator(rep.role),
                      const SizedBox(width: 6),
                      Flexible(child: Text(
                        rep.fullName.isNotEmpty ? rep.fullName : rep.email,
                        style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600,
                          color: alreadyAssigned ? Colors.grey.shade400 : AppTheme.onSurface),
                        overflow: TextOverflow.ellipsis,
                      )),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: roleColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          rep.role == 'brand_rep' ? 'Brand' : 'Sales',
                          style: GoogleFonts.manrope(fontSize: 8, fontWeight: FontWeight.w800, color: roleColor),
                        ),
                      ),
                      if (rep.teamId != widget.beat.teamId) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('Cross-team',
                            style: GoogleFonts.manrope(fontSize: 7, fontWeight: FontWeight.w800, color: Colors.red)),
                        ),
                      ],
                    ]),
                    subtitle: alreadyAssigned
                        ? Text('Already assigned', style: GoogleFonts.manrope(fontSize: 10, color: Colors.grey.shade400))
                        : Text(rep.email, style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant)),
                    trailing: alreadyAssigned
                        ? Icon(Icons.check_circle_rounded, color: Colors.grey.shade300, size: 18)
                        : Icon(Icons.arrow_forward_ios_rounded, color: AppTheme.primary, size: 14),
                    onTap: alreadyAssigned ? null : () => setState(() {
                      _pickedRep = rep;
                      _selectedDays = Set<String>.from(widget.beat.weekdays);
                    }),
                  );
                },
              ),
            ),
          ] else ...[
            // Weekday picker
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Schedule', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('Beat default: ${widget.beat.weekdays.map((d) => _dayShort[d.toLowerCase()] ?? d).join(', ')}',
                    style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _allDays.map((day) {
                      final isSelected = _selectedDays.contains(day);
                      return GestureDetector(
                        onTap: () => setState(() => isSelected ? _selectedDays.remove(day) : _selectedDays.add(day)),
                        child: Container(
                          width: 40, height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isSelected ? AppTheme.primary : Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: isSelected ? AppTheme.primary : AppTheme.outlineVariant),
                          ),
                          child: Text(
                            _dayShort[day]!,
                            style: GoogleFonts.manrope(
                              fontSize: 12, fontWeight: FontWeight.w700,
                              color: isSelected ? Colors.white : AppTheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() => _pickedRep = null),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppTheme.outline),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text('Back', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onAdd(_pickedRep!, _selectedDays.toList());
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text('Assign', style: GoogleFonts.manrope(fontWeight: FontWeight.w600, color: Colors.white)),
                ),
              ),
            ]),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Beat Card with Weekday Matrix
// ═══════════════════════════════════════════════════════════════

class _BeatRepCard extends StatelessWidget {
  final BeatModel beat;
  final List<AppUserModel> assignedReps;
  final Map<String, List<String>> userBeatWeekdays;
  final VoidCallback onAddRep;
  final void Function(String userId) onRemoveRep;
  final void Function(AppUserModel rep) onEditWeekdays;

  static const _dayShort = {
    'monday': 'M', 'tuesday': 'T', 'wednesday': 'W',
    'thursday': 'Th', 'friday': 'F', 'saturday': 'S', 'sunday': 'Su'
  };

  const _BeatRepCard({
    required this.beat,
    required this.assignedReps,
    required this.userBeatWeekdays,
    required this.onAddRep,
    required this.onRemoveRep,
    required this.onEditWeekdays,
  });

  @override
  Widget build(BuildContext context) {
    // Check coverage gaps
    final coveredDays = <String>{};
    for (final rep in assignedReps) {
      final wKey = '${beat.id}_${rep.id}';
      final days = userBeatWeekdays[wKey] ?? beat.weekdays;
      coveredDays.addAll(days.map((d) => d.toLowerCase()));
    }
    final beatDays = beat.weekdays.map((d) => d.toLowerCase()).toSet();
    final uncoveredDays = beatDays.difference(coveredDays);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: uncoveredDays.isNotEmpty && assignedReps.isNotEmpty
              ? Colors.orange.withValues(alpha: 0.5)
              : AppTheme.outlineVariant,
        ),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(6), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Beat header
            Row(children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.route_rounded, color: AppTheme.primary, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(beat.beatName,
                    style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.onSurface)),
                  Text(beat.beatCode,
                    style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                ],
              )),
              GestureDetector(
                onTap: onAddRep,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(8)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.person_add_rounded, color: Colors.white, size: 14),
                    const SizedBox(width: 4),
                    Text('Add Rep', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
                  ]),
                ),
              ),
            ]),

            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),

            // Weekday Matrix
            if (assignedReps.isNotEmpty) ...[
              _buildWeekdayMatrix(),
              if (uncoveredDays.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.warning_amber_rounded, size: 12, color: Colors.orange.shade700),
                    const SizedBox(width: 4),
                    Text(
                      'No rep on: ${uncoveredDays.map((d) => _dayShort[d] ?? d).join(', ')}',
                      style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.orange.shade700),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 8),
            ],

            // Assigned Reps as chips
            if (assignedReps.isEmpty)
              Text('No reps assigned to this beat',
                style: GoogleFonts.manrope(fontSize: 12, fontStyle: FontStyle.italic, color: AppTheme.onSurfaceVariant))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: assignedReps.map((rep) {
                  final displayName = rep.fullName.isNotEmpty ? rep.fullName : rep.email;
                  final roleColor = rep.role == 'brand_rep'
                      ? _AdminUserBeatsTabState._brandRepColor
                      : _AdminUserBeatsTabState._salesRepColor;
                  final wKey = '${beat.id}_${rep.id}';
                  final repWeekdays = userBeatWeekdays[wKey] ?? beat.weekdays;
                  final dayLabel = repWeekdays.map((d) => _dayShort[d.toLowerCase()] ?? d[0].toUpperCase()).join(',');

                  return GestureDetector(
                    onTap: () => onEditWeekdays(rep),
                    child: Chip(
                      avatar: CircleAvatar(
                        backgroundColor: roleColor.withValues(alpha: 0.15),
                        child: Text(displayName[0].toUpperCase(),
                          style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: roleColor)),
                      ),
                      label: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(displayName, style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
                        if (dayLabel.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppTheme.secondary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(dayLabel,
                              style: GoogleFonts.manrope(fontSize: 8, fontWeight: FontWeight.w700, color: AppTheme.secondary)),
                          ),
                        ],
                        if (rep.teamId != beat.teamId) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(rep.teamId,
                              style: GoogleFonts.manrope(fontSize: 8, fontWeight: FontWeight.w800, color: Colors.red)),
                          ),
                        ],
                      ]),
                      deleteIcon: const Icon(Icons.close_rounded, size: 14),
                      onDeleted: () => onRemoveRep(rep.id),
                      backgroundColor: roleColor.withValues(alpha: 0.06),
                      side: BorderSide(color: roleColor.withValues(alpha: 0.3), width: 0.5),
                      deleteIconColor: roleColor,
                      labelStyle: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurface),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                      visualDensity: VisualDensity.compact,
                    ),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
  }

  // ── Weekday matrix: days across top, reps as rows ───────────
  Widget _buildWeekdayMatrix() {
    // Collect all days any rep is assigned to (not from beat.weekdays)
    const allDaysOrdered = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
    final usedDays = <String>{};
    for (final rep in assignedReps) {
      final wKey = '${beat.id}_${rep.id}';
      final days = userBeatWeekdays[wKey] ?? beat.weekdays;
      usedDays.addAll(days.map((d) => d.toLowerCase()));
    }
    // Also include beat default days
    usedDays.addAll(beat.weekdays.map((d) => d.toLowerCase()));
    // Keep in correct order
    final activeDays = allDaysOrdered.where((d) => usedDays.contains(d)).toList();
    if (activeDays.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // Day header row
          Row(children: [
            const SizedBox(width: 50),
            ...activeDays.map((day) => Expanded(
              child: Center(child: Text(
                _dayShort[day] ?? day[0].toUpperCase(),
                style: GoogleFonts.manrope(fontSize: 8, fontWeight: FontWeight.w700, color: AppTheme.onSurfaceVariant),
              )),
            )),
          ]),
          const Divider(height: 6),
          // Rep rows
          ...assignedReps.map((rep) {
            final wKey = '${beat.id}_${rep.id}';
            final repDays = (userBeatWeekdays[wKey] ?? beat.weekdays).map((d) => d.toLowerCase()).toSet();
            final roleColor = rep.role == 'brand_rep'
                ? _AdminUserBeatsTabState._brandRepColor
                : _AdminUserBeatsTabState._salesRepColor;
            final name = rep.fullName.isNotEmpty ? rep.fullName : rep.email;
            // Show first name only to save space
            final shortName = name.split(' ').first;

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(children: [
                SizedBox(
                  width: 50,
                  child: Row(children: [
                    Container(width: 5, height: 5, decoration: BoxDecoration(shape: BoxShape.circle, color: roleColor)),
                    const SizedBox(width: 3),
                    Expanded(child: Text(shortName, style: GoogleFonts.manrope(fontSize: 8, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis)),
                  ]),
                ),
                ...activeDays.map((day) => Expanded(
                  child: Center(
                    child: Container(
                      width: 16, height: 16,
                      decoration: BoxDecoration(
                        color: repDays.contains(day)
                            ? roleColor.withValues(alpha: 0.2)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: repDays.contains(day)
                              ? roleColor.withValues(alpha: 0.5)
                              : Colors.grey.shade200,
                          width: 0.5,
                        ),
                      ),
                      child: repDays.contains(day)
                          ? Icon(Icons.check_rounded, size: 10, color: roleColor)
                          : null,
                    ),
                  ),
                )),
              ]),
            );
          }),
        ],
      ),
    );
  }
}
