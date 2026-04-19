import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/search_utils.dart';
import '../../../services/supabase_service.dart';
import '../../../services/auth_service.dart';
import '../../../theme/app_theme.dart';
import './admin_shared_widgets.dart';

class AdminBrandAccessTab extends StatefulWidget {
  const AdminBrandAccessTab({super.key});

  @override
  State<AdminBrandAccessTab> createState() => _AdminBrandAccessTabState();
}

class _AdminBrandAccessTabState extends State<AdminBrandAccessTab> {
  bool _isLoading = true;
  List<AppUserModel> _salesReps = [];
  List<AppUserModel> _filtered = [];
  String? _error;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(_applySearch);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ADDED: track per-user config status
  Map<String, List<String>> _userBrands = {};  // userId → enabled brands (empty = open access)
  Map<String, bool> _userStock = {};           // userId → showStock

  Future<void> _load() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      // CHANGED: unified — fetch all sales reps from both teams
      final resp = await SupabaseService.instance.client.from('app_users').select().order('full_name');
      final allUsers = (resp as List).map((e) => AppUserModel.fromJson(Map<String, dynamic>.from(e))).toList();
      final reps = allUsers.where((u) => (u.role == 'sales_rep' || u.role == 'brand_rep') && u.isActive).toList();
      // ADDED: load brand access + stock visibility for each rep
      final brands = <String, List<String>>{};
      final stock = <String, bool>{};
      for (final u in reps) {
        brands[u.id] = await SupabaseService.instance.getUserBrandAccess(u.id);
        stock[u.id] = await SupabaseService.instance.getUserShowStock(u.id);
      }
      if (!mounted) return;
      setState(() {
        _salesReps = reps; _filtered = reps;
        _userBrands = brands; _userStock = stock;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  void _applySearch() {
    final q = _searchCtrl.text;
    setState(() {
      _filtered = _salesReps
          .where((u) => tokenMatch(q, [u.fullName, u.email]))
          .toList();
    });
  }

  Future<void> _openBrandSheet(AppUserModel user) async {
    // Fetch brands from BOTH teams with their team_id
    final client = SupabaseService.instance.client;
    final resp = await client.from('product_categories')
        .select('name, team_id')
        .eq('is_active', true)
        .order('name');
    final catRows = (resp as List).cast<Map<String, dynamic>>();
    // Deduplicate by name, keep track of team per brand
    final brandTeamMap = <String, String>{}; // brand → team_id
    final allBrands = <String>[];
    for (final row in catRows) {
      final name = row['name'] as String;
      if (!brandTeamMap.containsKey(name)) {
        brandTeamMap[name] = row['team_id'] as String;
        allBrands.add(name);
      }
    }
    allBrands.sort();

    // Fetch ALL enabled brands for this user across both teams
    final enabledResp = await client.from('user_brand_access')
        .select('brand')
        .eq('user_id', user.id)
        .eq('is_enabled', true);
    final enabledBrands = (enabledResp as List).map((e) => e['brand'] as String).toSet();

    // Check if user has ANY records at all
    final anyResp = await client.from('user_brand_access')
        .select('brand')
        .eq('user_id', user.id)
        .limit(1);
    final isOpenAccess = (anyResp as List).isEmpty;

    final initialShowStock = await SupabaseService.instance.getUserShowStock(user.id);

    if (!mounted) return;

    final brandStates = <String, bool>{};
    for (final b in allBrands) {
      brandStates[b] = isOpenAccess || enabledBrands.contains(b);
    }
    bool showStock = initialShowStock;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final allOn = brandStates.values.every((v) => v);
          final enabledCount = brandStates.values.where((v) => v).length;

          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.8,
            ),
            decoration: BoxDecoration(
              color: Theme.of(ctx).scaffoldBackgroundColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle
                Center(
                  child: Container(
                    width: 40, height: 4,
                    margin: const EdgeInsets.only(top: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                        child: Text(
                          user.fullName.isNotEmpty ? user.fullName[0].toUpperCase() : '?',
                          style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(user.fullName,
                                style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w700)),
                            Text('$enabledCount of ${allBrands.length} brands enabled',
                                style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      // Reset to All button
                      if (!isOpenAccess || !allOn)
                        TextButton(
                          onPressed: () async {
                            await SupabaseService.instance.resetUserBrandAccess(user.id);
                            setSheet(() {
                              for (final key in brandStates.keys) {
                                brandStates[key] = true;
                              }
                            });
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('${user.fullName} — all brands enabled'),
                                  backgroundColor: AppTheme.success,
                                ),
                              );
                            }
                          },
                          child: Text('Reset to All',
                              style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                        ),
                    ],
                  ),
                ),
                const Divider(),
                // ADDED: Stock visibility toggle
                SwitchListTile(
                  activeColor: AppTheme.primary,
                  secondary: Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      color: showStock ? Colors.green.withValues(alpha: 0.1) : Colors.orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      showStock ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                      size: 18,
                      color: showStock ? Colors.green : Colors.orange,
                    ),
                  ),
                  title: Text('Show Stock Levels',
                      style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    showStock ? 'Stock numbers visible to this salesman' : 'Stock numbers hidden from this salesman',
                    style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
                  ),
                  value: showStock,
                  onChanged: (v) async {
                    setSheet(() => showStock = v);
                    await SupabaseService.instance.setUserShowStock(user.id, v);
                  },
                ),
                const Divider(),
                // Brand list
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                    itemCount: allBrands.length,
                    itemBuilder: (_, i) {
                      final brand = allBrands[i];
                      final enabled = brandStates[brand] ?? true;
                      return SwitchListTile(
                        dense: true,
                        activeColor: AppTheme.primary,
                        title: Text(brand,
                            style: GoogleFonts.manrope(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: enabled ? AppTheme.onSurface : Colors.grey,
                            )),
                        secondary: Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: enabled
                                ? AppTheme.primary.withValues(alpha: 0.1)
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            enabled ? Icons.check_circle_rounded : Icons.block_rounded,
                            size: 18,
                            color: enabled ? AppTheme.primary : Colors.grey.shade400,
                          ),
                        ),
                        value: enabled,
                        onChanged: (v) async {
                          setSheet(() => brandStates[brand] = v);
                          // Save ALL brand states with correct team per brand
                          for (final b in allBrands) {
                            await SupabaseService.instance.setUserBrandAccess(
                              user.id, b, brandStates[b] ?? true,
                              teamId: brandTeamMap[b],
                            );
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return AdminErrorRetry(message: _error!, onRetry: _load);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Column(
        children: [
          // Search
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              style: GoogleFonts.manrope(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search sales reps...',
                hintStyle: GoogleFonts.manrope(fontSize: 13, color: Colors.grey.shade500),
                prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.primary, size: 20),
                filled: true,
                fillColor: AppTheme.primary.withValues(alpha: 0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
          // Info banner
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: Colors.blue.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Tap a sales rep to control which brands they can see. No restrictions = sees all brands.',
                    style: GoogleFonts.manrope(fontSize: 11, color: Colors.blue.shade700),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Text('${_filtered.length} sales rep${_filtered.length == 1 ? '' : 's'}',
                    style: GoogleFonts.manrope(fontSize: 12, color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          // User list
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              color: AppTheme.primary,
              child: _filtered.isEmpty
                  ? Center(child: Text('No sales reps found', style: GoogleFonts.manrope(color: Colors.grey)))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                      itemCount: _filtered.length,
                      itemBuilder: (context, index) {
                        final u = _filtered[index];
                        final brands = _userBrands[u.id] ?? [];
                        final showStock = _userStock[u.id] ?? true;
                        final hasRestrictions = brands.isNotEmpty;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: BoxDecoration(
                            color: AppTheme.surface,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: hasRestrictions ? AppTheme.primary.withValues(alpha: 0.3) : AppTheme.outlineVariant),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            leading: CircleAvatar(
                              backgroundColor: hasRestrictions
                                  ? AppTheme.primary.withValues(alpha: 0.12)
                                  : Colors.green.withValues(alpha: 0.12),
                              child: Icon(
                                hasRestrictions ? Icons.shield_rounded : Icons.lock_open_rounded,
                                size: 20,
                                color: hasRestrictions ? AppTheme.primary : Colors.green,
                              ),
                            ),
                            title: Text(
                              u.fullName,
                              style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 14),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(u.email,
                                    style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant),
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 4),
                                // ADDED: status badges
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: [
                                    _statusBadge(
                                      hasRestrictions ? '${brands.length} brands' : 'All brands',
                                      hasRestrictions ? Colors.orange : Colors.green,
                                    ),
                                    _statusBadge(
                                      showStock ? 'Stock visible' : 'Stock hidden',
                                      showStock ? Colors.green : Colors.red,
                                    ),
                                    if (hasRestrictions || !showStock)
                                      _statusBadge('Configured', AppTheme.primary),
                                  ],
                                ),
                              ],
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.primary),
                            onTap: () async {
                              await _openBrandSheet(u);
                              _load(); // ADDED: reload status after sheet closes
                            },
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}
