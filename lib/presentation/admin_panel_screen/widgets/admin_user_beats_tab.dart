import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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
  String _repFilter = 'All'; // 'All', rep name, or 'Unassigned'

  static const _allDays = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
  static const _dayShort = {'monday': 'M', 'tuesday': 'T', 'wednesday': 'W', 'thursday': 'Th', 'friday': 'F', 'saturday': 'S', 'sunday': 'Su'};

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
      final assignments = await SupabaseService.instance.getBeatAssignments(allTeams: true);
      final weekdaysMap = await SupabaseService.instance.getUserBeatWeekdays();
      final allUsers = await SupabaseService.instance.getAppUsers(allTeams: true);
      final reps = allUsers.where((u) => (u.role == 'sales_rep' || u.role == 'brand_rep') && u.isActive).toList();
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
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _applyFilter() {
    setState(() {
      if (_repFilter == 'All') {
        _filteredBeats = _beats;
      } else if (_repFilter == 'Unassigned') {
        _filteredBeats = _beats.where((b) => (_assignments[b.id] ?? []).isEmpty).toList();
      } else {
        // Filter by rep name
        _filteredBeats = _beats.where((b) {
          final reps = _assignments[b.id] ?? [];
          return reps.any((r) => (r.fullName.isNotEmpty ? r.fullName : r.email) == _repFilter);
        }).toList();
      }
    });
  }

  Future<void> _removeRepFromBeat(String userId, String beatId) async {
    try {
      await SupabaseService.instance.removeUserFromBeat(userId, beatId);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e'),
          backgroundColor: AppTheme.error,
        ));
      }
    }
  }

  void _showAddRepSheet(BeatModel beat) {
    final assignedIds =
        (_assignments[beat.id] ?? []).map((u) => u.id).toSet();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
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
            const SizedBox(height: 16),
            Text(
              'Add Rep to ${beat.beatName}',
              style: GoogleFonts.manrope(
                  fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap a rep to assign them to this beat',
              style: GoogleFonts.manrope(
                  fontSize: 12, color: AppTheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (_allReps.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No active sales reps found.',
                  style: GoogleFonts.manrope(
                      fontSize: 13, color: AppTheme.onSurfaceVariant),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.5,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _allReps.length,
                  itemBuilder: (_, i) {
                    final rep = _allReps[i];
                    final alreadyAssigned = assignedIds.contains(rep.id);
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: alreadyAssigned
                            ? Colors.grey.shade200
                            : AppTheme.primaryContainer,
                        child: Text(
                          rep.fullName.isNotEmpty
                              ? rep.fullName[0].toUpperCase()
                              : rep.email[0].toUpperCase(),
                          style: GoogleFonts.manrope(
                            fontWeight: FontWeight.w700,
                            color: alreadyAssigned
                                ? Colors.grey.shade400
                                : AppTheme.primary,
                          ),
                        ),
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              rep.fullName.isNotEmpty ? rep.fullName : rep.email,
                              style: GoogleFonts.manrope(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: alreadyAssigned
                                    ? Colors.grey.shade400
                                    : AppTheme.onSurface,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (rep.teamId != beat.teamId) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: rep.teamId == 'JA' ? Colors.blue.withValues(alpha: 0.12) : Colors.orange.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                rep.teamId,
                                style: GoogleFonts.manrope(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: rep.teamId == 'JA' ? Colors.blue : Colors.orange,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        alreadyAssigned
                            ? 'Already assigned to this beat'
                            : '${rep.email}${rep.teamId != beat.teamId ? ' • Cross-team' : ''}',
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          color: alreadyAssigned
                              ? Colors.grey.shade400
                              : AppTheme.onSurfaceVariant,
                        ),
                      ),
                      trailing: alreadyAssigned
                          ? Icon(Icons.check_circle_rounded,
                              color: Colors.grey.shade300, size: 20)
                          : Icon(Icons.add_circle_outline_rounded,
                              color: AppTheme.primary, size: 20),
                      onTap: alreadyAssigned
                          ? null
                          : () async {
                              Navigator.pop(ctx);
                              try {
                                await SupabaseService.instance
                                    .addUserToBeat(rep.id, beat.id);
                                await _load();
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '${rep.fullName.isNotEmpty ? rep.fullName : rep.email} assigned to ${beat.beatName}',
                                      ),
                                      backgroundColor: AppTheme.success,
                                    ),
                                  );
                                }
                              } catch (e) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Error: $e'),
                                      backgroundColor: AppTheme.error,
                                    ),
                                  );
                                }
                              }
                            },
                    );
                  },
                ),
              ),
          ],
        ),
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
          title: Text('${rep.fullName}\n${beat.beatName}', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 14)),
          content: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _allDays.map((day) {
              final isSelected = selected.contains(day);
              return FilterChip(
                label: Text(day[0].toUpperCase() + day.substring(1), style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
                selected: isSelected,
                selectedColor: AppTheme.primary.withValues(alpha: 0.2),
                checkmarkColor: AppTheme.primary,
                onSelected: (v) => setDialogState(() => v ? selected.add(day) : selected.remove(day)),
              );
            }).toList(),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.manrope())),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  await SupabaseService.instance.updateUserBeatWeekdays(rep.id, beat.id, selected.toList());
                  _load();
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Schedule updated for ${rep.fullName}'), backgroundColor: AppTheme.success),
                  );
                } catch (e) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
                  );
                }
              },
              child: Text('Save', style: GoogleFonts.manrope(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRepChip(String label) {
    final selected = _repFilter == label;
    final isUnassigned = label == 'Unassigned';
    final unassignedCount = isUnassigned
        ? _beats.where((b) => (_assignments[b.id] ?? []).isEmpty).length
        : 0;
    final chipColor = isUnassigned ? Colors.red : AppTheme.primary;
    final displayLabel = isUnassigned && unassignedCount > 0 ? '$label ($unassignedCount)' : label;

    return GestureDetector(
      onTap: () {
        _repFilter = label;
        _applyFilter();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? chipColor : chipColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? chipColor : chipColor.withValues(alpha: 0.3), width: 1),
        ),
        child: Text(
          displayLabel,
          style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w700, color: selected ? Colors.white : chipColor),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return AdminErrorRetry(message: _error!, onRetry: _load);

    // Build rep name list for chips
    final repNames = <String>{};
    for (final reps in _assignments.values) {
      for (final r in reps) {
        repNames.add(r.fullName.isNotEmpty ? r.fullName : r.email);
      }
    }
    final chipLabels = ['All', ...repNames.toList()..sort(), 'Unassigned'];

    return Column(
      children: [
        // ── Filter chips ─────────────────────────────────────
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
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
        // ── Beat list ────────────────────────────────────────
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            color: AppTheme.primary,
            child: _filteredBeats.isEmpty
                ? Center(
                    child: Text(
                      _beats.isEmpty ? 'No beats found. Add beats first.' : 'No beats match this filter.',
                      style: GoogleFonts.manrope(fontSize: 14, color: AppTheme.onSurfaceVariant),
                    ),
                  )
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

class _BeatRepCard extends StatelessWidget {
  final BeatModel beat;
  final List<AppUserModel> assignedReps;
  final Map<String, List<String>> userBeatWeekdays;
  final VoidCallback onAddRep;
  final void Function(String userId) onRemoveRep;
  final void Function(AppUserModel rep) onEditWeekdays;

  static const _dayShort = {'monday': 'M', 'tuesday': 'T', 'wednesday': 'W', 'thursday': 'Th', 'friday': 'F', 'saturday': 'S', 'sunday': 'Su'};

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
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(6),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Beat header ────────────────────────────────────
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.route_rounded,
                      color: AppTheme.primary, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        beat.beatName,
                        style: GoogleFonts.manrope(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.onSurface,
                        ),
                      ),
                      Text(
                        beat.beatCode,
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          color: AppTheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: onAddRep,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.person_add_rounded,
                            color: Colors.white, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          'Add Rep',
                          style: GoogleFonts.manrope(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            // ── Weekdays ────────────────────────────────────────
            if (beat.weekdays.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.calendar_today_rounded,
                      size: 12, color: AppTheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(
                    beat.weekdays.join(', '),
                    style: GoogleFonts.manrope(
                      fontSize: 11,
                      color: AppTheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),

            // ── Assigned Reps ───────────────────────────────────
            if (assignedReps.isEmpty)
              Text(
                'No reps assigned to this beat',
                style: GoogleFonts.manrope(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: AppTheme.onSurfaceVariant,
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: assignedReps.map((rep) {
                  final displayName = rep.fullName.isNotEmpty
                      ? rep.fullName
                      : rep.email;
                  final wKey = '${beat.id}_${rep.id}';
                  final repWeekdays = userBeatWeekdays[wKey] ?? beat.weekdays;
                  final dayLabel = repWeekdays.map((d) => _dayShort[d.toLowerCase()] ?? d[0].toUpperCase()).join(',');
                  return GestureDetector(
                    onTap: () => onEditWeekdays(rep),
                    child: Chip(
                    avatar: CircleAvatar(
                      backgroundColor: AppTheme.primaryContainer,
                      child: Text(
                        displayName[0].toUpperCase(),
                        style: GoogleFonts.manrope(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primary,
                        ),
                      ),
                    ),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          displayName,
                          style: GoogleFonts.manrope(
                              fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        if (dayLabel.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppTheme.secondary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              dayLabel,
                              style: GoogleFonts.manrope(fontSize: 8, fontWeight: FontWeight.w700,
                                color: AppTheme.secondary),
                            ),
                          ),
                        ],
                        if (rep.teamId != beat.teamId) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: rep.teamId == 'JA' ? Colors.blue.withValues(alpha: 0.15) : Colors.orange.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              rep.teamId,
                              style: GoogleFonts.manrope(fontSize: 8, fontWeight: FontWeight.w800,
                                color: rep.teamId == 'JA' ? Colors.blue : Colors.orange),
                            ),
                          ),
                        ],
                      ],
                    ),
                    deleteIcon: const Icon(Icons.close_rounded, size: 14),
                    onDeleted: () => onRemoveRep(rep.id),
                    backgroundColor: AppTheme.primaryContainer,
                    side: const BorderSide(color: AppTheme.outline, width: 0.5),
                    deleteIconColor: AppTheme.primary,
                    labelStyle: GoogleFonts.manrope(
                        fontSize: 12, color: AppTheme.onSurface),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
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
}
