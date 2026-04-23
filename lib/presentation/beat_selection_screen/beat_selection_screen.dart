import 'dart:math' as math;
import 'dart:typed_data' show Uint8List;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:http/http.dart' as http;

import '../../core/search_utils.dart';
import '../../core/time_utils.dart';
import '../../main.dart' show routeObserver;
import '../../routes/app_routes.dart';
import '../../services/auth_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;
import '../../services/supabase_service.dart';
import '../../services/cart_service.dart';
import '../../services/pdf_service.dart';
import '../../services/offline_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hero_selfie_modal.dart';
import '../../widgets/hero_avatar_widget.dart';

class BeatSelectionScreen extends StatefulWidget {
  const BeatSelectionScreen({super.key});

  @override
  State<BeatSelectionScreen> createState() => _BeatSelectionScreenState();
}

class _BeatSelectionScreenState extends State<BeatSelectionScreen>
    with TickerProviderStateMixin, RouteAware {
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
  // True when the last load attempt failed (likely offline). Surfaced as a
  // banner so the rep sees "Offline — showing cached data" instead of an
  // empty beat list that looks like "no beats assigned."
  bool _loadFailed = false;
  
  // Cache user data to avoid redundant network calls
  AppUserModel? _cachedUser;

  // Tab data
  late TabController _tabController;
  List<Map<String, dynamic>> _todayOrders = [];
  List<CollectionModel> _todayCollections = [];
  List<CustomerModel> _nextDayOutstanding = [];
  String _nextDayLabel = '';
  // Cross-team tracking for next day outstanding
  Map<String, String> _nextDayCustomerTeam = {}; // customer ID -> team that found them
  String? _nextDayCrossTeamId; // the other team if cross-team beats detected
  List<String>? _todayTeamIds; // all team IDs for today's beats (for cross-team print)
  List<String>? _cachedAllowedBrands; // lazily fetched; only used when brand_rep

  bool get _isBrandRep => SupabaseService.instance.currentUserRole == 'brand_rep';
  bool get _isSalesRep => SupabaseService.instance.currentUserRole == 'sales_rep';

  Future<List<String>?> _brandScopeForReport() async {
    if (!_isBrandRep) return null;
    if (_cachedAllowedBrands != null) return _cachedAllowedBrands;
    final uid = SupabaseService.instance.client.auth.currentUser?.id;
    if (uid == null) return const <String>[];
    _cachedAllowedBrands = await SupabaseService.instance.getUserBrandAccess(uid);
    return _cachedAllowedBrands;
  }

  int get _tabCount => _isBrandRep ? 1 : 3; // brand_rep: Orders only; sales_rep: Orders + Collections + Next Day

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabCount, vsync: this);
    _loadData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) routeObserver.subscribe(this, route);
  }

  // Reps return to this screen after placing an order / settling a collection /
  // visiting a customer. Auto-refresh so the Today Orders / Collections /
  // Next Day Due tabs reflect the work they just did.
  @override
  void didPopNext() {
    _loadData();
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData({bool forceRefresh = false}) async {
    setState(() { _isLoading = true; _userIdError = false; _loadFailed = false; });
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
      // IST + Sunday-shift: on Sunday the "today" we work with is Monday,
      // so date-scoped fetches pull the upcoming working day's data instead
      // of an empty Sunday slice.
      final todayStr = _effectiveToday.toIso8601String().substring(0, 10);

      // Detect cross-team beats for today (e.g., Sourab covering Kaulagarh for both JA & MA)
      final todayBeatsList = beats.where((b) => _isBeatToday(b)).toList();
      final todayTeams = todayBeatsList.map((b) => b.teamId).toSet().toList();
      _todayTeamIds = todayTeams.length > 1 ? todayTeams : null;

      // Fetch all today's data in parallel — use multi-team if shared beats detected
      final results = await Future.wait([
        SupabaseService.instance.getOrdersByDate(todayStr, teamIds: _todayTeamIds),
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
          // "Customers on this beat" for the rep's visit count uses OR
          // semantics — a customer with an ordering-beat override should
          // appear on BOTH beats' count so the rep knows to stop by on
          // whichever route they're running that day.
          final orderContextCustomers = allCustomers.where((c) {
            final primary = c.beatIdForTeam(beatTeam);
            final orderOverride = c.orderBeatIdOverrideForTeam(beatTeam);
            return primary == b.id ||
                (orderOverride != null && orderOverride == b.id);
          }).toList();
          // Outstanding is a collection metric — use PRIMARY beat only
          // (ACMAST-synced billing address). Including order-override
          // customers would double-count their dues across beats.
          final collectionCustomers = allCustomers
              .where((c) => c.beatIdForTeam(beatTeam) == b.id)
              .toList();
          todayTotalMap[b.id] = orderContextCustomers.length;
          todayOrderMap[b.id] = orders
              .where((o) => o['beat_name'] == b.beatName)
              .map((o) => o['customer_id'])
              .toSet()
              .length;
          outstandingMap[b.id] = collectionCustomers.fold(
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
          _todayOrders = orders
            ..sort((a, b) => ((a['customer_name'] as String?) ?? '').toLowerCase()
                .compareTo(((b['customer_name'] as String?) ?? '').toLowerCase()));
        });

        // Load tab data in background (non-blocking)
        _loadTabData(allCustomers, beats);
      }
    } catch (e) {
      if (mounted) setState(() { _isLoading = false; _loadFailed = true; });
    }
  }

  Future<void> _loadTabData(List<CustomerModel> allCustomers, List<BeatModel> allBeats) async {
    try {
      // Collections / next-day base off IST + Sunday-shift so Sunday users
      // see Monday's working set. NDD jumps one day forward from _effectiveToday,
      // which keeps Sat→Mon, Sun→Mon, Mon→Tue correct.
      final today = _effectiveToday;
      final todayStr = today.toIso8601String().substring(0, 10);

      // Load today's collections for logged-in rep only
      if (!_isBrandRep) {
        final repEmail = SupabaseService.instance.client.auth.currentUser?.email ?? '';
        final allCollections = await SupabaseService.instance.getCollections(
          startDate: today,
          endDate: today,
        );
        // Filter by current user's email
        final myCollections = repEmail.isNotEmpty
            ? allCollections.where((c) => c.repEmail == repEmail).toList()
            : allCollections;
        if (mounted) setState(() => _todayCollections = myCollections);
      }

      // Load next day beat outstanding (sales_rep only).
      // NDD is computed from RAW IST now (not _effectiveToday) so Sunday
      // still shows Monday (spec: Sat→Mon, Sun→Mon, Mon→Tue). If we used
      // _effectiveToday here, Sunday would incorrectly advance to Tuesday.
      if (!_isBrandRep) {
        final istNow = TimeUtils.nowIst();
        var tomorrow = istNow.add(const Duration(days: 1));
        if (tomorrow.weekday == DateTime.sunday) {
          tomorrow = tomorrow.add(const Duration(days: 1));
        }
        final tomorrowName = _weekdayNames[tomorrow.weekday - 1];
        _nextDayLabel = DateFormat('EEEE').format(tomorrow);

        final tomorrowBeats = allBeats.where((b) =>
            b.weekdays.any((d) => d.toLowerCase().trim() == tomorrowName)).toList();

        // Auto-detect cross-team: check if tomorrow's beats span both teams
        final tomorrowTeams = tomorrowBeats.map((b) => b.teamId).toSet();
        final crossTeamId = tomorrowTeams.length > 1
            ? tomorrowTeams.firstWhere((t) => t != AuthService.currentTeam, orElse: () => '')
            : null;

        final outstandingCustomers = <CustomerModel>[];
        final customerTeamMap = <String, String>{};
        for (final b in tomorrowBeats) {
          final beatTeam = b.teamId;
          final beatCustomers = allCustomers.where((c) {
            final bid = c.beatIdForTeam(beatTeam);
            return bid == b.id;
          });
          for (final c in beatCustomers) {
            final outstanding = c.outstandingForTeam(beatTeam);
            if (outstanding > 0 && !outstandingCustomers.any((oc) => oc.id == c.id)) {
              outstandingCustomers.add(c);
              customerTeamMap[c.id] = beatTeam;
            }
          }
        }
        // Sort A-Z by customer name
        outstandingCustomers.sort((a, b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()));

        if (mounted) {
          setState(() {
            _nextDayOutstanding = outstandingCustomers;
            _nextDayCustomerTeam = customerTeamMap;
            _nextDayCrossTeamId = crossTeamId != null && crossTeamId.isNotEmpty ? crossTeamId : null;
          });
        }
      }
    } catch (e) {
      debugPrint('⚠️ _loadTabData error: $e');
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

  /// Check if user needs to take hero selfie.
  /// Cache-first: if we already have a user record with a hero image, trust it
  /// and skip the network round-trip. Offline reps used to wait for a timeout
  /// on every launch — now they pass through immediately.
  Future<void> _checkHeroSelfieRequirement(String userId) async {
    try {
      setState(() => _isCheckingHeroSelfie = true);

      // Fast path: cached user already has a hero image → no check needed.
      final cached = _cachedUser;
      if (cached != null && cached.heroImageUrl != null && cached.heroImageUrl!.isNotEmpty) {
        setState(() => _shouldShowHeroSelfie = false);
        return;
      }

      // Slow path: no cached hero. Try fresh fetch; if it fails (offline), fall
      // back to whatever cached record we have without forcing the modal.
      AppUserModel? user = cached;
      try {
        user = await SupabaseService.instance.getCurrentUser();
        if (user != null) _cachedUser = user;
      } catch (_) {
        // offline / network error — keep cached user
      }

      if (user == null) {
        setState(() => _shouldShowHeroSelfie = false);
        return;
      }

      debugPrint('[BeatSelection] Hero check: role=${user.role}, heroUrl=${user.heroImageUrl}');

      final needsHeroSelfie = user.heroImageUrl == null || user.heroImageUrl!.isEmpty;
      setState(() => _shouldShowHeroSelfie = needsHeroSelfie);

      if (needsHeroSelfie && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showHeroSelfieModal(userId, user!.fullName);
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
        final brands = await _brandScopeForReport();
        await PdfService.generateAndShareOrderReport(
          picked,
          teamIds: _todayTeamIds,
          allowedBrands: brands,
        );
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

  /// Returns the weekday the UI should behave as "today" for working-day
  /// flows. Normally just IST today, but on Sunday it shifts to Monday —
  /// reps don't work Sundays, so the collection tab + today's beat list
  /// should show the upcoming Monday's data instead of an empty Sunday.
  DateTime get _effectiveToday {
    final now = TimeUtils.nowIst();
    if (now.weekday == DateTime.sunday) {
      return now.add(const Duration(days: 1));
    }
    return now;
  }

  bool _isBeatToday(BeatModel beat) {
    if (beat.weekdays.isEmpty) return false;
    final todayName = _weekdayNames[_effectiveToday.weekday - 1];
    // FIX 1 (BUG 2): case-insensitive full-name comparison
    return beat.weekdays.any((day) => day.toLowerCase().trim() == todayName);
  }

  // FEATURE 2: Out-of-Beat bottom sheet
  void _showOutOfBeatSheet() {
    // Guard: if user id couldn't be resolved we can't load beats. Fail loud
    // instead of opening a sheet that spins forever.
    final userId = SupabaseService.instance.currentUserId
        ?? SupabaseService.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Cannot identify your account. Please log out and back in.'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        minChildSize: 0.5,
        builder: (_, scrollCtrl) => _OutOfBeatSheetContent(
          userId: userId,
          scrollCtrl: scrollCtrl,
          isBeatToday: _isBeatToday,
          onBeatPicked: (beat) {
            Navigator.pop(ctx);
            Navigator.pushNamed(
              context,
              AppRoutes.customerListScreen,
              arguments: {'beat': beat, 'isOutOfBeat': true},
            );
          },
          onCustomerPicked: (customer, beat) {
            Navigator.pop(ctx);
            Navigator.pushNamed(
              context,
              AppRoutes.customerDetails,
              arguments: {
                'customer': customer,
                'beat': beat,
                'isOutOfBeat': true,
              },
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
      body = NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                children: [
                  _buildGreetingHeader(),
                  const SizedBox(height: 16),
                  _buildSummaryStrip(totalOutlets, totalOrders, coverage),
                  const SizedBox(height: 20),
                  if (_beats.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 20, bottom: 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.event_busy_rounded,
                              size: 48, color: AppTheme.onSurfaceVariant.withAlpha(100)),
                          const SizedBox(height: 12),
                          Text("No beats scheduled for today",
                              style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.onSurface)),
                          const SizedBox(height: 4),
                          Text(
                              _isBrandRep
                                  ? 'Ask admin to assign customers for your brand.'
                                  : "Use 'Out of Beat Order' below",
                              style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
                        ],
                      ),
                    )
                  else
                    _buildTodaysBeatsCard(),
                ],
              ),
            ),
          ),
          // Pinned tab bar — sticks below AppBar when scrolled
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabBarDelegate(
              TabBar(
                controller: _tabController,
                labelColor: AppTheme.primary,
                unselectedLabelColor: AppTheme.onSurfaceVariant,
                indicatorColor: AppTheme.primary,
                labelStyle: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700),
                unselectedLabelStyle: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w500),
                tabs: [
                  const Tab(text: 'Today Orders'),
                  if (!_isBrandRep) const Tab(text: 'Collections'),
                  if (!_isBrandRep) const Tab(text: 'Next Day Due'),
                ],
              ),
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildTodayOrdersTab(),
            if (!_isBrandRep) _buildTodayCollectionsTab(),
            if (!_isBrandRep) _buildNextDayOutstandingTab(),
          ],
        ),
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
      // OOB FAB is available to all field roles. Brand_rep uses it to log
      // orders on days with no scheduled beats (e.g. Sunday) or for walk-ins
      // outside their route. Product-level brand-access filter still limits
      // what SKUs they can add, so the brand scope is preserved.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showOutOfBeatSheet,
        backgroundColor: Colors.orange.shade700,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_location_alt_rounded),
        label: Text('Out of Beat Order',
            style: GoogleFonts.manrope(
                fontSize: 13, fontWeight: FontWeight.w600)),
      ),
      body: Column(
        children: [
          // Offline banner: shown when the last data load failed — usually
          // network. Prevents the rep from mistaking an empty beat list for
          // "no beats assigned."
          if (_loadFailed)
            Material(
              color: Colors.orange.shade700,
              child: InkWell(
                onTap: () => _loadData(forceRefresh: true),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.cloud_off_rounded, size: 16, color: Colors.white),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Offline — showing cached data. Tap to retry.',
                          style: GoogleFonts.manrope(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.white),
                        ),
                      ),
                      const Icon(Icons.refresh_rounded, size: 16, color: Colors.white),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(child: body),
        ],
      ),
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

  // ─── TAB: Today Orders ─────────────────────────────────────────
  Widget _buildTodayOrdersTab() {
    if (_todayOrders.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _loadData(forceRefresh: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.5,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.receipt_long_outlined,
                        size: 48,
                        color: AppTheme.onSurfaceVariant.withAlpha(80)),
                    const SizedBox(height: 12),
                    Text('No orders today',
                        style: GoogleFonts.manrope(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.onSurfaceVariant)),
                    const SizedBox(height: 4),
                    Text('Pull down to refresh',
                        style: GoogleFonts.manrope(
                            fontSize: 11, color: AppTheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    final totalAmt = _todayOrders.fold(0.0, (sum, o) => sum + ((o['grand_total'] as num?)?.toDouble() ?? 0));
    return Column(
      children: [
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            Text('${_todayOrders.length} orders', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.onSurfaceVariant)),
            if (OfflineService.instance.pendingCount > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: AppTheme.warning.withAlpha(30), borderRadius: BorderRadius.circular(8)),
                child: Text('${OfflineService.instance.pendingCount} pending sync', style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w600, color: AppTheme.warning)),
              ),
            ],
            const Spacer(),
            Text('\u20B9${totalAmt.toStringAsFixed(0)}', style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800, color: AppTheme.primary)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _loadData(forceRefresh: true),
            child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
            itemCount: _todayOrders.length + 1, // +1 for export button
            itemBuilder: (_, i) {
              // Last item = export button
              if (i == _todayOrders.length) {
                return Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: FilledButton.icon(
                      onPressed: _exportTodayOrdersPdf,
                      icon: const Icon(Icons.picture_as_pdf_rounded, size: 18),
                      label: Text('Export & Share on WhatsApp', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700)),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                );
              }
              final o = _todayOrders[i];
              final name = o['customer_name'] as String? ?? '';
              final total = (o['grand_total'] as num?)?.toDouble() ?? 0;
              final items = (o['order_items'] as List?)?.length ?? 0;
              final status = o['status'] as String? ?? '';
              final beat = o['beat_name'] as String? ?? '';
              final orderId = o['id'] as String? ?? '';
              return GestureDetector(
                onTap: () => _showOrderActions(o),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.outlineVariant),
                  ),
                  child: Row(children: [
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text('$items items \u2022 $beat', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                      ],
                    )),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text('\u20B9${total.toStringAsFixed(0)}', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800, color: AppTheme.primary)),
                      const SizedBox(height: 2),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: status == 'Delivered' ? Colors.green.shade50 : Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(status, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w700,
                            color: status == 'Delivered' ? Colors.green.shade700 : Colors.orange.shade700)),
                      ),
                    ]),
                    const SizedBox(width: 4),
                    Icon(Icons.more_vert_rounded, size: 16, color: AppTheme.onSurfaceVariant),
                  ]),
                ),
              );
            },
          ),
          ),
        ),
      ],
    );
  }

  void _showOrderActions(Map<String, dynamic> order) {
    final orderId = order['id'] as String? ?? '';
    final customerName = order['customer_name'] as String? ?? '';
    final total = (order['grand_total'] as num?)?.toDouble() ?? 0;
    final customerId = order['customer_id'] as String?;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$customerName — \u20B9${total.toStringAsFixed(0)}',
                style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: AppTheme.primary.withAlpha(20), borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.edit_rounded, color: AppTheme.primary, size: 20),
              ),
              title: Text('Edit Order', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
              subtitle: Text('Load items into cart and modify', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
              onTap: () async {
                Navigator.pop(ctx);
                await _editOrder(order);
              },
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.delete_outline_rounded, color: Colors.red, size: 20),
              ),
              title: Text('Delete Order', style: GoogleFonts.manrope(fontWeight: FontWeight.w600, color: Colors.red)),
              subtitle: Text('Permanently remove this order', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteOrder(orderId, customerName, total);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editOrder(Map<String, dynamic> order) async {
    try {
      final customerId = order['customer_id'] as String?;
      if (customerId == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Customer not found for this order'), backgroundColor: Colors.red));
        return;
      }

      final customer = await SupabaseService.instance.getCustomerById(customerId);
      if (customer == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Customer no longer exists'), backgroundColor: Colors.red));
        return;
      }
      if (!mounted) return;

      // Build OrderModel and load to cart (stores editingOrderId — old order stays until submit).
      // Resolve the original beat by name so edited orders preserve beat_name on resubmit.
      // Look across ALL the user's beats, not just today's — a rep may edit a
      // beat order from a prior day.
      final orderModel = OrderModel.fromJson(order);
      BeatModel? beat;
      if (orderModel.beat.isNotEmpty) {
        final uid = SupabaseService.instance.currentUserId
            ?? SupabaseService.instance.client.auth.currentUser?.id;
        if (uid != null) {
          final allUserBeats = await SupabaseService.instance.getUserBeats(uid, allTeams: true);
          beat = allUserBeats.where((b) => b.beatName == orderModel.beat).firstOrNull;
        }
      }
      await CartService.instance.loadOrderToCart(orderModel, customer, beat);
      if (!mounted) return;

      // Warn if some products were missing
      final skipped = CartService.instance.editingSkippedItems;
      if (skipped.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${skipped.length} item(s) no longer available: ${skipped.join(", ")}'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 4),
        ));
      }

      Navigator.pushNamed(context, AppRoutes.productsScreen);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
    }
  }

  void _confirmDeleteOrder(String orderId, String customerName, double total) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete Order', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Text('Delete order for "$customerName" (\u20B9${total.toStringAsFixed(0)})?\n\nThis cannot be undone.',
            style: GoogleFonts.manrope(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.manrope(color: Colors.grey))),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                final role = SupabaseService.instance.currentUserRole;
                final isSuperAdmin = role == 'super_admin' || role == 'admin';
                await SupabaseService.instance.deleteOrder(orderId, isSuperAdmin: isSuperAdmin);
                if (!mounted) return;
                setState(() => _todayOrders.removeWhere((o) => o['id'] == orderId));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Order deleted'), backgroundColor: Colors.green));
              } catch (e) {
                final msg = e.toString().toLowerCase().contains('3 days')
                    ? 'Order older than 3 days — contact admin.'
                    : 'Error: $e';
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
              }
            },
            child: Text('Delete', style: GoogleFonts.manrope(color: Colors.red, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  void _showCollectionActions(CollectionModel collection) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${collection.customerName} — \u20B9${collection.amountCollected.toStringAsFixed(0)}',
                style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: AppTheme.primary.withAlpha(20), borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.edit_rounded, color: AppTheme.primary, size: 20),
              ),
              title: Text('Edit Collection', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
              subtitle: Text('Change amount, method, or bill no', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
              onTap: () {
                Navigator.pop(ctx);
                _showEditCollectionDialog(collection);
              },
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.delete_outline_rounded, color: Colors.red, size: 20),
              ),
              title: Text('Delete Collection', style: GoogleFonts.manrope(fontWeight: FontWeight.w600, color: Colors.red)),
              subtitle: Text('Remove and restore outstanding', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteCollection(collection);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEditCollectionDialog(CollectionModel collection) {
    final amountCtrl = TextEditingController(text: collection.amountCollected.toStringAsFixed(0));
    final billNoCtrl = TextEditingController(text: collection.billNo ?? '');
    String method = collection.paymentMode;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Edit Collection', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'Amount (\u20B9)', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), prefixIcon: const Icon(Icons.currency_rupee)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: billNoCtrl,
                decoration: InputDecoration(labelText: 'Bill Number', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), prefixIcon: const Icon(Icons.receipt_outlined)),
              ),
              const SizedBox(height: 12),
              Row(children: [
                _methodChip('UPI', method, (v) => setDialogState(() => method = v)),
                const SizedBox(width: 8),
                _methodChip('CASH', method, (v) => setDialogState(() => method = v)),
                const SizedBox(width: 8),
                _methodChip('Cheque', method, (v) => setDialogState(() => method = v)),
              ]),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.manrope(color: Colors.grey))),
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final newAmt = double.tryParse(amountCtrl.text.trim());
                final success = await SupabaseService.instance.updateCollection(
                  collection.id,
                  newAmount: newAmt,
                  newMethod: method,
                  newBillNo: billNoCtrl.text.trim(),
                );
                if (success && mounted) {
                  _loadTabData(await SupabaseService.instance.getCustomers(),
                      await SupabaseService.instance.getUserBeats(
                          SupabaseService.instance.currentUserId ?? '', allTeams: true));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Collection updated'), backgroundColor: Colors.green));
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ).then((_) { amountCtrl.dispose(); billNoCtrl.dispose(); });
  }

  Widget _methodChip(String label, String selected, ValueChanged<String> onTap) {
    final isSelected = selected == label || (label == 'CASH' && (selected == 'Cash' || selected == 'CASH'));
    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(label),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.primary : AppTheme.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(child: Text(label, style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600,
              color: isSelected ? Colors.white : AppTheme.onSurfaceVariant))),
        ),
      ),
    );
  }

  void _confirmDeleteCollection(CollectionModel collection) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete Collection', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Text('Delete \u20B9${collection.amountCollected.toStringAsFixed(0)} collection from "${collection.customerName}"?\n\nOutstanding will be restored.',
            style: GoogleFonts.manrope(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.manrope(color: Colors.grey))),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final success = await SupabaseService.instance.deleteCollection(collection.id);
              if (success && mounted) {
                setState(() => _todayCollections.removeWhere((c) => c.id == collection.id));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Collection deleted, outstanding restored'), backgroundColor: Colors.green));
              }
            },
            child: Text('Delete', style: GoogleFonts.manrope(color: Colors.red, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Future<void> _exportTodayOrdersPdf() async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Generating report...'), duration: Duration(seconds: 1)),
      );
      final brands = await _brandScopeForReport();
      final filePath = await PdfService.generateOrderReportFile(
        DateTime.now(),
        teamIds: _todayTeamIds,
        allowedBrands: brands,
      );
      // Share directly to WhatsApp
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(filePath)],
          text: 'MAJAA Sales — Today\'s Order Report (${DateFormat('dd MMM yyyy').format(DateTime.now())})',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ─── TAB: Today Collections ───────────────────────────────────
  Widget _buildTodayCollectionsTab() {
    if (_todayCollections.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _loadData(forceRefresh: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.42,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.payments_outlined,
                        size: 48,
                        color: AppTheme.onSurfaceVariant.withAlpha(80)),
                    const SizedBox(height: 12),
                    Text('No collections today',
                        style: GoogleFonts.manrope(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.onSurfaceVariant)),
                    const SizedBox(height: 4),
                    Text('Pull down to refresh',
                        style: GoogleFonts.manrope(
                            fontSize: 11, color: AppTheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
            if (_todayPrimaryBeatNames.isNotEmpty || _todayCrossBeatNames.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  "Today's outstanding",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.onSurfaceVariant),
                ),
              ),
              _buildCollectionActionsRow(),
            ],
          ],
        ),
      );
    }
    final totalAmt = _todayCollections.fold(0.0, (sum, c) => sum + c.amountCollected);
    final cashAmt = _todayCollections.where((c) => c.paymentMode == 'CASH' || c.paymentMode == 'Cash').fold(0.0, (sum, c) => sum + c.amountCollected);
    final upiAmt = _todayCollections.where((c) => c.paymentMode == 'UPI').fold(0.0, (sum, c) => sum + c.amountCollected);
    final chequeAmt = _todayCollections.where((c) => c.paymentMode == 'Cheque' || c.paymentMode == 'CHEQUE').fold(0.0, (sum, c) => sum + c.amountCollected);
    final cashCount = _todayCollections.where((c) => c.paymentMode == 'CASH' || c.paymentMode == 'Cash').length;
    final upiCount = _todayCollections.where((c) => c.paymentMode == 'UPI').length;
    final chequeCount = _todayCollections.where((c) => c.paymentMode == 'Cheque' || c.paymentMode == 'CHEQUE').length;

    return Column(
      children: [
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(children: [
            Row(children: [
              Text('${_todayCollections.length} collections', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.onSurfaceVariant)),
              const Spacer(),
              Text('\u20B9${totalAmt.toStringAsFixed(0)}', style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.green.shade700)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              if (cashCount > 0) _collectionMethodChip(Icons.money, 'Cash', cashAmt, cashCount, Colors.orange),
              if (cashCount > 0) const SizedBox(width: 8),
              if (upiCount > 0) _collectionMethodChip(Icons.qr_code_rounded, 'UPI', upiAmt, upiCount, Colors.blue),
              if (upiCount > 0) const SizedBox(width: 8),
              if (chequeCount > 0) _collectionMethodChip(Icons.description_outlined, 'Cheque', chequeAmt, chequeCount, Colors.purple),
            ]),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: Builder(builder: (_) {
            // Sort alphabetically by customer name, then by bill number
            final sorted = List<CollectionModel>.from(_todayCollections)
              ..sort((a, b) {
                final nameCompare = a.customerName.toLowerCase().compareTo(b.customerName.toLowerCase());
                if (nameCompare != 0) return nameCompare;
                return (a.billNo ?? '').compareTo(b.billNo ?? '');
              });

            // Group by customer
            final Map<String, List<CollectionModel>> byCustomer = {};
            for (final c in sorted) {
              byCustomer.putIfAbsent(c.customerName, () => []);
              byCustomer[c.customerName]!.add(c);
            }
            final customers = byCustomer.entries.toList();

            return RefreshIndicator(
              onRefresh: () => _loadData(forceRefresh: true),
              child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
              itemCount: customers.length + 1, // +1 for overlay buttons
              itemBuilder: (_, i) {
                // Last item = unified share/print row (dispatches on state).
                if (i == customers.length) {
                  return _buildCollectionActionsRow();
                }
                final entry = customers[i];
                final custName = entry.key;
                final bills = entry.value;
                final custTotal = bills.fold(0.0, (sum, c) => sum + c.amountCollected);

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Customer header
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                        child: Row(children: [
                          Expanded(child: Text(custName, style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                          Text('\u20B9${custTotal.toStringAsFixed(0)}', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.green.shade700)),
                        ]),
                      ),
                      // Bill-wise rows
                      ...bills.map((c) {
                        final isCash = c.paymentMode == 'CASH' || c.paymentMode == 'Cash';
                        final isUpi = c.paymentMode == 'UPI';
                        final methodColor = isCash ? Colors.orange : isUpi ? Colors.blue : Colors.purple;
                        final methodIcon = isCash ? Icons.money : isUpi ? Icons.qr_code_rounded : Icons.description_outlined;
                        return GestureDetector(
                          onTap: () => _showCollectionActions(c),
                          child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                          child: Row(children: [
                            Icon(methodIcon, size: 14, color: methodColor),
                            const SizedBox(width: 6),
                            Text('Bill #${c.billNo ?? '-'}', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(color: methodColor.withAlpha(20), borderRadius: BorderRadius.circular(4)),
                              child: Text(c.paymentMode, style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w700, color: methodColor)),
                            ),
                            const Spacer(),
                            Text('\u20B9${c.amountCollected.toStringAsFixed(0)}', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.onSurface)),
                            const SizedBox(width: 4),
                            Icon(Icons.edit_outlined, size: 12, color: AppTheme.onSurfaceVariant),
                          ]),
                        ),
                        );
                      }),
                    ],
                  ),
                );
              },
              ),
            );
          }),
        ),
      ],
    );
  }

  /// Unified Share / Print row on the Collections tab. One pair of buttons
  /// regardless of whether any collections have been recorded yet:
  /// - Empty collections  → today's outstanding (same layout as Next-Day-Due)
  /// - Has collections     → overlay PDF with cash/UPI/cheque breakdown per bill
  Widget _buildCollectionActionsRow() {
    final hasCollections = _todayCollections.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: Row(children: [
        Expanded(
          child: SizedBox(
            height: 46,
            child: FilledButton.icon(
              onPressed: hasCollections
                  ? _shareCollectionOverlay
                  : () => _shareOutstandingReport(
                        primaryBeatNames: _todayPrimaryBeatNames,
                        crossTeamId: _todayCrossTeamId,
                        crossBeatNames: _todayCrossBeatNames,
                      ),
              icon: const Icon(Icons.share_rounded, size: 16),
              label: Text('Share', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700)),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SizedBox(
            height: 46,
            child: OutlinedButton.icon(
              onPressed: hasCollections
                  ? _printCollectionOverlay
                  : () => _printOutstandingReport(
                        primaryBeatNames: _todayPrimaryBeatNames,
                        crossTeamId: _todayCrossTeamId,
                        crossBeatNames: _todayCrossBeatNames,
                      ),
              icon: Icon(Icons.print_rounded, size: 16, color: AppTheme.primary),
              label: Text('Print', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppTheme.primary),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Future<void> _printCollectionOverlay() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Print Collections Overlay', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This prints ONLY the UPI/CHQ/CASH amounts.', style: GoogleFonts.manrope(fontSize: 13)),
            const SizedBox(height: 8),
            Text('Re-feed your printed outstanding sheet into the printer tray, then confirm.',
                style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Row(children: [
              Icon(Icons.print_rounded, size: 16, color: AppTheme.primary),
              const SizedBox(width: 8),
              Text('HP LaserJet M1136 MFP', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
            ]),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.manrope(color: Colors.grey))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Print')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Generating overlay...'), duration: Duration(seconds: 1)));
      final allCustomers = await SupabaseService.instance.getCustomers();
      final allBills = await SupabaseService.instance.getCustomerBillsForTeam();
      final pdfBytes = await PdfService.generateCollectionOverlayBytes(
        customers: allCustomers, allBills: allBills,
        collections: _todayCollections,
        teamId: AuthService.currentTeam,
        beatNames: _todayBeatNames,
      );
      if (kIsWeb) {
        final fileName = 'collection_overlay_${DateTime.now().millisecondsSinceEpoch}.pdf';
        await SupabaseService.instance.client.storage
            .from('print_queue')
            .uploadBinary(fileName, Uint8List.fromList(pdfBytes), fileOptions: const FileOptions(contentType: 'application/pdf'));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent to print queue!'), backgroundColor: Colors.green));
      } else {
        final uri = Uri.parse('http://192.168.29.149:5000/print');
        final request = http.MultipartRequest('POST', uri)
          ..files.add(http.MultipartFile.fromBytes('file', pdfBytes, filename: 'collection_overlay.pdf'));
        final response = await request.send().timeout(const Duration(seconds: 15));
        if (!mounted) return;
        if (response.statusCode == 200) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent to printer!'), backgroundColor: Colors.green));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Printer error: ${response.statusCode}'), backgroundColor: Colors.red));
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
    }
  }


  Future<void> _shareCollectionOverlay() async {
    try {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Generating overlay PDF...'), duration: Duration(seconds: 1)));
      final allCustomers = await SupabaseService.instance.getCustomers();
      final allBills = await SupabaseService.instance.getCustomerBillsForTeam();
      final filePath = await PdfService.generateCollectionOverlayFile(
        customers: allCustomers, allBills: allBills,
        collections: _todayCollections,
        teamId: AuthService.currentTeam,
        beatNames: _todayBeatNames,
      );
      await SharePlus.instance.share(ShareParams(
        files: [XFile(filePath)],
        text: 'Collection Overlay — ${DateFormat('dd MMM yyyy').format(DateTime.now())}',
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
    }
  }

  Widget _collectionMethodChip(IconData icon, String label, double amount, int count, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: color.withAlpha(15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withAlpha(40)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('\u20B9${amount.toStringAsFixed(0)}', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w800, color: color)),
                Text('$count $label', style: GoogleFonts.manrope(fontSize: 8, color: color.withAlpha(180))),
              ],
            )),
          ],
        ),
      ),
    );
  }

  // ─── TAB: Next Day Outstanding ────────────────────────────────
  Widget _buildNextDayOutstandingTab() {
    if (_nextDayOutstanding.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _loadData(forceRefresh: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.5,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 48, color: Colors.green.shade300),
                    const SizedBox(height: 12),
                    Text(
                      'No outstanding for $_nextDayLabel',
                      style: GoogleFonts.manrope(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 4),
                    Text('Pull down to refresh',
                        style: GoogleFonts.manrope(
                            fontSize: 11, color: AppTheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    final totalDue = _nextDayOutstanding.fold(0.0, (sum, c) {
      final team = _nextDayCustomerTeam[c.id] ?? AuthService.currentTeam;
      return sum + c.outstandingForTeam(team);
    });
    return Column(
      children: [
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            Text('$_nextDayLabel \u2022 ${_nextDayOutstanding.length} customers', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.onSurfaceVariant)),
            const Spacer(),
            Text('\u20B9${totalDue.toStringAsFixed(0)}', style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.red.shade700)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _loadData(forceRefresh: true),
            child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
            itemCount: _nextDayOutstanding.length + 1, // +1 for buttons
            itemBuilder: (_, i) {
              // Last item = export/print buttons
              if (i == _nextDayOutstanding.length) {
                return Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 16),
                  child: Row(children: [
                    Expanded(
                      child: SizedBox(
                        height: 46,
                        child: FilledButton.icon(
                          onPressed: () => _shareOutstandingReport(
                            primaryBeatNames: _nextDayBeatNames,
                            crossTeamId: _nextDayCrossTeamId,
                            crossBeatNames: _nextDayCrossBeatNames,
                          ),
                          icon: const Icon(Icons.share_rounded, size: 16),
                          label: Text('Share', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700)),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.green.shade700,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 46,
                        child: OutlinedButton.icon(
                          onPressed: () => _printOutstandingReport(
                            primaryBeatNames: _nextDayBeatNames,
                            crossTeamId: _nextDayCrossTeamId,
                            crossBeatNames: _nextDayCrossBeatNames,
                          ),
                          icon: Icon(Icons.print_rounded, size: 16, color: AppTheme.primary),
                          label: Text('Print', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: AppTheme.primary),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ),
                  ]),
                );
              }
              final c = _nextDayOutstanding[i];
              final custTeam = _nextDayCustomerTeam[c.id] ?? AuthService.currentTeam;
              final outstanding = c.outstandingForTeam(custTeam);
              final beat = c.beatNameForTeam(custTeam);
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.outlineVariant),
                ),
                child: Row(children: [
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name, style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Row(children: [
                        Text(beat, style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                        if (custTeam != AuthService.currentTeam) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: custTeam == 'JA'
                                  ? Colors.blue.withValues(alpha: 0.12)
                                  : Colors.orange.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(custTeam, style: GoogleFonts.manrope(
                              fontSize: 9, fontWeight: FontWeight.w800,
                              color: custTeam == 'JA' ? Colors.blue : Colors.orange,
                            )),
                          ),
                        ],
                      ]),
                    ],
                  )),
                  Text('\u20B9${outstanding.toStringAsFixed(0)}', style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.red.shade700)),
                ]),
              );
            },
          ),
          ),
        ),
      ],
    );
  }

  /// Beat names for the primary (current) team in next day outstanding
  List<String> get _nextDayBeatNames =>
      _nextDayOutstanding
          .where((c) => (_nextDayCustomerTeam[c.id] ?? AuthService.currentTeam) == AuthService.currentTeam)
          .map((c) => c.beatNameForTeam(AuthService.currentTeam))
          .toSet().toList();

  /// Beat names for the cross team in next day outstanding
  List<String> get _nextDayCrossBeatNames {
    if (_nextDayCrossTeamId == null) return [];
    return _nextDayOutstanding
        .where((c) => _nextDayCustomerTeam[c.id] == _nextDayCrossTeamId)
        .map((c) => c.beatNameForTeam(_nextDayCrossTeamId!))
        .toSet().toList();
  }

  List<String> get _todayBeatNames =>
      _beats.map((b) => b.beatName).toSet().toList();

  /// Beat names for the primary (current) team in today's beats
  List<String> get _todayPrimaryBeatNames =>
      _beats.where((b) => b.teamId == AuthService.currentTeam)
          .map((b) => b.beatName).toSet().toList();

  /// Cross-team id for today if any of today's beats belong to the other team
  String? get _todayCrossTeamId {
    final currentTeam = AuthService.currentTeam;
    final others = _beats.where((b) => b.teamId != currentTeam)
        .map((b) => b.teamId).toSet();
    return others.isEmpty ? null : others.first;
  }

  /// Beat names for the cross team in today's beats
  List<String> get _todayCrossBeatNames {
    final crossId = _todayCrossTeamId;
    if (crossId == null) return [];
    return _beats.where((b) => b.teamId == crossId)
        .map((b) => b.beatName).toSet().toList();
  }

  Future<void> _shareOutstandingReport({
    required List<String> primaryBeatNames,
    String? crossTeamId,
    required List<String> crossBeatNames,
  }) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Generating report...'), duration: Duration(seconds: 1)),
      );
      final allCustomers = await SupabaseService.instance.getCustomers();
      final allBills = await SupabaseService.instance.getCustomerBillsForTeam();
      final advances = await SupabaseService.instance.getCustomerAdvancesForTeam();
      final creditNotes = await SupabaseService.instance.getCustomerCreditNotesForTeam();

      // Fetch cross-team bills + advances + CNs if cross-team beats detected
      List<Map<String, dynamic>>? crossBills;
      List<Map<String, dynamic>>? crossAdvances;
      List<Map<String, dynamic>>? crossCreditNotes;
      if (crossTeamId != null && crossBeatNames.isNotEmpty) {
        crossBills = await SupabaseService.instance.getCustomerBillsForTeam(teamId: crossTeamId);
        crossAdvances = await SupabaseService.instance.getCustomerAdvancesForTeam(teamId: crossTeamId);
        crossCreditNotes = await SupabaseService.instance.getCustomerCreditNotesForTeam(teamId: crossTeamId);
      }

      final filePath = await PdfService.generateOutstandingReportFile(
        customers: allCustomers, allBills: allBills, teamId: AuthService.currentTeam,
        beatNames: primaryBeatNames,
        advances: advances,
        creditNotes: creditNotes,
        crossTeamId: crossTeamId,
        crossTeamBills: crossBills,
        crossTeamBeatNames: crossBeatNames,
        crossTeamAdvances: crossAdvances,
        crossTeamCreditNotes: crossCreditNotes,
      );
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(filePath)],
          text: 'MAJAA — Outstanding Report (${DateFormat('dd MMM yyyy').format(DateTime.now())})',
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _printOutstandingReport({
    required List<String> primaryBeatNames,
    String? crossTeamId,
    required List<String> crossBeatNames,
  }) async {
    final isWeb = kIsWeb;
    // Confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Print Outstanding Report', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Send to office printer?', style: GoogleFonts.manrope(fontSize: 14)),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.print_rounded, size: 16, color: AppTheme.primary),
              const SizedBox(width: 8),
              Text('HP LaserJet M1136 MFP', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
            ]),
            if (!isWeb) Row(children: [
              Icon(Icons.wifi_rounded, size: 16, color: AppTheme.primary),
              const SizedBox(width: 8),
              Text('192.168.29.149', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
            ]),
            if (isWeb) Row(children: [
              Icon(Icons.cloud_upload_rounded, size: 16, color: AppTheme.primary),
              const SizedBox(width: 8),
              Flexible(child: Text('Via cloud print queue', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant))),
            ]),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.manrope(color: Colors.grey))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Print'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isWeb ? 'Generating & uploading to print queue...' : 'Generating & sending to printer...'), duration: const Duration(seconds: 2)),
        );
      }
      final allCustomers = await SupabaseService.instance.getCustomers();
      final allBills = await SupabaseService.instance.getCustomerBillsForTeam();
      final advances = await SupabaseService.instance.getCustomerAdvancesForTeam();
      final creditNotes = await SupabaseService.instance.getCustomerCreditNotesForTeam();

      // Fetch cross-team bills + advances + CNs if cross-team beats detected
      List<Map<String, dynamic>>? crossBills;
      List<Map<String, dynamic>>? crossAdvances;
      List<Map<String, dynamic>>? crossCreditNotes;
      if (crossTeamId != null && crossBeatNames.isNotEmpty) {
        crossBills = await SupabaseService.instance.getCustomerBillsForTeam(teamId: crossTeamId);
        crossAdvances = await SupabaseService.instance.getCustomerAdvancesForTeam(teamId: crossTeamId);
        crossCreditNotes = await SupabaseService.instance.getCustomerCreditNotesForTeam(teamId: crossTeamId);
      }

      final pdfBytes = await PdfService.generateOutstandingReportBytes(
        customers: allCustomers, allBills: allBills, teamId: AuthService.currentTeam,
        beatNames: primaryBeatNames,
        advances: advances,
        creditNotes: creditNotes,
        crossTeamId: crossTeamId,
        crossTeamBills: crossBills,
        crossTeamBeatNames: crossBeatNames,
        crossTeamAdvances: crossAdvances,
        crossTeamCreditNotes: crossCreditNotes,
      );

      if (isWeb) {
        // Web/iOS: Upload to Supabase Storage print_queue bucket
        final fileName = 'outstanding_${DateTime.now().millisecondsSinceEpoch}.pdf';
        await SupabaseService.instance.client.storage
            .from('print_queue')
            .uploadBinary(fileName, Uint8List.fromList(pdfBytes), fileOptions: const FileOptions(contentType: 'application/pdf'));

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sent to print queue! Will print shortly.'), backgroundColor: Colors.green),
        );
      } else {
        // Android: Direct network print
        final uri = Uri.parse('http://192.168.29.149:5000/print');
        final request = http.MultipartRequest('POST', uri)
          ..files.add(http.MultipartFile.fromBytes('file', pdfBytes, filename: 'outstanding.pdf'));
        final response = await request.send().timeout(const Duration(seconds: 15));

        if (!mounted) return;
        if (response.statusCode == 200) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sent to printer!'), backgroundColor: Colors.green),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Printer error: ${response.statusCode}'), backgroundColor: Colors.red),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cannot connect to printer: $e'), backgroundColor: Colors.red),
        );
      }
    }
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

