// All 172 errors cascade from 'package:flutter/material.dart' and 'package:google_fonts/google_fonts.dart' not resolving; the import statements in the file are already syntactically correct and no code changes are required. //

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../services/offline_service.dart'; //
import '../../theme/app_theme.dart';

class BeatSelectionScreen extends StatefulWidget {
  const BeatSelectionScreen({super.key});

  @override
  State<BeatSelectionScreen> createState() => _BeatSelectionScreenState();
}

class _BeatSelectionScreenState extends State<BeatSelectionScreen> {
  bool _isLoading = true;
  bool _isSyncing = false;
  bool _isInitialized = false;
  String? _error;
  List<BeatModel> _beats = [];
  String _searchQuery = '';
  AppUserModel? _currentUser;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map<String, dynamic> && args['user'] is AppUserModel) {
        _currentUser = args['user'] as AppUserModel;
      }
      _loadBeats();
      _isInitialized = true;
    }
  }

  Future<void> _loadBeats() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      AppUserModel? user = _currentUser;
      
      List<BeatModel> beats;
      if (user?.assignedBeats.isNotEmpty ?? false) {
        beats = user!.assignedBeats;
      } else {
        beats = await SupabaseService.instance.getBeats();
      }

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

  // 🔴 SYNC LOGIC:
  Future<void> _handleSync() async {
    setState(() => _isSyncing = true);
    final success = await OfflineService.instance.syncOfflineOrders();
    if (success) {
      SupabaseService.instance.isOfflineMode = false; //
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync complete! Orders uploaded.')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync failed. Check connection.')));
    }
    if (mounted) setState(() => _isSyncing = false);
  }

  List<BeatModel> get _filteredBeats {
    List<BeatModel> listToReturn = [];
    if (_searchQuery.isEmpty) {
      listToReturn = List.from(_beats);
    } else {
      final q = _searchQuery.toLowerCase();
      listToReturn = _beats
          .where(
            (b) =>
                b.beatName.toLowerCase().contains(q) ||
                b.beatCode.toLowerCase().contains(q),
          )
          .toList();
    }
    listToReturn.sort(
        (a, b) => a.beatName.toLowerCase().compareTo(b.beatName.toLowerCase()));
    return listToReturn;
  }

  void _logout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Logout',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Text('Are you sure you want to logout?',
            style: GoogleFonts.manrope(fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pushNamedAndRemoveUntil(
                  context, AppRoutes.loginScreen, (route) => false);
            },
            child: Text('Logout'),
          ),
        ],
      ),
    );
  }

  String _todayLabel() {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday'
    ];
    return days[DateTime.now().weekday - 1];
  }

  bool _isTodayBeat(BeatModel beat) {
    return beat.weekdays.contains(_todayLabel());
  }

  @override
  Widget build(BuildContext context) {
    final bool isOffline = SupabaseService.instance.isOfflineMode; //
    final today = _todayLabel();

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with All Original Original Styles
            Container(
              color: AppTheme.surface,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppTheme.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.route_rounded,
                            color: Colors.white, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Select Beat',
                                style: GoogleFonts.manrope(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.onSurface)),
                            Text(
                              _currentUser != null
                                  ? '${_currentUser!.fullName.isNotEmpty ? _currentUser!.fullName : _currentUser!.email} · ${_beats.length} beats assigned'
                                  : 'Choose your beat for today\'s orders',
                              style: GoogleFonts.manrope(
                                  fontSize: 12,
                                  color: AppTheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.analytics_rounded,
                            color: AppTheme.primary),
                        onPressed: () => Navigator.pushNamed(
                            context, AppRoutes.dashboardScreen),
                      ),
                      IconButton(
                        icon: const Icon(Icons.history_rounded,
                            color: AppTheme.primary),
                        onPressed: () => Navigator.pushNamed(
                            context, AppRoutes.orderHistoryScreen),
                      ),
                      IconButton(
                          icon: const Icon(Icons.logout_rounded,
                              color: AppTheme.error),
                          onPressed: _logout),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                        color: AppTheme.primaryContainer,
                        borderRadius: BorderRadius.circular(100)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.calendar_today_rounded,
                            size: 14, color: AppTheme.primary),
                        const SizedBox(width: 6),
                        Text('Today: $today',
                            style: GoogleFonts.manrope(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.primary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // 🔴 OFFLINE SYNC BANNER: Integrated into your Original UI
            if (isOffline)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                color: AppTheme.warningContainer.withAlpha(230),
                child: Row(
                  children: [
                    const Icon(Icons.wifi_off_rounded,
                        color: AppTheme.warning, size: 18),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Text('Offline Mode Active',
                            style: GoogleFonts.manrope(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.warning))),
                    TextButton.icon(
                      onPressed: _isSyncing ? null : _handleSync,
                      icon: _isSyncing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AppTheme.warning))
                          : const Icon(Icons.sync_rounded,
                              size: 16, color: AppTheme.warning),
                      label: Text('Sync Now',
                          style: GoogleFonts.manrope(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.warning)),
                    ),
                  ],
                ),
              ),

            // Original Search Bar Logic
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Container(
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.outlineVariant),
                ),
                child: TextField(
                  onChanged: (v) => setState(() => _searchQuery = v),
                  decoration: const InputDecoration(
                    hintText: 'Search beats…',
                    prefixIcon: Icon(Icons.search_rounded),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ),

            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredBeats.isEmpty
                      ? const Center(child: Text('No beats found'))
                      : RefreshIndicator(
                          onRefresh: _loadBeats,
                          child: ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: _filteredBeats.length,
                            itemBuilder: (context, index) {
                              final beat = _filteredBeats[index];
                              return _BeatCard(
                                beat: beat,
                                isToday: _isTodayBeat(beat),
                                onTap: () => Navigator.pushNamed(
                                    context, AppRoutes.customerListScreen,
                                    arguments: {'beat': beat}),
                              );
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

// 🔴 THE CUSTOM ORIGINAL BEAT CARD (AZ-Sorting Ready)
class _BeatCard extends StatelessWidget {
  final BeatModel beat;
  final bool isToday;
  final VoidCallback onTap;

  const _BeatCard(
      {required this.beat, required this.isToday, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: isToday ? AppTheme.primary : AppTheme.outlineVariant,
                  width: isToday ? 2 : 1),
            ),
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(beat.beatName,
                          style: GoogleFonts.manrope(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.onSurface)),
                      const SizedBox(height: 4),
                      Text(beat.beatCode,
                          style: GoogleFonts.manrope(
                              fontSize: 12, color: AppTheme.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 4,
                        children: beat.weekdays
                            .map((day) => Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                      color: AppTheme.secondaryContainer,
                                      borderRadius: BorderRadius.circular(8)),
                                  child: Text(day.substring(0, 3),
                                      style: GoogleFonts.manrope(
                                          fontSize: 10,
                                          color: AppTheme.secondary,
                                          fontWeight: FontWeight.w600)),
                                ))
                            .toList(),
                      ),
                    ],
                  ),
                ),
                if (isToday)
                  const Icon(Icons.check_circle_rounded,
                      color: AppTheme.primary, size: 24)
                else
                  const Icon(Icons.chevron_right_rounded,
                      color: AppTheme.outlineVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
