import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';
import './admin_shared_widgets.dart';

const _reasons = [
  'Closed',
  'Out of Stock',
  'No Budget',
  'Ordering from Competitor',
  'Not Interested',
];

Color _reasonColor(String reason) {
  switch (reason) {
    case 'Closed':
      return Colors.red.shade600;
    case 'Out of Stock':
      return Colors.orange.shade600;
    case 'No Budget':
      return Colors.amber.shade700;
    case 'Ordering from Competitor':
      return Colors.purple.shade600;
    case 'Not Interested':
      return Colors.grey.shade600;
    default:
      return AppTheme.primary;
  }
}

IconData _reasonIcon(String reason) {
  switch (reason) {
    case 'Closed':
      return Icons.lock_outline_rounded;
    case 'Out of Stock':
      return Icons.inventory_2_outlined;
    case 'No Budget':
      return Icons.money_off_rounded;
    case 'Ordering from Competitor':
      return Icons.storefront_outlined;
    case 'Not Interested':
      return Icons.thumb_down_outlined;
    default:
      return Icons.help_outline_rounded;
  }
}

class AdminVisitsTab extends StatefulWidget {
  const AdminVisitsTab({super.key});

  @override
  State<AdminVisitsTab> createState() => _AdminVisitsTabState();
}

class _AdminVisitsTabState extends State<AdminVisitsTab> {
  List<VisitLogModel> _visits = [];
  List<BeatModel> _beats = [];
  bool _isLoading = true;

  // Filters
  DateTime? _startDate;
  DateTime? _endDate;
  String? _selectedBeatId;
  String? _selectedReason;

  // Team scope — 'All' drops the team filter so super_admin sees visits
  // from both JA and MA reps at once.
  String _teamFilter = 'All';