// ─── Tab Bar Delegate for pinned SliverPersistentHeader ─────────────────────
class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  const _TabBarDelegate(this.tabBar);

  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(bottom: BorderSide(color: AppTheme.outlineVariant)),
      ),
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) => false;
}

// ─── Out-of-Beat sheet content ──────────────────────────────────────────────
//
// Extracted into its own widget so it can manage its own search state without
// rebuilding the parent. Adds:
//   • explicit error state if getUserBeats fails
//   • close button + search field
//   • today's beats hidden (already shown on the main screen)
//   • cross-team beats included (allTeams: true) so reps who cover both teams
//     don't have to switch team first.
class _OutOfBeatSheetContent extends StatefulWidget {
  final String userId;
  final ScrollController scrollCtrl;
  final bool Function(BeatModel) isBeatToday;
  final void Function(BeatModel) onBeatPicked;
  final void Function(CustomerModel, BeatModel) onCustomerPicked;

  const _OutOfBeatSheetContent({
    required this.userId,
    required this.scrollCtrl,
    required this.isBeatToday,
    required this.onBeatPicked,
    required this.onCustomerPicked,
  });

  @override
  State<_OutOfBeatSheetContent> createState() => _OutOfBeatSheetContentState();
}

class _OutOfBeatSheetContentState extends State<_OutOfBeatSheetContent> {
  late Future<List<BeatModel>> _future;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  // Loaded lazily on first non-empty search. Customers are scoped to the
  // beats this rep is actually allowed on — for brand_rep and sales_rep
  // alike the list comes from getUserBeats, so no cross-rep leak.
  List<CustomerModel> _customers = [];
  bool _customersLoaded = false;
  bool _customersLoading = false;

