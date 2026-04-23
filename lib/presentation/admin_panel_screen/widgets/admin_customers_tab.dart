import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';

import '../../../core/search_utils.dart';
import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';
import './admin_shared_widgets.dart';
import '../../../services/auth_service.dart';
import '../../../widgets/empty_state_widget.dart';

class AdminCustomersTab extends StatefulWidget {
  const AdminCustomersTab({super.key});

  @override
  State<AdminCustomersTab> createState() => _AdminCustomersTabState();
}

class _AdminCustomersTabState extends State<AdminCustomersTab> {
  bool _isLoading = true;
  List<CustomerModel> _customers = [];
  List<CustomerModel> _filtered = [];
  List<BeatModel> _beatsJA = [];
  List<BeatModel> _beatsMA = [];
  int _displayLimit = 200;
  String _teamFilter = 'All'; // All, JA, MA, Unassigned
  String? _error;
  bool _isSuperAdmin = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _searchController.addListener(_applySearch);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final customers = await SupabaseService.instance.getCustomers(forceRefresh: forceRefresh);
      final beatsJA = await SupabaseService.instance.getBeatsForTeam('JA');
      final beatsMA = await SupabaseService.instance.getBeatsForTeam('MA');
      final role = await SupabaseService.instance.getUserRole();
      if (!mounted) return;
      customers.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      beatsJA.sort((a, b) => a.beatName.toLowerCase().compareTo(b.beatName.toLowerCase()));
      beatsMA.sort((a, b) => a.beatName.toLowerCase().compareTo(b.beatName.toLowerCase()));
      setState(() {
        _customers = customers;
        _filtered = customers;
        _beatsJA = beatsJA;
        _beatsMA = beatsMA;
        _isSuperAdmin = role == 'super_admin' || role == 'admin';
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

  void _applySearch() {
    final q = _searchController.text;
    setState(() {
      _displayLimit = 200;
      _filtered = _customers.where((c) {
        // Team filter — tolerant: customer counts as "in team X" if EITHER
        // the team flag is set OR a beat is assigned for that team. Mirrors
        // the rep-side view so admin sees the same customers the reps see.
        if (_teamFilter == 'JA' && !(c.belongsToTeam('JA') || c.beatIdForTeam('JA') != null)) return false;
        if (_teamFilter == 'MA' && !(c.belongsToTeam('MA') || c.beatIdForTeam('MA') != null)) return false;
        if (_teamFilter == 'Unassigned') {
          final hasTeam = c.belongsToTeam('JA') || c.belongsToTeam('MA');
          final hasBeat = c.beatIdForTeam('JA') != null || c.beatIdForTeam('MA') != null;
          if (hasTeam || hasBeat) return false;
        }
        // Tokenized search filter
        return tokenMatch(q, [c.name, c.phone, c.address]);
      }).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    });
  }

  void _confirmDeleteCustomer(CustomerModel customer) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete Customer', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
        content: Text('Delete "${customer.name}"?\n\nThis will remove the customer and all team profile data. This cannot be undone.',
            style: GoogleFonts.manrope(fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.manrope(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await SupabaseService.instance.deleteCustomer(customer.id);
                if (!mounted) return;
                setState(() {
                  _customers.removeWhere((c) => c.id == customer.id);
                  _filtered.removeWhere((c) => c.id == customer.id);
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Customer deleted'), backgroundColor: Colors.green),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                );
              }
            },
            child: Text('Delete', style: GoogleFonts.manrope(color: Colors.red, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  void _showCustomerDialog(CustomerModel? customer) {
    final nameCtrl = TextEditingController(text: customer?.name ?? '');
    final phoneCtrl = TextEditingController(text: customer?.phone ?? '');
    final addressCtrl = TextEditingController(text: customer?.address ?? '');
    final outstandingJaCtrl = TextEditingController(
      text: customer?.outstandingForTeam('JA').toStringAsFixed(2) ?? '0.00',
    );
    final outstandingMaCtrl = TextEditingController(
      text: customer?.outstandingForTeam('MA').toStringAsFixed(2) ?? '0.00',
    );

    final types = ['General Trade', 'Modern Trade', 'Wholesale', 'HoReCa', 'Pharmacy', 'Other'];
    final deliveryRoutes = ['Unassigned', 'North Route', 'City Center', 'Industrial Area', 'West Ring Road', 'Highway A'];
    final teamOptions = ['JA', 'MA', 'Both'];

    String? selectedType = types.contains(customer?.type) ? customer?.type : types.first;
    String? selectedRoute = deliveryRoutes.contains(customer?.deliveryRoute) ? customer?.deliveryRoute : 'Unassigned';

    // Per-team beat selections
    final jaBeatId = customer?.beatIdForTeam('JA');
    final maBeatId = customer?.beatIdForTeam('MA');
    String? selectedBeatIdJA = _beatsJA.any((b) => b.id == jaBeatId) ? jaBeatId : null;
    String? selectedBeatIdMA = _beatsMA.any((b) => b.id == maBeatId) ? maBeatId : null;

    // Per-team ordering-beat override — null means "use primary beat for
    // ordering too". Loaded from existing override if present; cleared to
    // null when admin unchecks the checkbox.
    final jaOrderBeatId = customer?.orderBeatIdOverrideForTeam('JA');
    final maOrderBeatId = customer?.orderBeatIdOverrideForTeam('MA');
    String? selectedOrderBeatIdJA =
        _beatsJA.any((b) => b.id == jaOrderBeatId) ? jaOrderBeatId : null;
    String? selectedOrderBeatIdMA =
        _beatsMA.any((b) => b.id == maOrderBeatId) ? maOrderBeatId : null;
    bool useOrderBeatJA =
        customer?.hasOrderBeatOverrideForTeam('JA') ?? false;
    bool useOrderBeatMA =
        customer?.hasOrderBeatOverrideForTeam('MA') ?? false;

    // Pre-populate team from customer profile
    String selectedTeamAssignment;
    if (customer != null) {
      final inJA = customer.belongsToTeam('JA');
      final inMA = customer.belongsToTeam('MA');
      if (inJA && inMA) {
        selectedTeamAssignment = 'Both';
      } else if (inMA) {
        selectedTeamAssignment = 'MA';
      } else {
        selectedTeamAssignment = 'JA';
      }
    } else {
      selectedTeamAssignment = AuthService.currentTeam;
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(customer == null ? 'Add Customer' : 'Edit Customer', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                buildAdminTextField('Name', nameCtrl),
                const SizedBox(height: 10),
                buildAdminTextField('Phone', phoneCtrl, keyboardType: TextInputType.phone),
                const SizedBox(height: 10),
                buildAdminTextField('Address', addressCtrl),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: selectedTeamAssignment,
                  decoration: InputDecoration(labelText: 'Team Assignment', border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
                  items: teamOptions.map((t) => DropdownMenuItem(value: t, child: Text(
                    t == 'JA' ? 'Jagannath (JA)' : t == 'MA' ? 'Madhav (MA)' : 'Both Teams',
                    style: GoogleFonts.manrope(fontSize: 13),
                  ))).toList(),
                  onChanged: (v) => setDialogState(() { if (v != null) selectedTeamAssignment = v; }),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: selectedType,
                  decoration: InputDecoration(labelText: 'Customer Type', border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
                  items: types.map((t) => DropdownMenuItem(value: t, child: Text(t, style: GoogleFonts.manrope(fontSize: 13)))).toList(),
                  onChanged: (v) => setDialogState(() => selectedType = v),
                ),
                // JA Beat dropdown — shown when team is JA or Both
                if (selectedTeamAssignment == 'JA' || selectedTeamAssignment == 'Both') ...[
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    value: selectedBeatIdJA,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: selectedTeamAssignment == 'Both' ? 'JA Beat' : 'Assign Beat',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      prefixIcon: selectedTeamAssignment == 'Both'
                          ? Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
                                child: Text('JA', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.blue)),
                              ),
                            )
                          : null,
                    ),
                    items: [
                      DropdownMenuItem<String?>(value: null, child: Text('No Beat', style: GoogleFonts.manrope(fontSize: 13))),
                      ..._beatsJA.map((b) => DropdownMenuItem<String?>(value: b.id, child: Text(b.beatName, style: GoogleFonts.manrope(fontSize: 13), overflow: TextOverflow.ellipsis))),
                    ],
                    onChanged: (v) => setDialogState(() => selectedBeatIdJA = v),
                  ),
                  // JA ordering-beat override: ACMAST-synced beat above is
                  // used for collection/outstanding. When this checkbox is
                  // on, the customer ALSO appears on the picked beat's list
                  // for order-taking (so rep on that route can place orders
                  // even though the billing office is on a different route).
                  CheckboxListTile(
                    value: useOrderBeatJA,
                    onChanged: (v) => setDialogState(() {
                      useOrderBeatJA = v ?? false;
                      if (!useOrderBeatJA) selectedOrderBeatIdJA = null;
                    }),
                    title: Text(
                      'Different ordering beat (JA)',
                      style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      useOrderBeatJA
                          ? 'Rep will see this customer on the chosen beat for orders; collection stays on the primary beat above.'
                          : 'Rep sees the customer only on the primary beat.',
                      style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  if (useOrderBeatJA) ...[
                    const SizedBox(height: 4),
                    DropdownButtonFormField<String?>(
                      value: selectedOrderBeatIdJA,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Ordering beat (JA)',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      items: _beatsJA
                          .map((b) => DropdownMenuItem<String?>(
                                value: b.id,
                                child: Text(b.beatName, style: GoogleFonts.manrope(fontSize: 13), overflow: TextOverflow.ellipsis),
                              ))
                          .toList(),
                      onChanged: (v) => setDialogState(() => selectedOrderBeatIdJA = v),
                    ),
                  ],
                ],
                // MA Beat dropdown — shown when team is MA or Both
                if (selectedTeamAssignment == 'MA' || selectedTeamAssignment == 'Both') ...[
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    value: selectedBeatIdMA,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: selectedTeamAssignment == 'Both' ? 'MA Beat' : 'Assign Beat',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      prefixIcon: selectedTeamAssignment == 'Both'
                          ? Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
                                child: Text('MA', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.orange)),
                              ),
                            )
                          : null,
                    ),
                    items: [
                      DropdownMenuItem<String?>(value: null, child: Text('No Beat', style: GoogleFonts.manrope(fontSize: 13))),
                      ..._beatsMA.map((b) => DropdownMenuItem<String?>(value: b.id, child: Text(b.beatName, style: GoogleFonts.manrope(fontSize: 13), overflow: TextOverflow.ellipsis))),
                    ],
                    onChanged: (v) => setDialogState(() => selectedBeatIdMA = v),
                  ),
                  // MA ordering-beat override — same pattern as JA.
                  CheckboxListTile(
                    value: useOrderBeatMA,
                    onChanged: (v) => setDialogState(() {
                      useOrderBeatMA = v ?? false;
                      if (!useOrderBeatMA) selectedOrderBeatIdMA = null;
                    }),
                    title: Text(
                      'Different ordering beat (MA)',
                      style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      useOrderBeatMA
                          ? 'Rep will see this customer on the chosen beat for orders; collection stays on the primary beat above.'
                          : 'Rep sees the customer only on the primary beat.',
                      style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  if (useOrderBeatMA) ...[
                    const SizedBox(height: 4),
                    DropdownButtonFormField<String?>(
                      value: selectedOrderBeatIdMA,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Ordering beat (MA)',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      items: _beatsMA
                          .map((b) => DropdownMenuItem<String?>(
                                value: b.id,
                                child: Text(b.beatName, style: GoogleFonts.manrope(fontSize: 13), overflow: TextOverflow.ellipsis),
                              ))
                          .toList(),
                      onChanged: (v) => setDialogState(() => selectedOrderBeatIdMA = v),
                    ),
                  ],
                ],
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: selectedRoute,
                  decoration: InputDecoration(labelText: 'Delivery Route (Logistics)', border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
                  items: deliveryRoutes.map((route) => DropdownMenuItem(value: route, child: Text(route, style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.primary, fontWeight: FontWeight.bold)))).toList(),
                  onChanged: (v) => setDialogState(() => selectedRoute = v),
                ),
                // Outstanding balance — only super_admin or admin can edit
                if (_isSuperAdmin && customer != null) ...[
                  if (selectedTeamAssignment == 'JA' || selectedTeamAssignment == 'Both') ...[
                    const SizedBox(height: 10),
                    buildAdminTextField(
                      selectedTeamAssignment == 'Both' ? 'JA Outstanding — Admin Only' : 'Outstanding Balance — Admin Only',
                      outstandingJaCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ],
                  if (selectedTeamAssignment == 'MA' || selectedTeamAssignment == 'Both') ...[
                    const SizedBox(height: 10),
                    buildAdminTextField(
                      selectedTeamAssignment == 'Both' ? 'MA Outstanding — Admin Only' : 'Outstanding Balance — Admin Only',
                      outstandingMaCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    'Editing outstanding directly. Use CSV upload for bulk changes.',
                    style: GoogleFonts.manrope(fontSize: 10, color: Colors.orange.shade700),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            // Delete offered only when editing an existing customer.
            // Closes the dialog first, then _confirmDeleteCustomer opens its
            // own Cancel/Delete AlertDialog. Same safety pattern as products
            // tab (#SA4).
            if (customer != null)
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _confirmDeleteCustomer(customer);
                },
                icon: Icon(Icons.delete_outline_rounded, color: Colors.red.shade600, size: 18),
                label: Text('Delete', style: GoogleFonts.manrope(color: Colors.red.shade600, fontWeight: FontWeight.w700)),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.manrope())),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  final teamJa = selectedTeamAssignment == 'JA' || selectedTeamAssignment == 'Both';
                  final teamMa = selectedTeamAssignment == 'MA' || selectedTeamAssignment == 'Both';

                  // Resolve beat names
                  final beatNameJA = _beatsJA.where((b) => b.id == selectedBeatIdJA).map((b) => b.beatName).firstOrNull ?? '';
                  final beatNameMA = _beatsMA.where((b) => b.id == selectedBeatIdMA).map((b) => b.beatName).firstOrNull ?? '';
                  // Resolve ordering-beat override values. Only set when the
                  // checkbox is on AND a beat is picked; otherwise null out
                  // both fields so a previously-saved override is cleared.
                  final String? orderBeatIdJaPersist =
                      (useOrderBeatJA && selectedOrderBeatIdJA != null) ? selectedOrderBeatIdJA : null;
                  final String orderBeatNameJaPersist = orderBeatIdJaPersist == null
                      ? ''
                      : (_beatsJA.where((b) => b.id == orderBeatIdJaPersist).map((b) => b.beatName).firstOrNull ?? '');
                  final String? orderBeatIdMaPersist =
                      (useOrderBeatMA && selectedOrderBeatIdMA != null) ? selectedOrderBeatIdMA : null;
                  final String orderBeatNameMaPersist = orderBeatIdMaPersist == null
                      ? ''
                      : (_beatsMA.where((b) => b.id == orderBeatIdMaPersist).map((b) => b.beatName).firstOrNull ?? '');

                  if (customer == null) {
                    // Create customer with default beat for current team
                    final defaultBeatId = AuthService.currentTeam == 'JA' ? selectedBeatIdJA : selectedBeatIdMA;
                    final defaultBeatName = AuthService.currentTeam == 'JA' ? beatNameJA : beatNameMA;
                    await SupabaseService.instance.createCustomer(
                      name: nameCtrl.text.trim(), phone: phoneCtrl.text.trim(),
                      address: addressCtrl.text.trim(), type: selectedType ?? 'General Trade',
                      beatId: defaultBeatId, beat: defaultBeatName, deliveryRoute: selectedRoute ?? 'Unassigned',
                    );
                    final newCusts = await SupabaseService.instance.getCustomers(forceRefresh: true);
                    final created = newCusts.where((c) => c.name == nameCtrl.text.trim() && c.phone == phoneCtrl.text.trim()).toList();
                    if (created.isNotEmpty) {
                      await SupabaseService.instance.client
                          .from('customer_team_profiles')
                          .update({
                            'team_ja': teamJa, 'team_ma': teamMa,
                            'beat_id_ja': selectedBeatIdJA, 'beat_name_ja': beatNameJA,
                            'beat_id_ma': selectedBeatIdMA, 'beat_name_ma': beatNameMA,
                            'order_beat_id_ja': orderBeatIdJaPersist,
                            'order_beat_name_ja': orderBeatNameJaPersist,
                            'order_beat_id_ma': orderBeatIdMaPersist,
                            'order_beat_name_ma': orderBeatNameMaPersist,
                          })
                          .eq('customer_id', created.first.id);
                    }
                    _load(forceRefresh: true);
                  } else {
                    await SupabaseService.instance.updateCustomer(
                      id: customer.id, name: nameCtrl.text.trim(), phone: phoneCtrl.text.trim(),
                      address: addressCtrl.text.trim(), type: selectedType ?? customer.type,
                      beatId: null, beat: '', deliveryRoute: selectedRoute ?? 'Unassigned',
                    );
                    // Update team flags + per-team beats + ordering-beat
                    // overrides (cleared to null when the checkbox was off).
                    final profileUpdate = <String, dynamic>{
                      'team_ja': teamJa, 'team_ma': teamMa,
                      'beat_id_ja': teamJa ? selectedBeatIdJA : null,
                      'beat_name_ja': teamJa ? beatNameJA : '',
                      'beat_id_ma': teamMa ? selectedBeatIdMA : null,
                      'beat_name_ma': teamMa ? beatNameMA : '',
                      'order_beat_id_ja': teamJa ? orderBeatIdJaPersist : null,
                      'order_beat_name_ja': teamJa ? orderBeatNameJaPersist : '',
                      'order_beat_id_ma': teamMa ? orderBeatIdMaPersist : null,
                      'order_beat_name_ma': teamMa ? orderBeatNameMaPersist : '',
                    };
                    // Outstanding balance (admin only)
                    if (_isSuperAdmin) {
                      if (teamJa) {
                        final val = double.tryParse(outstandingJaCtrl.text.trim());
                        if (val != null) profileUpdate['outstanding_ja'] = val;
                      }
                      if (teamMa) {
                        final val = double.tryParse(outstandingMaCtrl.text.trim());
                        if (val != null) profileUpdate['outstanding_ma'] = val;
                      }
                    }
                    await SupabaseService.instance.client
                        .from('customer_team_profiles')
                        .update(profileUpdate)
                        .eq('customer_id', customer.id);
                    // Refresh only the edited customer in-place
                    final updated = await SupabaseService.instance.getCustomerById(customer.id);
                    if (updated != null && mounted) {
                      setState(() {
                        final idx = _customers.indexWhere((c) => c.id == customer.id);
                        if (idx != -1) _customers[idx] = updated;
                        final fIdx = _filtered.indexWhere((c) => c.id == customer.id);
                        if (fIdx != -1) _filtered[fIdx] = updated;
                      });
                    }
                  }
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(customer == null ? 'Customer added' : 'Customer updated'), backgroundColor: AppTheme.success));
                } catch (e) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
                }
              },
              child: Text('Save', style: GoogleFonts.manrope(color: Colors.white)),
            ),
          ],
        ),
      ),
    ).then((_) {
      nameCtrl.dispose();
      phoneCtrl.dispose();
      addressCtrl.dispose();
      outstandingJaCtrl.dispose();
      outstandingMaCtrl.dispose();
    });
  }

  Widget _buildFilterChip(String label) {
    final selected = _teamFilter == label;
    final isUnassigned = label == 'Unassigned';
    final unassignedCount = isUnassigned
        ? _customers.where((c) => !c.belongsToTeam('JA') && !c.belongsToTeam('MA') && c.beatIdForTeam('JA') == null && c.beatIdForTeam('MA') == null).length
        : 0;
    final chipColor = isUnassigned ? Colors.red : AppTheme.primary;
    final displayLabel = isUnassigned && unassignedCount > 0 ? '$label ($unassignedCount)' : label;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: selected ? chipColor : chipColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: selected ? chipColor : chipColor.withValues(alpha: 0.3), width: 1),
      ),
      child: Text(
        displayLabel,
        style: GoogleFonts.manrope(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: selected ? Colors.white : chipColor,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return AdminErrorRetry(message: _error!, onRetry: _load);

    return Scaffold(
      backgroundColor: AppTheme.background,
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'csv_upload',
            backgroundColor: Colors.teal,
            foregroundColor: Colors.white,
            mini: true,
            tooltip: 'Update Outstanding via CSV',
            onPressed: _showCsvUploadSheet,
            child: const Icon(Icons.upload_file_rounded),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            heroTag: 'add_customer',
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.person_add_rounded),
            label: Text('Add Customer', style: GoogleFonts.manrope(fontSize: 13)),
            onPressed: () => _showCustomerDialog(null),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Search Bar ───────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              style: GoogleFonts.manrope(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search by name or phone...',
                hintStyle: GoogleFonts.manrope(
                    fontSize: 13, color: Colors.grey.shade500),
                prefixIcon:
                    Icon(Icons.search_rounded, color: AppTheme.primary, size: 20),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded,
                            size: 18, color: Colors.grey),
                        onPressed: () {
                          _searchController.clear();
                          _applySearch();
                        },
                      )
                    : null,
                filled: true,
                fillColor: AppTheme.primary.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
          // ── Team filter chips ────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                for (final filter in ['All', 'JA', 'MA', 'Unassigned'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _teamFilter = filter);
                        _applySearch();
                      },
                      child: _buildFilterChip(filter),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  '${_filtered.length} customer${_filtered.length == 1 ? '' : 's'}',
                  style: GoogleFonts.manrope(
                      fontSize: 11,
                      color: Colors.grey.shade500,
                      fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // ── Customer List ─────────────────────────────────────
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(forceRefresh: true),
              color: AppTheme.primary,
              child: _filtered.isEmpty
                  ? const EmptyStateWidget(
                      icon: Icons.people_outline_rounded,
                      title: 'No customers found',
                      description: 'Try adjusting your search or filters.',
                    )
                  : NotificationListener<ScrollNotification>(
                      onNotification: (scroll) {
                        if (scroll.metrics.pixels > scroll.metrics.maxScrollExtent - 200 && _displayLimit < _filtered.length) {
                          setState(() => _displayLimit += 200);
                        }
                        return false;
                      },
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                        itemCount: _displayLimit < _filtered.length ? _displayLimit + 1 : _filtered.length,
                        itemBuilder: (context, index) {
                          if (index >= _displayLimit && index >= _filtered.length) return const SizedBox.shrink();
                          if (index == _displayLimit && _displayLimit < _filtered.length) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Center(child: Text('Loading more... (${_filtered.length - _displayLimit} remaining)', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant))),
                            );
                          }
                          final c = _filtered[index];
                          return _CustomerCard(
                            customer: c,
                            onEdit: () => _showCustomerDialog(c),
                          );
                        },
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCsvUploadSheet() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (result == null) return;
    if (!kIsWeb && result.files.single.path == null) return;

    final content = kIsWeb
        ? String.fromCharCodes(result.files.single.bytes!)
        : await File(result.files.single.path!).readAsString();

    List<Map<String, dynamic>> rows;
    try {
      final csvTable = const CsvToListConverter(eol: '\n').convert(content);
      if (csvTable.isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV is empty')));
        return;
      }
      final headers = csvTable.first.map((e) => e.toString().trim().toLowerCase()).toList();
      rows = csvTable.skip(1).where((r) => r.isNotEmpty).map((row) {
        final map = <String, dynamic>{};
        for (int i = 0; i < headers.length && i < row.length; i++) {
          map[headers[i]] = row[i];
        }
        return map;
      }).toList();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('CSV parse error: $e')));
      return;
    }

    if (!mounted) return;

    // Preview dialog
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Update Outstanding Balances', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${rows.length} rows found in CSV', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey.shade200)),
              child: Text('Expected columns:\ncustomer_id, team, outstanding_amount\n\nExample:\ncust-001, JA, 5000', style: GoogleFonts.manrope(fontSize: 11, color: Colors.grey.shade700)),
            ),
            if (rows.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('First row: ${rows.first}', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Update Now')),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    // Show progress
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));

    final result2 = await SupabaseService.instance.updateOutstandingFromCsv(rows);
    if (mounted) Navigator.pop(context); // dismiss progress
    if (!mounted) return;

    // Show results
    final updated = result2['updated'] as int;
    final errors = result2['errors'] as List<String>;

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Update Complete', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [const Icon(Icons.check_circle_rounded, color: Colors.green, size: 18), const SizedBox(width: 8), Expanded(child: Text('Updated: $updated customers', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, color: Colors.green)))]),
            if (errors.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(children: [const Icon(Icons.error_rounded, color: Colors.red, size: 18), const SizedBox(width: 8), Expanded(child: Text('Failed: ${errors.length}', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, color: Colors.red)))]),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 100),
                child: SingleChildScrollView(
                  child: Text(errors.join('\n'), style: GoogleFonts.manrope(fontSize: 10, color: Colors.red.shade700)),
                ),
              ),
            ],
          ],
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
      ),
    );

    _load();
  }
}