  // Pagination
  static const _pageSize = 50;
  bool _loadingMore = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _loadBeats();
    _loadVisits();
  }

  Future<void> _loadBeats() async {
    try {
      final beats = await SupabaseService.instance.getBeats();
      if (mounted) setState(() => _beats = beats);
    } catch (_) {}
  }

  Future<void> _loadVisits({bool forceRefresh = false}) async {
    setState(() { _isLoading = true; _hasMore = true; });
    try {
      final visits = await SupabaseService.instance.getVisitLogs(
        startDate: _startDate,
        endDate: _endDate,
        beatId: _selectedBeatId,
        reason: _selectedReason,
        limit: _pageSize,
        offset: 0,
        forceRefresh: forceRefresh,
        teamId: _teamFilter == 'All' ? null : _teamFilter,
      );
      if (mounted) setState(() {
        _visits = visits;
        _isLoading = false;
        _hasMore = visits.length >= _pageSize;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final moreVisits = await SupabaseService.instance.getVisitLogs(
        startDate: _startDate,
        endDate: _endDate,
        beatId: _selectedBeatId,
        reason: _selectedReason,
        limit: _pageSize,
        offset: _visits.length,
        teamId: _teamFilter == 'All' ? null : _teamFilter,
      );
      if (mounted) setState(() {
        _visits.addAll(moreVisits);
        _loadingMore = false;
        _hasMore = moreVisits.length >= _pageSize;
      });
    } catch (e) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _clearFilters() {
    setState(() {
      _startDate = null;
      _endDate = null;
      _selectedBeatId = null;
      _selectedReason = null;
    });
    _loadVisits();
  }

  bool get _hasFilters =>
      _startDate != null || _endDate != null ||
      _selectedBeatId != null || _selectedReason != null;

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.light(primary: AppTheme.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() => _startDate = picked);
      _loadVisits();
    }
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: _startDate ?? DateTime(2020),
      lastDate: DateTime.now(),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.light(primary: AppTheme.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() => _endDate = picked);
      _loadVisits();
    }
  }

  String _fmt(DateTime? d) {
    if (d == null) return 'Any';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  // ── Derived stats ──────────────────────────────────────────────
  int get _totalVisits => _visits.length;

  int get _uniqueCustomers =>
      _visits.map((v) => v.customerId).toSet().length;

  int get _activeReps =>
      _visits.map((v) => v.repEmail).toSet().length;

  String get _topReason {
    if (_visits.isEmpty) return '—';
    final counts = <String, int>{};
    for (final v in _visits) { counts[v.reason] = (counts[v.reason] ?? 0) + 1; }
    return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  Map<String, int> get _reasonCounts {
    final counts = <String, int>{for (final r in _reasons) r: 0};
    for (final v in _visits) {
      if (counts.containsKey(v.reason)) counts[v.reason] = counts[v.reason]! + 1;
    }
    return counts;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: RefreshIndicator(
        onRefresh: _loadVisits,
        color: AppTheme.primary,
        child: CustomScrollView(
          slivers: [
            // Team scope picker — 'All' = cross-team visits.
            SliverToBoxAdapter(
              child: TeamFilterChips(
                value: _teamFilter,
                onChanged: (v) {
                  setState(() => _teamFilter = v);
                  _loadVisits(forceRefresh: true);
                },
              ),
            ),
            // ── Filter bar ─────────────────────────────────────
            SliverToBoxAdapter(child: _buildFilterBar()),

            // ── Stats cards ────────────────────────────────────
            if (!_isLoading)
              SliverToBoxAdapter(child: _buildStatsRow()),

            // ── Bar chart ──────────────────────────────────────
            if (!_isLoading && _visits.isNotEmpty)
              SliverToBoxAdapter(child: _buildChart()),

            // ── Visit list ─────────────────────────────────────
            if (_isLoading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (_visits.isEmpty)
              SliverToBoxAdapter(child: _buildEmpty())
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, i) => _VisitCard(visit: _visits[i]),
                    childCount: _visits.length,
                  ),
                ),
              ),
            if (!_isLoading && _hasMore && _visits.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                  child: _loadingMore
                      ? const Center(child: Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(),
                        ))
                      : OutlinedButton.icon(
                          onPressed: _loadMore,
                          icon: const Icon(Icons.expand_more_rounded),
                          label: Text('Load More Visits',
                              style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.primary,
                            side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.3)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            minimumSize: const Size(double.infinity, 44),
                          ),
                        ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }

  // ── Filter bar ────────────────────────────────────────────────
  Widget _buildFilterBar() {
    return Container(
      color: AppTheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Date row
          Row(
            children: [
              Expanded(
                child: _FilterChip(
                  icon: Icons.calendar_today_rounded,
                  label: 'From: ${_fmt(_startDate)}',
                  active: _startDate != null,
                  onTap: _pickStartDate,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _FilterChip(
                  icon: Icons.calendar_month_rounded,
                  label: 'To: ${_fmt(_endDate)}',
                  active: _endDate != null,
                  onTap: _pickEndDate,
                ),
              ),
              if (_hasFilters) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _clearFilters,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  color: AppTheme.error,
                  tooltip: 'Clear filters',
                  style: IconButton.styleFrom(
                    backgroundColor: AppTheme.error.withValues(alpha: 0.1),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          // Beat chips
          if (_beats.isNotEmpty) ...[
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _beatChip(null, 'All Beats'),
                  ..._beats.map((b) => _beatChip(b.id, b.beatName)),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          // Reason chips
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _reasonFilterChip(null, 'All Reasons'),
                ..._reasons.map((r) => _reasonFilterChip(r, r)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _beatChip(String? beatId, String label) {
    final selected = _selectedBeatId == beatId;
    return GestureDetector(
      onTap: () {
        setState(() => _selectedBeatId = beatId);
        _loadVisits();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary : AppTheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: GoogleFonts.manrope(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppTheme.primary,
          ),
        ),
      ),
    );
  }

  Widget _reasonFilterChip(String? reason, String label) {
    final selected = _selectedReason == reason;
    final color = reason != null ? _reasonColor(reason) : AppTheme.primary;
    return GestureDetector(
      onTap: () {
        setState(() => _selectedReason = reason);
        _loadVisits();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color : color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: GoogleFonts.manrope(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : color,
          ),
        ),
      ),
    );
  }

  // ── Stats cards ───────────────────────────────────────────────
  Widget _buildStatsRow() {
    final topR = _topReason;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        children: [
          Expanded(child: _StatCard(label: 'Total Visits', value: '$_totalVisits',
              icon: Icons.location_on_rounded, color: AppTheme.primary)),
          const SizedBox(width: 10),
          Expanded(child: _StatCard(label: 'Customers', value: '$_uniqueCustomers',
              icon: Icons.people_rounded, color: AppTheme.secondary)),
          const SizedBox(width: 10),
          Expanded(child: _StatCard(label: 'Reps', value: '$_activeReps',
              icon: Icons.badge_outlined, color: AppTheme.success)),
          const SizedBox(width: 10),
          Expanded(child: _StatCard(
            label: 'Top Reason',
            value: topR == '—' ? '—' : topR.split(' ').first,
            icon: topR == '—' ? Icons.help_outline : _reasonIcon(topR),
            color: topR == '—' ? Colors.grey : _reasonColor(topR),
          )),
        ],
      ),
    );
  }

  // ── Bar chart ─────────────────────────────────────────────────
  Widget _buildChart() {
    final counts = _reasonCounts;
    final maxVal = counts.values.fold(0, (m, v) => v > m ? v : m).toDouble();
    if (maxVal == 0) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade100),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Visits by Reason',
              style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          SizedBox(
            height: 160,
            child: BarChart(
              BarChartData(
                maxY: maxVal * 1.3,
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, meta) {
                        final idx = value.toInt();
                        if (idx < 0 || idx >= _reasons.length) return const SizedBox();
                        final count = counts[_reasons[idx]] ?? 0;
                        if (count == 0) return const SizedBox();
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text('$count',
                              style: GoogleFonts.manrope(
                                  fontSize: 11, fontWeight: FontWeight.w700,
                                  color: _reasonColor(_reasons[idx]))),
                        );
                      },
                      reservedSize: 22,
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, meta) {
                        final idx = value.toInt();
                        if (idx < 0 || idx >= _reasons.length) return const SizedBox();
                        final short = _reasons[idx].split(' ').first;
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(short,
                              style: GoogleFonts.manrope(
                                  fontSize: 10, fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade600)),
                        );
                      },
                      reservedSize: 28,
                    ),
                  ),
                ),
                barGroups: List.generate(_reasons.length, (i) {
                  final count = counts[_reasons[i]] ?? 0;
                  return BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: count.toDouble(),
                        color: _reasonColor(_reasons[i]),
                        width: 28,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                      ),
                    ],
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_off_outlined, size: 56, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('No visits found',
                style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w600,
                    color: Colors.grey.shade400)),
            const SizedBox(height: 4),
            Text(_hasFilters ? 'Try adjusting the filters' : 'Visits will appear here once logged',
                style: GoogleFonts.manrope(fontSize: 13, color: Colors.grey.shade400)),
          ],
        ),
      ),
    );
  }
}

