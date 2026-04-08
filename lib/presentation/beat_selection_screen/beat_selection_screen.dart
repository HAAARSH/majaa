import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../routes/app_routes.dart';
import '../../services/auth_service.dart';
import '../../services/supabase_service.dart';
import '../../services/pdf_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hero_selfie_modal.dart';
import '../../widgets/hero_avatar_widget.dart';

class BeatSelectionScreen extends StatefulWidget {
  const BeatSelectionScreen({super.key});

  @override
  State<BeatSelectionScreen> createState() => _BeatSelectionScreenState();
}

class _BeatSelectionScreenState extends State<BeatSelectionScreen> {
  List<BeatModel> _beats = [];
  Map<String, int> _totalOutlets = {};
  Map<String, int> _ordersToday = {};
  Map<String, int> _visitedToday = {};
  Map<String, int> _collectionsToday = {};
  Map<String, double> _outstandingByBeat = {};
  bool _isLoading = true;
  bool _userIdError = false; // FIX 2: show error when userId cannot be resolved
  bool _isCheckingHeroSelfie = false;
  bool _shouldShowHeroSelfie = false;
  
  // Cache user data to avoid redundant network calls
  AppUserModel? _cachedUser;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData({bool forceRefresh = false}) async {
    setState(() { _isLoading = true; _userIdError = false; });
    try {
      // Phase 2: Hard reset - clear cache if forceRefresh is true
      if (forceRefresh) {
        await _clearCache();
        _cachedUser = null; // Clear user cache on force refresh
      }

      // FIX 2: try currentUserId first, fall back to live auth user id
      final userId = SupabaseService.instance.currentUserId
          ?? SupabaseService.instance.client.auth.currentUser?.id;

      debugPrint('[BeatSelection] userId = $userId, forceRefresh = $forceRefresh');

      if (userId == null) {
        if (mounted) setState(() { _isLoading = false; _userIdError = true; });
        return;
      }

      // Cache user data if not already cached
      if (_cachedUser == null) {
        _cachedUser = await SupabaseService.instance.getCurrentUser();
      }

      // Check if user needs hero selfie using cached data
      await _checkHeroSelfieRequirement(userId);

      // Fetch assigned beats — include cross-team only if rep has explicit assignments
      final beats = await SupabaseService.instance.getUserBeats(userId, allTeams: true);

      final allCustomers = await SupabaseService.instance.getCustomers(forceRefresh: forceRefresh);
      final todayStr = DateTime.now().toIso8601String().substring(0, 10);

      // Fetch all today's data in parallel
      final results = await Future.wait([
        SupabaseService.instance.getOrdersByDate(todayStr),
        SupabaseService.instance.getVisitedCountsTodayByBeat(),
        SupabaseService.instance.getCollectionCountsTodayByBeat(allCustomers),
      ]);

      final orders = results[0] as List<Map<String, dynamic>>;
      final visitedMap = results[1] as Map<String, int>;
      final collectionsMap = results[2] as Map<String, int>;

      if (mounted) {
        // Filter to show only today's beats in the list
        final todayBeats = beats.where((b) => _isBeatToday(b)).toList();

        final Map<String, int> todayTotalMap = {};
        final Map<String, int> todayOrderMap = {};
        final Map<String, double> outstandingMap = {};

        for (var b in todayBeats) {
          // Use each beat's own team for stats (supports cross-team beats)
          final beatTeam = b.teamId;
          final beatCustomers = allCustomers.where((c) {
            final bid = c.beatIdForTeam(beatTeam);
            return bid == b.id;
          }).toList();
          todayTotalMap[b.id] = beatCustomers.length;
          todayOrderMap[b.id] = orders
              .where((o) => o['beat_name'] == b.beatName)
              .map((o) => o['customer_id'])
              .toSet()
              .length;
          outstandingMap[b.id] = beatCustomers.fold(
            0.0,
            (sum, c) => sum + c.outstandingForTeam(beatTeam),
          );
        }

        setState(() {
          _beats = todayBeats;
          _totalOutlets = todayTotalMap;
          _ordersToday = todayOrderMap;
          _visitedToday = visitedMap;
          _collectionsToday = collectionsMap;
          _outstandingByBeat = outstandingMap;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Phase 2: Clear cache for current team - performs hard reset
  Future<void> _clearCache() async {
    try {
      final teamKey = 'cache_${AuthService.currentTeam}';
      if (Hive.isBoxOpen(teamKey)) {
        await Hive.box(teamKey).clear();
        debugPrint('[BeatSelection] Cleared cache for team: ${AuthService.currentTeam}');
      }
    } catch (e) {
      debugPrint('[BeatSelection] Failed to clear cache: $e');
    }
  }

  /// Check if user needs to take hero selfie
  Future<void> _checkHeroSelfieRequirement(String userId) async {
    try {
      setState(() => _isCheckingHeroSelfie = true);

      // Always fetch fresh from DB to check hero_image_url (cache may be stale)
      final user = await SupabaseService.instance.getCurrentUser();
      _cachedUser = user;

      if (user == null) {
        setState(() => _shouldShowHeroSelfie = false);
        return;
      }

      debugPrint('[BeatSelection] Hero check: role=${user.role}, heroUrl=${user.heroImageUrl}');

      // Check if user has no hero image — mandatory for all roles
      final needsHeroSelfie = user.heroImageUrl == null || user.heroImageUrl!.isEmpty;

      setState(() => _shouldShowHeroSelfie = needsHeroSelfie);
      
      if (needsHeroSelfie && mounted) {
        // Show hero selfie modal after a short delay to allow UI to render
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showHeroSelfieModal(userId, user.fullName);
          }
        });
      }
    } catch (e) {
      debugPrint('[BeatSelection] Error checking hero selfie requirement: $e');
      setState(() => _shouldShowHeroSelfie = false);
    } finally {
      setState(() => _isCheckingHeroSelfie = false);
    }
  }

  /// Show hero selfie modal
  void _showHeroSelfieModal(String userId, String fullName) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => HeroSelfieModal(
        userId: userId,
        fullName: fullName,
        onSuccess: () {
          Navigator.pop(ctx); // Close modal
          // Refresh cached user data to get updated hero image URL
          _loadData();
        },
      ),
    );
  }