  @override
  void initState() {
    super.initState();
    _future = SupabaseService.instance.getUserBeats(widget.userId, allTeams: true);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _ensureCustomersLoaded(List<BeatModel> allowedBeats) async {
    if (_customersLoaded || _customersLoading) return;
    _customersLoading = true;
    try {
      final allowedBeatIds = allowedBeats.map((b) => b.id).toSet();
      final allCustomers = await SupabaseService.instance.getCustomers();
      // A customer is "on" an allowed beat if their PRIMARY beat OR their
      // ordering-beat override for either team matches an allowed beat id.
      // Including override beats here lets the OOB search find customers
      // whose split (e.g. Dobhal & Navi: primary=Dharampur 2nd,
      // order_beat=Panditvari) puts them on a route the rep is running.
      final scoped = allCustomers.where((c) {
        final jaPrimary = c.beatIdForTeam('JA');
        final jaOverride = c.orderBeatIdOverrideForTeam('JA');
        final maPrimary = c.beatIdForTeam('MA');
        final maOverride = c.orderBeatIdOverrideForTeam('MA');
        return (jaPrimary != null && allowedBeatIds.contains(jaPrimary)) ||
            (jaOverride != null && allowedBeatIds.contains(jaOverride)) ||
            (maPrimary != null && allowedBeatIds.contains(maPrimary)) ||
            (maOverride != null && allowedBeatIds.contains(maOverride));
      }).toList();
      if (!mounted) return;
      setState(() {
        _customers = scoped;
        _customersLoaded = true;
        _customersLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _customersLoading = false;
      });
    }
  }

  /// Resolve which of the rep's allowed beats this customer should be opened
  /// under. Tap-from-OOB-search jumps straight to the customer detail with
  /// this beat as context — so pick the beat that best represents the
  /// ORDERING context (override first, primary fallback). Per-team, prefers
  /// the current team to keep the rep on their logged-in side when possible.
  BeatModel? _resolveCustomerBeat(
    CustomerModel customer,
    List<BeatModel> allowedBeats,
  ) {
    final allowedById = {for (final b in allowedBeats) b.id: b};
    final current = AuthService.currentTeam;

    // For each team, prefer the ordering override if present, else primary.
    String? bestForTeam(String team) {
      final override = customer.orderBeatIdOverrideForTeam(team);
      if (override != null && allowedById.containsKey(override)) return override;
      final primary = customer.beatIdForTeam(team);
      if (primary != null && allowedById.containsKey(primary)) return primary;
      return null;
    }

    // Current team first so rep stays in their team's flow.
    final currentBeat = bestForTeam(current);
    if (currentBeat != null) return allowedById[currentBeat];
    final otherTeam = current == 'JA' ? 'MA' : 'JA';
    final otherBeat = bestForTeam(otherTeam);
    if (otherBeat != null) return allowedById[otherBeat];
    return null;
  }

  @override
  Widget build(BuildContext context) {
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
        // Title + close
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Icon(Icons.add_location_alt_rounded,
                  color: Colors.orange.shade700, size: 22),
              const SizedBox(width: 8),
              Text('Out of Beat Order',
                  style: GoogleFonts.manrope(
                      fontSize: 17, fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(context),
                tooltip: 'Close',
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // Warning box — explains what the picker does.
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
              'Type a customer name / phone to jump straight to the order — or pick a route below to browse its customer list.',
              style: GoogleFonts.manrope(
                  fontSize: 12, color: Colors.orange.shade900),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Search — finds customers across all beats the rep is allowed on.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v.trim()),
            decoration: InputDecoration(
              hintText: 'Search customer…',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppTheme.outlineVariant),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1),
        // Beat list
        Expanded(
          child: FutureBuilder<List<BeatModel>>(
            future: _future,
            builder: (_, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: CircularProgressIndicator(),
                  ),
                );
              }
              if (snap.hasError) {
                return _errorState(
                  icon: Icons.cloud_off_rounded,
                  title: 'Could not load your beats',
                  detail: 'Check your connection and try again.',
                  onRetry: () => setState(() {
                    _future = SupabaseService.instance
                        .getUserBeats(widget.userId, allTeams: true);
                  }),
                );
              }
              final all = snap.data ?? <BeatModel>[];

              if (all.isEmpty) {
                return _errorState(
                  icon: Icons.inbox_outlined,
                  title: 'No beats assigned to you',
                  detail: 'Ask admin to assign a route so you can place orders.',
                );
              }

              // When the rep types anything, switch to customer-search mode:
              // tokenized match across name / phone / address, scoped to
              // customers on this rep's allowed beats (same pool for
              // sales_rep and brand_rep — the visible filter comes from the
              // rep's beat assignments, not their role).
              if (_query.isNotEmpty) {
                // Kick off a one-time customer fetch.
                if (!_customersLoaded && !_customersLoading) {
                  _ensureCustomersLoaded(all);
                }
                if (!_customersLoaded) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: CircularProgressIndicator(),
                    ),
                  );
                }
                final matches = _customers
                    .where((c) =>
                        tokenMatch(_query, [c.name, c.phone, c.address]))
                    .toList()
                  ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
                if (matches.isEmpty) {
                  return _errorState(
                    icon: Icons.search_off_rounded,
                    title: 'No customers matching "$_query"',
                    detail: 'Try a different name or phone number.',
                  );
                }
                return ListView.builder(
                  controller: widget.scrollCtrl,
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: matches.length,
                  itemBuilder: (_, i) {
                    final c = matches[i];
                    final beat = _resolveCustomerBeat(c, all);
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
                        child: Text(
                          c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
                          style: TextStyle(
                            color: AppTheme.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      title: Text(
                        c.name,
                        style: GoogleFonts.manrope(
                            fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        [
                          if (c.phone.isNotEmpty && c.phone != 'No Phone') c.phone,
                          if (beat != null) beat.beatName,
                        ].join(' · '),
                        style: GoogleFonts.manrope(
                            fontSize: 12,
                            color: AppTheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.arrow_forward_ios_rounded,
                          size: 14, color: Colors.grey),
                      onTap: beat == null
                          ? null
                          : () => widget.onCustomerPicked(c, beat),
                    );
                  },
                );
              }

              // No query — fall back to the original route picker, minus
              // today's beats (those are already on the main screen).
              final nonToday = all.where((b) => !widget.isBeatToday(b)).toList();
              if (nonToday.isEmpty) {
                return _errorState(
                  icon: Icons.search_off_rounded,
                  title: 'No non-today beats to show',
                  detail: 'Your other beats are already shown above. Type a customer name to search directly.',
                );
              }
              final filtered = nonToday;
              return ListView.builder(
                controller: widget.scrollCtrl,
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final beat = filtered[i];
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
                    title: Text(beat.beatName,
                        style: GoogleFonts.manrope(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: beat.area.isNotEmpty
                        ? Text(beat.area,
                            style: GoogleFonts.manrope(
                                fontSize: 12,
                                color: AppTheme.onSurfaceVariant))
                        : null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Team pill — useful when the rep covers both teams.
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: beat.teamId == 'JA'
                                ? Colors.blue.shade50
                                : Colors.purple.shade50,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            beat.teamId,
                            style: GoogleFonts.manrope(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: beat.teamId == 'JA'
                                  ? Colors.blue.shade800
                                  : Colors.purple.shade800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.arrow_forward_ios_rounded,
                            size: 14, color: Colors.grey),
                      ],
                    ),
                    onTap: () => widget.onBeatPicked(beat),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _errorState({
    required IconData icon,
    required String title,
    required String detail,
    VoidCallback? onRetry,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppTheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.onSurface)),
            const SizedBox(height: 4),
            Text(detail,
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(
                    fontSize: 12, color: AppTheme.onSurfaceVariant)),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