class _CustomerCard extends StatelessWidget {
  final CustomerModel customer;
  final VoidCallback onEdit;

  const _CustomerCard({
    required this.customer,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
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
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    customer.name,
                    style: GoogleFonts.manrope(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.onSurface),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  _BeatInfoRow(customer: customer),
                  const SizedBox(height: 3),
                  Text(
                    customer.phone,
                    style: GoogleFonts.manrope(
                        fontSize: 12, color: AppTheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  // ADDED: team badges
                  Row(
                    children: [
                      if (customer.belongsToTeam('JA'))
                        Container(
                          margin: const EdgeInsets.only(right: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
                          child: Text('JA', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.blue)),
                        ),
                      if (customer.belongsToTeam('MA'))
                        Container(
                          margin: const EdgeInsets.only(right: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
                          child: Text('MA', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.orange)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _BalanceRow(customer: customer),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              children: [
                // Single Edit affordance. Delete lives inside the edit dialog
                // behind a confirm (same pattern as products tab — see #SA4).
                GestureDetector(
                  onTap: onEdit,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Edit',
                      style: GoogleFonts.manrope(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BeatInfoRow extends StatelessWidget {
  final CustomerModel customer;
  const _BeatInfoRow({required this.customer});

  @override
  Widget build(BuildContext context) {
    // Show beat info if EITHER team flag is set OR a beat is assigned.
    // Some customers have beat_id_* filled from ACMAST sync but team_*
    // flag not flipped (stale data or RLS-blocked upsert). Without this
    // fallback, reps see the customer on their beat but admin couldn't.
    final inJa = customer.belongsToTeam('JA') || customer.beatIdForTeam('JA') != null;
    final inMa = customer.belongsToTeam('MA') || customer.beatIdForTeam('MA') != null;
    final jaBeat = inJa ? customer.beatNameForTeam('JA') : '';
    final maBeat = inMa ? customer.beatNameForTeam('MA') : '';
    final parts = <String>[];
    if (inJa) {
      parts.add('JA: ${jaBeat.isNotEmpty ? jaBeat : 'Unassigned'}');
    }
    if (inMa) {
      parts.add('MA: ${maBeat.isNotEmpty ? maBeat : 'Unassigned'}');
    }
    if (parts.isEmpty) parts.add('No team assigned');
    final beatText = parts.join(' · ');
    return Text(
      '$beatText · Route: ${customer.deliveryRoute}',
      style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant),
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _BalanceRow extends StatelessWidget {
  final CustomerModel customer;
  const _BalanceRow({required this.customer});

  Color _color(double bal) {
    if (bal <= 0) return Colors.green.shade600;
    if (bal > 5000) return Colors.red.shade600;
    return Colors.orange.shade600;
  }

  @override
  Widget build(BuildContext context) {
    final parts = <Widget>[];
    for (final team in ['JA', 'MA']) {
      if (!customer.belongsToTeam(team)) continue;
      final bal = customer.outstandingForTeam(team);
      final color = _color(bal);
      parts.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            bal <= 0 ? Icons.check_circle_rounded : Icons.account_balance_wallet_rounded,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 3),
          Text(
            bal <= 0 ? '$team: Clear' : '$team: ₹${bal.toStringAsFixed(0)}',
            style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ));
    }
    if (parts.isEmpty) {
      return Text('No balance info', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant));
    }
    return Wrap(spacing: 12, runSpacing: 4, children: parts);
  }
}