  void _showLogoutConfirmation() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Logout', style: GoogleFonts.manrope(fontWeight: FontWeight.bold)),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await SupabaseService.instance.signOut();
              if (mounted) Navigator.pushReplacementNamed(context, AppRoutes.initial);
            },
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
  }

  Future<void> _generateReportWithDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: AppTheme.primary,
              onPrimary: Colors.white,
              onSurface: AppTheme.onSurface,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      try {
        await PdfService.generateAndShareOrderReport(picked);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: AppTheme.error),
          );
        }
      }
    }
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour >= 5 && hour < 12) return 'Good Morning';
    if (hour >= 12 && hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  String _todayLabel() {
    return DateFormat('EEEE, d MMMM yyyy').format(DateTime.now());
  }

  Color _ringColor(double pct) {
    if (pct >= 0.70) return Colors.green.shade600;
    if (pct >= 0.30) return Colors.orange.shade600;
    return Colors.red.shade600;
  }

  // FIX 1: Use full lowercase names to match DB storage format.
  // Index 0 = Monday (weekday 1) … Index 6 = Sunday (weekday 7)
  static const _weekdayNames = [
    'monday', 'tuesday', 'wednesday',
    'thursday', 'friday', 'saturday', 'sunday',
  ];

  bool _isBeatToday(BeatModel beat) {
    if (beat.weekdays.isEmpty) return false;
    final todayName = _weekdayNames[DateTime.now().weekday - 1];
    // FIX 1 (BUG 2): case-insensitive full-name comparison
    return beat.weekdays.any((day) => day.toLowerCase().trim() == todayName);
  }

  // FEATURE 2: Out-of-Beat bottom sheet
  void _showOutOfBeatSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        builder: (_, scrollCtrl) => FutureBuilder<List<BeatModel>>(
          future: SupabaseService.instance.getUserBeats(
            SupabaseService.instance.currentUserId
                ?? SupabaseService.instance.client.auth.currentUser?.id
                ?? '',
          ),
          builder: (_, snap) {
            if (!snap.hasData) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            final allBeats = snap.data!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 12),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                // Title
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Icon(Icons.add_location_alt_rounded,
                          color: Colors.orange.shade700, size: 22),
                      const SizedBox(width: 8),
                      Text(
                        'Out of Beat Order',
                        style: GoogleFonts.manrope(
                            fontSize: 17, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                // Warning box
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Text(
                      'This will let you take an order from a customer outside your assigned beats. You will return to your beat list after.',
                      style: GoogleFonts.manrope(
                          fontSize: 12, color: Colors.orange.shade900),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                // Beat list
                Expanded(
                  child: ListView.builder(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: allBeats.length,
                    itemBuilder: (_, i) {
                      final beat = allBeats[i];
                      final isToday = _isBeatToday(beat);
                      return ListTile(
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.route_outlined,
                              color: AppTheme.primary, size: 18),
                        ),
                        title: Text(
                          beat.beatName,
                          style: GoogleFonts.manrope(
                              fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        subtitle: beat.area.isNotEmpty
                            ? Text(
                          beat.area,
                          style: GoogleFonts.manrope(
                              fontSize: 12,
                              color: AppTheme.onSurfaceVariant),
                        )
                            : null,
                        trailing: isToday
                            ? Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.green.shade600,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'TODAY',
                            style: GoogleFonts.manrope(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        )
                            : const Icon(Icons.arrow_forward_ios_rounded,
                            size: 14, color: Colors.grey),
                        onTap: () {
                          Navigator.pop(ctx);
                          Navigator.pushNamed(
                            context,
                            AppRoutes.customerListScreen,
                            arguments: {'beat': beat, 'isOutOfBeat': true},
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Show loading indicator while checking hero selfie requirement
    if (_isCheckingHeroSelfie) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.camera_alt_rounded,
                  size: 64,
                  color: const Color(0xFFFFD700),
                ),
                const SizedBox(height: 16),
                Text(
                  'Setting up your profile...',
                  style: GoogleFonts.manrope(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Please wait while we check your account',
                  style: GoogleFonts.manrope(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: AppTheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                const CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFFD700)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final totalOutlets = _totalOutlets.values.fold(0, (a, b) => a + b);
    final totalOrders = _ordersToday.values.fold(0, (a, b) => a + b);
    final coverage = totalOutlets > 0
        ? (totalOrders / totalOutlets * 100).round()
        : 0;

    // Out of Beat FAB is always visible — reps may work early/late shifts.

    Widget body;
    if (_isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_userIdError) {
      body = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.person_off_outlined,
                size: 48, color: AppTheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              'Could not identify your account.\nPlease log out and log back in.',
              textAlign: TextAlign.center,
              style: GoogleFonts.manrope(
                  fontSize: 14, color: AppTheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () => _loadData(forceRefresh: true),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildGreetingHeader(),
          const SizedBox(height: 16),
          _buildSummaryStrip(totalOutlets, totalOrders, coverage),
          const SizedBox(height: 20),
          if (_beats.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.event_busy_rounded,
                      size: 64, color: AppTheme.onSurfaceVariant.withAlpha(100)),
                  const SizedBox(height: 16),
                  Text(
                    'No beats scheduled for today',
                    style: GoogleFonts.manrope(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Use 'Out of Beat Order' below to visit any customer",
                    textAlign: TextAlign.center,
                    style: GoogleFonts.manrope(
                      fontSize: 13,
                      color: AppTheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          else
            _buildTodaysBeatsCard(),
        ],
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text('ROUTES',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            icon: const Icon(Icons.analytics_outlined),
            tooltip: 'Sales Dashboard',
            onPressed: () =>
                Navigator.pushNamed(context, AppRoutes.dashboardScreen),
          ),
          IconButton(
            icon: const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'Download Order Report',
            onPressed: _generateReportWithDate,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _loadData(forceRefresh: true),
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            onPressed: _showLogoutConfirmation,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showOutOfBeatSheet,
        backgroundColor: Colors.orange.shade700,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_location_alt_rounded),
        label: Text('Out of Beat Order',
            style: GoogleFonts.manrope(
                fontSize: 13, fontWeight: FontWeight.w600)),
      ),
      body: body,
    );
  }

  Widget _buildGreetingHeader() {
    final user = _cachedUser;
    final userInitials = user?.fullName.isNotEmpty == true
        ? user!.fullName.split(' ').map((name) => name.isNotEmpty ? name[0].toUpperCase() : '').take(2).join()
        : 'U';
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          // Hero Avatar or Initials
          HeroAvatarWidget(
            imageUrl: user?.heroImageUrl,
            radius: 20,
            initials: userInitials,
          ),
          const SizedBox(width: 12),
          // Greeting and Name
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_getGreeting()}, ${AuthService.currentUserName}!',
                  style: GoogleFonts.manrope(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _todayLabel(),
                  style: GoogleFonts.manrope(
                    fontSize: 13,
                    color: AppTheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryStrip(int totalOutlets, int totalOrders, int coverage) {
    return Row(
      children: [
        Expanded(child: _buildStatCard('Total Outlets', '$totalOutlets', Icons.store_outlined)),
        const SizedBox(width: 10),
        Expanded(child: _buildStatCard('Orders Today', '$totalOrders', Icons.receipt_long_outlined)),
        const SizedBox(width: 10),
        Expanded(child: _buildStatCard('Coverage', '$coverage%', Icons.pie_chart_outline_rounded)),
      ],
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.outlineVariant.withAlpha(80)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withAlpha(5),
              blurRadius: 6,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        children: [
          Icon(icon, size: 18, color: AppTheme.primary),
          const SizedBox(height: 6),
          Text(value,
              style: GoogleFonts.manrope(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.onSurface)),
          const SizedBox(height: 2),
          Text(label,
              style: GoogleFonts.manrope(
                  fontSize: 10, color: AppTheme.onSurfaceVariant),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildTodaysBeatsCard() {
    final totalOutlets = _beats.fold(0, (sum, b) => sum + (_totalOutlets[b.id] ?? 0));
    final totalOrders = _beats.fold(0, (sum, b) => sum + (_ordersToday[b.id] ?? 0));
    final totalVisited = _beats.fold(0, (sum, b) => sum + (_visitedToday[b.id] ?? 0));
    final beatNames = _beats.map((b) => b.beatName).join(' + ');

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppTheme.primary, AppTheme.primaryLight],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.pushNamed(
          context,
          AppRoutes.customerListScreen,
          arguments: {'beats': _beats, 'isMergedView': true},
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.merge_rounded, color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Today's Beats",
                          style: GoogleFonts.manrope(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          beatNames,
                          style: GoogleFonts.manrope(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Colors.white.withValues(alpha: 0.8),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_rounded, color: Colors.white),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _todaysStat(Icons.storefront_rounded, '$totalOutlets', 'Outlets'),
                  _todaysStat(Icons.receipt_long_rounded, '$totalOrders', 'Orders'),
                  _todaysStat(Icons.location_on_rounded, '$totalVisited', 'Visited'),
                  _todaysStat(Icons.route_rounded, '${_beats.length}', 'Beats'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _todaysStat(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: Colors.white.withValues(alpha: 0.8), size: 18),
        const SizedBox(height: 4),
        Text(value, style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
        Text(label, style: GoogleFonts.manrope(fontSize: 10, color: Colors.white.withValues(alpha: 0.7))),
      ],
    );
  }

  Widget _buildBeatCard(
    BeatModel beat,
    int orders,
    int total, {
    int visitedToday = 0,
    int collectionsToday = 0,
    double outstandingTotal = 0.0,
  }) {
    final double progress = total > 0 ? (orders / total) : 0.0;
    final int pct = (progress * 100).round();
    final Color ringColor = _ringColor(progress);
    final bool isToday = _isBeatToday(beat);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.outlineVariant.withAlpha(80)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withAlpha(5),
              blurRadius: 8,
              offset: const Offset(0, 4))
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          // Switch team context for cross-team beats
          final originalTeam = AuthService.currentTeam;
          if (beat.teamId != originalTeam) {
            AuthService.currentTeam = beat.teamId;
          }
          await Navigator.pushNamed(
            context,
            AppRoutes.customerListScreen,
            arguments: beat,
          );
          // Restore original team on return
          if (AuthService.currentTeam != originalTeam) {
            AuthService.currentTeam = originalTeam;
          }
          // Refresh data on return
          if (mounted) _loadData();
        },
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Stack(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: AppTheme.primaryContainer,
                        shape: BoxShape.circle),
                    child: Icon(Icons.route_outlined,
                        color: AppTheme.primary, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(beat.beatName,
                                  style: GoogleFonts.manrope(
                                      fontSize: 17, fontWeight: FontWeight.w700),
                                  overflow: TextOverflow.ellipsis),
                            ),
                            if (beat.teamId != AuthService.currentTeam) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: beat.teamId == 'JA'
                                      ? Colors.blue.withValues(alpha: 0.12)
                                      : Colors.orange.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  beat.teamId,
                                  style: GoogleFonts.manrope(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: beat.teamId == 'JA' ? Colors.blue : Colors.orange,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$orders / $total Orders today',
                          style: GoogleFonts.manrope(
                              fontSize: 13,
                              color: AppTheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 8),
                        // Metrics row
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            _MetricChip(
                              icon: Icons.people_outline,
                              label: '$visitedToday visited',
                              color: Colors.teal,
                            ),
                            _MetricChip(
                              icon: Icons.payments_outlined,
                              label: '$collectionsToday collected',
                              color: Colors.green,
                            ),
                            if (outstandingTotal > 0)
                              _MetricChip(
                                icon: Icons.account_balance_wallet_outlined,
                                label: '₹${outstandingTotal >= 1000 ? '${(outstandingTotal / 1000).toStringAsFixed(1)}k' : outstandingTotal.toStringAsFixed(0)} due',
                                color: outstandingTotal > 5000 ? Colors.red : Colors.orange,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Circular coverage ring
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: CustomPaint(
                      painter:
                      _CoveragePainter(progress: progress, color: ringColor),
                      child: Center(
                        child: Text(
                          '$pct%',
                          style: GoogleFonts.manrope(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: ringColor),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              // TODAY badge
              if (isToday)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.green.shade600,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'TODAY',
                      style: GoogleFonts.manrope(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// Compact metric chip for beat cards
class _MetricChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _MetricChip({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: GoogleFonts.manrope(
                  fontSize: 11, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// Coverage ring painter
class _CoveragePainter extends CustomPainter {
  final double progress;
  final Color color;

  _CoveragePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2) - 5;
    const strokeWidth = 5.0;

    final bgPaint = Paint()
      ..color = color.withAlpha(40)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, bgPaint);

    final fgPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      fgPaint,
    );
  }

  @override
  bool shouldRepaint(_CoveragePainter old) =>
      old.progress != progress || old.color != color;
}
