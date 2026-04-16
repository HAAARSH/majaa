import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';

import '../../../services/supabase_service.dart';
import '../../../services/auth_service.dart';

class AdminDashboardTab extends StatefulWidget {
  const AdminDashboardTab({super.key});

  @override
  State<AdminDashboardTab> createState() => _AdminDashboardTabState();
}

class _AdminDashboardTabState extends State<AdminDashboardTab>
    with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  bool _isUploading = false;
  String? _error;
  Map<String, dynamic>? _analyticsData;
  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;

  // Chart toggle: 'beat' or 'pie'
  String _chartView = 'beat';

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _loadAnalytics();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAnalytics() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final data = await SupabaseService.instance.getSalesAnalytics();
      if (!mounted) return;
      setState(() {
        _analyticsData = data;
        _isLoading = false;
      });
      _animCtrl.forward(from: 0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _uploadBillingCsv() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (result == null) return;
      if (!kIsWeb && result.files.single.path == null) return;
      setState(() => _isUploading = true);

      final csvString = kIsWeb
          ? String.fromCharCodes(result.files.single.bytes!)
          : await File(result.files.single.path!).readAsString();
      List<List<dynamic>> csvTable =
      const CsvToListConverter().convert(csvString);

      if (csvTable.length <= 1) {
        throw Exception("The CSV file is empty or only contains headers.");
      }

      List<Map<String, dynamic>> officeData = [];
      for (int i = 1; i < csvTable.length; i++) {
        var row = csvTable[i];
        if (row.length >= 3) {
          officeData.add({
            'order_id': row[0].toString().trim(),
            'final_bill_no': row[1].toString().trim(),
            'billed_amount': row[2].toString().trim(),
          });
        }
      }

      final syncResult =
      await SupabaseService.instance.syncOfficeBilling(officeData);
      final updatedCount = syncResult['updated'] as int;
      final failed = List<Map<String, dynamic>>.from(syncResult['failed'] as List);
      if (mounted) {
        _showSuccessSnack("✅ Synced $updatedCount orders successfully!");
        if (failed.isNotEmpty) _showFailedRowsDialog(failed);
        _loadAnalytics();
      }
    } catch (e) {
      if (mounted) {
        _showErrorSnack("CSV Error: $e");
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  void _showSuccessSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(msg, style: GoogleFonts.manrope())),
      ]),
      backgroundColor: Colors.green.shade700,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _showErrorSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.error_rounded, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(msg, style: GoogleFonts.manrope())),
      ]),
      backgroundColor: Colors.red.shade700,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _showFailedRowsDialog(List<Map<String, dynamic>> failed) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${failed.length} Row(s) Failed to Sync',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: failed.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final row = failed[i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Order: ${row['order_id']}',
                        style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 13)),
                    const SizedBox(height: 2),
                    Text(row['reason'] as String,
                        style: GoogleFonts.manrope(fontSize: 11, color: Colors.red.shade700)),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────
  bool get _isJA => AuthService.currentTeam == 'JA';
  Color get _teamColor =>
      _isJA ? const Color(0xFF1A56DB) : const Color(0xFFD97706);
  Color get _teamColorLight =>
      _isJA ? const Color(0xFFEBF5FF) : const Color(0xFFFEF3C7);
  String get _teamName =>
      _isJA ? 'Jagannath' : 'Madhav';

  double _getMaxY(List<double> values) =>
      values.isEmpty ? 1000 : values.reduce((a, b) => a > b ? a : b) * 1.25;

  // ── Build ──────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: _teamColor, strokeWidth: 2.5),
            const SizedBox(height: 16),
            Text('Loading dashboard...',
                style: GoogleFonts.manrope(
                    fontSize: 13, color: Colors.grey.shade500)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 52, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('Failed to load',
                style: GoogleFonts.manrope(
                    fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(_error!,
                style: GoogleFonts.manrope(
                    fontSize: 12, color: Colors.grey.shade500)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadAnalytics,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: _teamColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
            )
          ],
        ),
      );
    }

    final totalSales =
        (_analyticsData?['totalSales'] as num?)?.toDouble() ?? 0.0;
    final totalOrders =
        (_analyticsData?['totalOrders'] as num?)?.toInt() ?? 0;
    final avgOrderValue =
        (_analyticsData?['avgOrderValue'] as num?)?.toDouble() ?? 0.0;
    final Map<String, dynamic> rawBeatData =
        _analyticsData?['salesByBeat'] ?? {};
    final salesByBeat = rawBeatData
        .map((k, v) => MapEntry(k, (v as num).toDouble()));

    // Derived metrics
    final topBeat = salesByBeat.isEmpty
        ? '—'
        : salesByBeat.entries
        .reduce((a, b) => a.value > b.value ? a : b)
        .key;
    final totalBeats = salesByBeat.length;

    final fmt =
    NumberFormat.currency(symbol: '₹', decimalDigits: 0, locale: 'en_IN');
    final fmtK = NumberFormat.compactCurrency(
        symbol: '₹', decimalDigits: 1, locale: 'en_IN');

    return FadeTransition(
      opacity: _fadeAnim,
      child: RefreshIndicator(
        onRefresh: _loadAnalytics,
        color: _teamColor,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ────────────────────────────────────────
              _buildHeader(),
              const SizedBox(height: 20),

              // ── KPI Cards Row ─────────────────────────────────
              _buildKpiRow(totalSales, totalOrders, avgOrderValue, fmt),
              const SizedBox(height: 16),

              // ── Secondary Metrics ─────────────────────────────
              _buildSecondaryRow(topBeat, totalBeats, totalSales, totalOrders),
              const SizedBox(height: 24),

              // ── Chart Section ─────────────────────────────────
              _buildChartSection(salesByBeat, fmt, fmtK),
              const SizedBox(height: 24),

              // ── Beat Breakdown Table ──────────────────────────
              if (salesByBeat.isNotEmpty) _buildBeatTable(salesByBeat, fmt, totalSales),
              const SizedBox(height: 24),

              // ── Office Bridge Card ────────────────────────────
              _buildOfficeBridgeCard(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Dashboard',
                  style: GoogleFonts.manrope(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.grey.shade900)),
              const SizedBox(height: 4),
              Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _teamColorLight,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(_teamName,
                    style: GoogleFonts.manrope(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: _teamColor)),
              ),
            ],
          ),
        ),
        // Refresh
        IconButton(
          onPressed: _loadAnalytics,
          icon: Icon(Icons.refresh_rounded,
              color: Colors.grey.shade500, size: 20),
          tooltip: 'Refresh',
          style: IconButton.styleFrom(
            backgroundColor: Colors.grey.shade100,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }

  // ── KPI Row ───────────────────────────────────────────────────
  Widget _buildKpiRow(
      double sales, int orders, double avg, NumberFormat fmt) {
    return Column(
      children: [
        // Revenue — full width hero card
        _KpiCard(
          label: 'Total Revenue',
          value: fmt.format(sales),
          icon: Icons.account_balance_wallet_rounded,
          color: _teamColor,
          isHero: true,
          subtitle: 'Across all beats this period',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _KpiCard(
                label: 'Orders',
                value: orders.toString(),
                icon: Icons.receipt_long_rounded,
                color: Colors.indigo.shade600,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _KpiCard(
                label: 'Avg Order',
                value: fmt.format(avg),
                icon: Icons.trending_up_rounded,
                color: Colors.teal.shade600,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Secondary Metrics ─────────────────────────────────────────
  Widget _buildSecondaryRow(
      String topBeat, int totalBeats, double sales, int orders) {
    // Daily average: total sales / days elapsed this month
    final daysElapsed = DateTime.now().day;
    final dailyAvg = daysElapsed > 0 ? sales / daysElapsed : 0.0;
    final dailyAvgStr = dailyAvg >= 1000
        ? '${(dailyAvg / 1000).toStringAsFixed(1)}K'
        : dailyAvg.toStringAsFixed(0);

    return Row(
      children: [
        Expanded(
          child: _SecondaryCard(
            label: 'Top Beat',
            value: topBeat,
            icon: Icons.emoji_events_rounded,
            iconColor: Colors.amber.shade700,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SecondaryCard(
            label: 'Active Beats',
            value: totalBeats.toString(),
            icon: Icons.route_rounded,
            iconColor: Colors.purple.shade600,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SecondaryCard(
            label: 'Daily Avg',
            value: '\u20B9$dailyAvgStr',
            icon: Icons.trending_up_rounded,
            iconColor: Colors.green.shade600,
          ),
        ),
      ],
    );
  }

  // ── Chart Section ─────────────────────────────────────────────
  Widget _buildChartSection(
      Map<String, double> data, NumberFormat fmt, NumberFormat fmtK) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade100),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 16,
              offset: const Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Chart header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Sales by Beat',
                          style: GoogleFonts.manrope(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Colors.grey.shade800)),
                      Text('Revenue distribution across routes',
                          style: GoogleFonts.manrope(
                              fontSize: 11, color: Colors.grey.shade400)),
                    ],
                  ),
                ),
                // Chart type toggle
                Container(
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      _ChartToggleBtn(
                        icon: Icons.bar_chart_rounded,
                        active: _chartView == 'beat',
                        onTap: () => setState(() => _chartView = 'beat'),
                      ),
                      _ChartToggleBtn(
                        icon: Icons.pie_chart_rounded,
                        active: _chartView == 'pie',
                        onTap: () => setState(() => _chartView = 'pie'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 240,
            child: data.isEmpty
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bar_chart_rounded,
                      size: 40, color: Colors.grey.shade200),
                  const SizedBox(height: 8),
                  Text('No data available',
                      style: GoogleFonts.manrope(
                          fontSize: 13, color: Colors.grey.shade400)),
                ],
              ),
            )
                : Padding(
              padding: const EdgeInsets.only(right: 16, left: 8),
              child: _chartView == 'beat'
                  ? _buildBarChart(data, fmtK)
                  : _buildPieChart(data, fmt),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildBarChart(Map<String, double> data, NumberFormat fmtK) {
    final maxY = _getMaxY(data.values.toList());
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxY,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => Colors.grey.shade900,
            tooltipPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            getTooltipItem: (group, _, rod, __) {
              final beat = data.keys.elementAt(group.x.toInt());
              return BarTooltipItem(
                '$beat\n',
                GoogleFonts.manrope(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
                children: [
                  TextSpan(
                    text: fmtK.format(rod.toY),
                    style: GoogleFonts.manrope(
                        color: Colors.amber.shade300,
                        fontSize: 13,
                        fontWeight: FontWeight.w800),
                  )
                ],
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i >= data.length) return const SizedBox.shrink();
                final name = data.keys.elementAt(i);
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    name.length > 5 ? name.substring(0, 5) : name,
                    style: GoogleFonts.manrope(
                        fontSize: 9,
                        color: Colors.grey.shade500,
                        fontWeight: FontWeight.w600),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 48,
              getTitlesWidget: (v, _) => Text(
                fmtK.format(v),
                style: GoogleFonts.manrope(
                    fontSize: 9, color: Colors.grey.shade400),
              ),
            ),
          ),
          topTitles:
          const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
          const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxY / 4,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: Colors.grey.shade100, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        barGroups: data.entries.toList().asMap().entries.map((e) {
          final i = e.key;
          final val = e.value.value;
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: val,
                width: 20,
                borderRadius:
                const BorderRadius.vertical(top: Radius.circular(6)),
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    _teamColor.withOpacity(0.7),
                    _teamColor,
                  ],
                ),
              )
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildPieChart(Map<String, double> data, NumberFormat fmt) {
    final total = data.values.fold(0.0, (a, b) => a + b);
    final colors = [
      _teamColor,
      Colors.indigo.shade400,
      Colors.teal.shade400,
      Colors.orange.shade400,
      Colors.purple.shade400,
      Colors.pink.shade400,
    ];

    return Row(
      children: [
        Expanded(
          child: PieChart(
            PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: 48,
              sections: data.entries.toList().asMap().entries.map((e) {
                final pct = total > 0 ? (e.value.value / total * 100) : 0.0;
                return PieChartSectionData(
                  value: e.value.value,
                  color: colors[e.key % colors.length],
                  title: '${pct.toStringAsFixed(0)}%',
                  titleStyle: GoogleFonts.manrope(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Colors.white),
                  radius: 60,
                );
              }).toList(),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: data.entries.toList().asMap().entries.map((e) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: colors[e.key % colors.length],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    e.value.key.length > 10
                        ? e.value.key.substring(0, 10)
                        : e.value.key,
                    style: GoogleFonts.manrope(
                        fontSize: 10, color: Colors.grey.shade700),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  // ── Beat Breakdown Table ──────────────────────────────────────
  Widget _buildBeatTable(
      Map<String, double> data, NumberFormat fmt, double total) {
    final sorted = data.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade100),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 12,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Row(
              children: [
                Text('Beat Breakdown',
                    style: GoogleFonts.manrope(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade800)),
                const Spacer(),
                Text('${sorted.length} routes',
                    style: GoogleFonts.manrope(
                        fontSize: 11, color: Colors.grey.shade400)),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 0.5),
          ...sorted.asMap().entries.map((e) {
            final rank = e.key + 1;
            final beat = e.value.key;
            final val = e.value.value;
            final pct = total > 0 ? val / total : 0.0;

            return Column(
              children: [
                Padding(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Row(
                    children: [
                      // Rank badge
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: rank <= 3
                              ? [
                            Colors.amber.shade50,
                            Colors.grey.shade100,
                            Colors.orange.shade50
                          ][rank - 1]
                              : Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            '#$rank',
                            style: GoogleFonts.manrope(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: rank <= 3
                                  ? [
                                Colors.amber.shade700,
                                Colors.grey.shade600,
                                Colors.orange.shade700
                              ][rank - 1]
                                  : Colors.grey.shade400,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Beat name + progress bar
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(beat,
                                style: GoogleFonts.manrope(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey.shade800)),
                            const SizedBox(height: 5),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: pct,
                                minHeight: 4,
                                backgroundColor: Colors.grey.shade100,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    _teamColor.withOpacity(0.7)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Value + pct
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(fmt.format(val),
                              style: GoogleFonts.manrope(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.grey.shade800)),
                          Text('${(pct * 100).toStringAsFixed(1)}%',
                              style: GoogleFonts.manrope(
                                  fontSize: 10, color: Colors.grey.shade400)),
                        ],
                      ),
                    ],
                  ),
                ),
                if (e.key < sorted.length - 1)
                  Divider(
                      height: 1,
                      thickness: 0.5,
                      indent: 20,
                      endIndent: 20,
                      color: Colors.grey.shade100),
              ],
            );
          }),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ── Office Bridge Card ────────────────────────────────────────
  Widget _buildOfficeBridgeCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.green.shade700, Colors.teal.shade600],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.green.withOpacity(0.25),
              blurRadius: 16,
              offset: const Offset(0, 6))
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.sync_alt_rounded,
                color: Colors.white, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Office Bridge',
                    style: GoogleFonts.manrope(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                Text('Sync Tally / Marg billing CSV',
                    style: GoogleFonts.manrope(
                        fontSize: 11,
                        color: Colors.white.withOpacity(0.75))),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: _isUploading ? null : _uploadBillingCsv,
            icon: _isUploading
                ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.green))
                : const Icon(Icons.upload_file_rounded, size: 16),
            label: Text(_isUploading ? 'Syncing...' : 'Upload CSV',
                style: GoogleFonts.manrope(
                    fontWeight: FontWeight.w700, fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.green.shade700,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Reusable Widgets ─────────────────────────────────────────────

class _KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final bool isHero;
  final String? subtitle;

  const _KpiCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.isHero = false,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(isHero ? 20 : 16),
      decoration: BoxDecoration(
        color: isHero ? color : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: isHero ? null : Border.all(color: Colors.grey.shade100),
        boxShadow: [
          BoxShadow(
            color: isHero
                ? color.withOpacity(0.25)
                : Colors.black.withOpacity(0.03),
            blurRadius: isHero ? 20 : 8,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: isHero
          ? Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: GoogleFonts.manrope(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.8),
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(value,
                    style: GoogleFonts.manrope(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
                if (subtitle != null)
                  Text(subtitle!,
                      style: GoogleFonts.manrope(
                          fontSize: 10,
                          color: Colors.white.withOpacity(0.6))),
              ],
            ),
          ),
        ],
      )
          : Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: GoogleFonts.manrope(
                        fontSize: 11, color: Colors.grey.shade500)),
                const SizedBox(height: 2),
                Text(value,
                    style: GoogleFonts.manrope(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade800)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SecondaryCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color iconColor;

  const _SecondaryCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade100),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 18),
          const SizedBox(height: 8),
          Text(value,
              style: GoogleFonts.manrope(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Colors.grey.shade800),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(label,
              style: GoogleFonts.manrope(
                  fontSize: 10, color: Colors.grey.shade400),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _ChartToggleBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _ChartToggleBtn(
      {required this.icon, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: active
              ? [
            BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 4,
                offset: const Offset(0, 1))
          ]
              : [],
        ),
        child: Icon(icon,
            size: 16,
            color: active ? Colors.grey.shade700 : Colors.grey.shade400),
      ),
    );
  }
}