// ── Filter Chip button ────────────────────────────────────────────────────────
class _FilterChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _FilterChip({
    required this.icon, required this.label,
    required this.active, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? AppTheme.primary.withValues(alpha: 0.1) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? AppTheme.primary : Colors.grey.shade300,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: active ? AppTheme.primary : Colors.grey.shade500),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.manrope(
                  fontSize: 12, fontWeight: FontWeight.w600,
                  color: active ? AppTheme.primary : Colors.grey.shade600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Stat Card ─────────────────────────────────────────────────────────────────
class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.label, required this.value,
    required this.icon, required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 8),
          Text(value,
              style: GoogleFonts.manrope(
                  fontSize: 20, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: GoogleFonts.manrope(
                  fontSize: 10, fontWeight: FontWeight.w600,
                  color: Colors.grey.shade500)),
        ],
      ),
    );
  }
}

// ── Visit Card ────────────────────────────────────────────────────────────────
class _VisitCard extends StatelessWidget {
  final VisitLogModel visit;

  const _VisitCard({required this.visit});

  @override
  Widget build(BuildContext context) {
    final color = _reasonColor(visit.reason);
    final repShort = visit.repEmail.contains('@')
        ? visit.repEmail.split('@').first
        : visit.repEmail;
    final dt = visit.createdAt.toLocal();
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final timeStr =
        '${dt.day} ${months[dt.month - 1]} · ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 1.2),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Color indicator
            Container(
              width: 4,
              height: 56,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 12),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          visit.customerName,
                          style: GoogleFonts.manrope(
                              fontSize: 14, fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(timeStr,
                          style: GoogleFonts.manrope(
                              fontSize: 11, color: Colors.grey.shade500)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.route_rounded, size: 12, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Text(visit.beatName,
                          style: GoogleFonts.manrope(
                              fontSize: 12, color: Colors.grey.shade600)),
                      const SizedBox(width: 12),
                      Icon(Icons.person_outline_rounded, size: 12, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Text(repShort,
                          style: GoogleFonts.manrope(
                              fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Reason badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_reasonIcon(visit.reason), size: 12, color: color),
                        const SizedBox(width: 5),
                        Text(
                          visit.reason,
                          style: GoogleFonts.manrope(
                            fontSize: 11, fontWeight: FontWeight.w700, color: color,
                          ),
                        ),
                      ],
                    ),
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
