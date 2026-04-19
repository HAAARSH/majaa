import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _isLoading = true;
  String? _error;
  Map<String, dynamic> _analytics = {};
  bool _myOnly = true; // true = My Sales, false = Team Sales
  List<String>? _allowedBrands; // non-null & non-empty = brand_rep scope

  bool get _isBrandRep => SupabaseService.instance.currentUserRole == 'brand_rep';

  @override
  void initState() {
    super.initState();
    _loadAnalytics();
  }

  Future<void> _loadAnalytics() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      if (_isBrandRep && _allowedBrands == null) {
        final uid = SupabaseService.instance.client.auth.currentUser?.id;
        _allowedBrands = uid != null
            ? await SupabaseService.instance.getUserBrandAccess(uid)
            : <String>[];
      }
      final analytics = await SupabaseService.instance.getSalesAnalytics(
        myOnly: _myOnly,
        allowedBrands: _isBrandRep ? _allowedBrands : null,
      );
      if (!mounted) return;
      setState(() {
        _analytics = analytics;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          color: AppTheme.onSurface,
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Sales Dashboard',
            style: GoogleFonts.manrope(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppTheme.onSurface)),
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text('Error: $_error'))
                : RefreshIndicator(
                    onRefresh: _loadAnalytics,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // My Sales / Team Sales toggle
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: true, label: Text('My Sales'), icon: Icon(Icons.person_rounded, size: 16)),
                              ButtonSegment(value: false, label: Text('Team Sales'), icon: Icon(Icons.groups_rounded, size: 16)),
                            ],
                            selected: {_myOnly},
                            onSelectionChanged: (sel) {
                              setState(() => _myOnly = sel.first);
                              _loadAnalytics();
                            },
                            style: ButtonStyle(
                              visualDensity: VisualDensity.compact,
                              textStyle: WidgetStateProperty.all(GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            DateFormat('MMMM yyyy').format(DateTime.now()),
                            style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 12),
                          _buildSummaryGrid(),
                          const SizedBox(height: 24),
                          _buildBeatSalesChart(),
                        ],
                      ),
                    ),
                  ),
      ),
    );
  }

  Widget _buildSummaryGrid() {
    final totalSales = _analytics['totalSales'] as double? ?? 0.0;
    final totalOrders = _analytics['totalOrders'] as int? ?? 0;
    final avgOrderValue = _analytics['avgOrderValue'] as double? ?? 0.0;

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.5,
      children: [
        _buildSummaryCard(
          'Total Sales',
          '₹${totalSales.toStringAsFixed(0)}',
          Icons.currency_rupee_rounded,
          AppTheme.primary,
        ),
        _buildSummaryCard(
          'Total Orders',
          '$totalOrders',
          Icons.shopping_bag_rounded,
          AppTheme.secondary,
        ),
        _buildSummaryCard(
          'Avg Order',
          '₹${avgOrderValue.toStringAsFixed(0)}',
          Icons.analytics_rounded,
          AppTheme.statusAvailable,
        ),
        _buildSummaryCard(
          'Target',
          '₹50,000',
          Icons.track_changes_rounded,
          AppTheme.warning,
        ),
      ],
    );
  }

  Widget _buildSummaryCard(
      String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: color, size: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: GoogleFonts.manrope(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.onSurface)),
              Text(title,
                  style: GoogleFonts.manrope(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBeatSalesChart() {
    final Map<String, double> salesByBeat =
        Map<String, double>.from(_analytics['salesByBeat'] ?? {});
    if (salesByBeat.isEmpty) return const SizedBox.shrink();

    final maxSales = salesByBeat.values.fold(0.0, (m, v) => v > m ? v : m);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sales by Beat',
            style: GoogleFonts.manrope(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppTheme.onSurface)),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.outlineVariant),
          ),
          child: Column(
            children: salesByBeat.entries.map((entry) {
              final percentage = maxSales > 0 ? entry.value / maxSales : 0.0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(entry.key,
                            style: GoogleFonts.manrope(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.onSurface)),
                        Text('₹${entry.value.toStringAsFixed(0)}',
                            style: GoogleFonts.manrope(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.primary)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Stack(
                      children: [
                        Container(
                          height: 8,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: percentage,
                          child: Container(
                            height: 8,
                            decoration: BoxDecoration(
                              color: AppTheme.primary,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}
