import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/order_model.dart';
import '../../../services/auth_service.dart';
import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/empty_state_widget.dart';

class AdminBeatOrdersTab extends StatefulWidget {
  const AdminBeatOrdersTab({super.key});

  @override
  State<AdminBeatOrdersTab> createState() => _AdminBeatOrdersTabState();
}

class _AdminBeatOrdersTabState extends State<AdminBeatOrdersTab> {
  final _service = SupabaseService.instance;
  bool _loading = true;
  bool _isSuperAdmin = false;
  String? _error;
  List<OrderModel> _allPendingOrders = [];
  List<OrderModel> _displayedOrders = [];
  List<String> _beats = [];
  String? _selectedBeat;
  String _selectedTeamFilter = 'JA';
  final Set<String> _selectedIds = {};

  static const _adminOnlyStatuses = {'Cancelled', 'Returned', 'Partially Delivered'};

  @override
  void initState() {
    super.initState();
    _loadRole();
    _loadOrders();
  }

  Future<void> _loadRole() async {
    final role = await _service.getUserRole();
    if (mounted) setState(() => _isSuperAdmin = role == 'super_admin' || role == 'admin');
  }

  Future<void> _loadOrders() async {
    setState(() { _loading = true; _error = null; });
    try {
      final orders = await _service.getOrdersByDateRange(
        teamId: _selectedTeamFilter,
        limit: 500,
        offset: 0,
        forceRefresh: true,
      );
      final pending = orders.where((o) => o.status.toLowerCase() == 'pending').toList();
      final beatSet = pending.map((o) => o.beat).where((b) => b.isNotEmpty).toSet().toList()..sort();
      setState(() {
        _allPendingOrders = pending;
        _beats = beatSet;
        // Default to first beat, or null if no beats
        if (_selectedBeat == null || !beatSet.contains(_selectedBeat)) {
          _selectedBeat = beatSet.isNotEmpty ? beatSet.first : null;
        }
        _loading = false;
        _applyBeatFilter();
      });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  void _applyBeatFilter() {
    setState(() {
      _selectedIds.clear();
      if (_selectedBeat == null) {
        _displayedOrders = _allPendingOrders;
      } else {
        _displayedOrders = _allPendingOrders.where((o) => o.beat == _selectedBeat).toList();
      }
    });
  }

  Color _statusColor(String status) {
    return switch (status.toLowerCase()) {
      'pending' => AppTheme.warning,
      'confirmed' => Colors.blue,
      'delivered' => AppTheme.success,
      'invoiced' => Colors.teal,
      'paid' => Colors.green.shade700,
      'cancelled' => AppTheme.error,
      'returned' => Colors.red.shade700,
      'partially delivered' => Colors.orange,
      _ => AppTheme.primary,
    };
  }

  void _showStatusPicker(OrderModel order) {
    final allStatuses = ['Pending', 'Confirmed', 'Delivered', 'Invoiced', 'Paid', 'Cancelled', 'Returned', 'Partially Delivered'];
    final available = _isSuperAdmin
        ? allStatuses.where((s) => s != order.status).toList()
        : allStatuses.where((s) => s != order.status && !_adminOnlyStatuses.contains(s)).toList();

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Change Status', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('${order.customerName} — current: ${order.status}',
                style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: available.map((s) {
                final isDestructive = _adminOnlyStatuses.contains(s);
                return ActionChip(
                  label: Text(s),
                  backgroundColor: isDestructive ? Colors.red.shade50 : Colors.blue.shade50,
                  labelStyle: TextStyle(
                    color: isDestructive ? Colors.red : Colors.blue.shade800,
                    fontWeight: FontWeight.w600,
                  ),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    try {
                      await _service.updateOrderStatus(order.id, s, isSuperAdmin: _isSuperAdmin);
                      setState(() {
                        final idx = _allPendingOrders.indexWhere((o) => o.id == order.id);
                        if (idx != -1) {
                          if (s.toLowerCase() != 'pending') {
                            _allPendingOrders.removeAt(idx);
                          } else {
                            _allPendingOrders[idx] = _allPendingOrders[idx].copyWithStatus(s);
                          }
                        }
                        _applyBeatFilter();
                      });
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('Order marked $s'),
                          backgroundColor: isDestructive ? Colors.red : Colors.green,
                        ));
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('Error: $e'),
                          backgroundColor: AppTheme.error,
                        ));
                      }
                    }
                  },
                );
              }).toList(),
            ),
            if (!_isSuperAdmin)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Cancel / Return / Partial Delivery requires super_admin role.',
                  style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedIds.length == _displayedOrders.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(_displayedOrders.map((o) => o.id));
      }
    });
  }

  void _showBulkStatusPicker() {
    final count = _selectedIds.length;
    final beatName = _selectedBeat ?? 'All';
    final allStatuses = ['Confirmed', 'Delivered', 'Invoiced', 'Paid', 'Cancelled', 'Returned', 'Partially Delivered'];
    final available = _isSuperAdmin
        ? allStatuses
        : allStatuses.where((s) => !_adminOnlyStatuses.contains(s)).toList();

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Bulk Status Change', style: GoogleFonts.manrope(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('$count order${count == 1 ? '' : 's'} selected  •  Beat: $beatName',
                style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: available.map((s) {
                final isDestructive = _adminOnlyStatuses.contains(s);
                return ActionChip(
                  label: Text(s),
                  backgroundColor: isDestructive ? Colors.red.shade50 : Colors.blue.shade50,
                  labelStyle: TextStyle(
                    color: isDestructive ? Colors.red : Colors.blue.shade800,
                    fontWeight: FontWeight.w600,
                  ),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    // Confirmation dialog
                    final confirm = await _showConfirmation(
                      'Change $count order${count == 1 ? '' : 's'} to "$s"?',
                      'Beat: $beatName',
                    );
                    if (!confirm) return;
                    await _executeBulkChange(_selectedIds.toList(), s, isDestructive);
                  },
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  /// Multi-beat bulk status change popup
  void _showMultiBeatStatusPicker() {
    final selectedBeats = <String>{};
    final allStatuses = ['Confirmed', 'Delivered', 'Invoiced', 'Paid', 'Cancelled', 'Returned', 'Partially Delivered'];
    final available = _isSuperAdmin
        ? allStatuses
        : allStatuses.where((s) => !_adminOnlyStatuses.contains(s)).toList();

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            // Count orders for selected beats
            final matchingOrders = _allPendingOrders.where((o) => selectedBeats.contains(o.beat)).toList();
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text('Beat Bulk Change', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Select beats to change all pending orders',
                        style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant)),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _beats.length,
                        itemBuilder: (_, i) {
                          final beat = _beats[i];
                          final count = _allPendingOrders.where((o) => o.beat == beat).length;
                          return CheckboxListTile(
                            dense: true,
                            title: Text(beat, style: GoogleFonts.manrope(fontSize: 13)),
                            subtitle: Text('$count pending', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                            value: selectedBeats.contains(beat),
                            onChanged: (_) {
                              setDialogState(() {
                                if (selectedBeats.contains(beat)) {
                                  selectedBeats.remove(beat);
                                } else {
                                  selectedBeats.add(beat);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                    if (selectedBeats.isNotEmpty) ...[
                      const Divider(),
                      Text('${matchingOrders.length} order${matchingOrders.length == 1 ? '' : 's'} — Change to:',
                          style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: available.map((s) {
                          final isDestructive = _adminOnlyStatuses.contains(s);
                          return ActionChip(
                            label: Text(s),
                            backgroundColor: isDestructive ? Colors.red.shade50 : Colors.blue.shade50,
                            labelStyle: TextStyle(
                              color: isDestructive ? Colors.red : Colors.blue.shade800,
                              fontWeight: FontWeight.w600,
                            ),
                            onPressed: () async {
                              Navigator.pop(ctx);
                              final beatNames = selectedBeats.join(', ');
                              final confirm = await _showConfirmation(
                                'Change ${matchingOrders.length} order${matchingOrders.length == 1 ? '' : 's'} to "$s"?',
                                'Beats: $beatNames',
                              );
                              if (!confirm) return;
                              await _executeBulkChange(matchingOrders.map((o) => o.id).toList(), s, isDestructive);
                            },
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Cancel', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<bool> _showConfirmation(String title, String subtitle) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Confirm', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(subtitle, style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Confirm', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _executeBulkChange(List<String> ids, String newStatus, bool isDestructive) async {
    int success = 0;
    for (final id in ids) {
      try {
        await _service.updateOrderStatus(id, newStatus, isSuperAdmin: _isSuperAdmin);
        success++;
      } catch (_) {}
    }
    setState(() {
      if (newStatus.toLowerCase() != 'pending') {
        _allPendingOrders.removeWhere((o) => ids.contains(o.id));
      } else {
        for (final id in ids) {
          final idx = _allPendingOrders.indexWhere((o) => o.id == id);
          if (idx != -1) _allPendingOrders[idx] = _allPendingOrders[idx].copyWithStatus(newStatus);
        }
      }
      // Refresh beat list
      final beatSet = _allPendingOrders.map((o) => o.beat).where((b) => b.isNotEmpty).toSet().toList()..sort();
      _beats = beatSet;
      if (_selectedBeat != null && !beatSet.contains(_selectedBeat)) {
        _selectedBeat = beatSet.isNotEmpty ? beatSet.first : null;
      }
      _selectedIds.clear();
      _applyBeatFilter();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$success order${success == 1 ? '' : 's'} marked $newStatus'),
        backgroundColor: isDestructive ? Colors.red : Colors.green,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Team filter
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: ['JA', 'MA'].map((team) {
              final selected = _selectedTeamFilter == team;
              final label = team == 'JA' ? 'Jagannath' : 'Madhav';
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () {
                    setState(() { _selectedTeamFilter = team; _selectedBeat = null; });
                    _loadOrders();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: selected ? AppTheme.secondary : AppTheme.secondary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(label, style: GoogleFonts.manrope(
                      fontSize: 12, fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : AppTheme.secondary,
                    )),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        // Beat dropdown
        Container(
          color: AppTheme.surface,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Icon(Icons.map_rounded, size: 16, color: AppTheme.primary),
              const SizedBox(width: 8),
              Text('Beat:', style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(
                child: _beats.isEmpty
                    ? Text('No beats', style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant))
                    : DropdownButtonFormField<String>(
                        value: _selectedBeat,
                        isExpanded: true,
                        decoration: InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        items: _beats.map((b) {
                          final count = _allPendingOrders.where((o) => o.beat == b).length;
                          return DropdownMenuItem(
                            value: b,
                            child: Text('$b ($count)', style: GoogleFonts.manrope(fontSize: 13)),
                          );
                        }).toList(),
                        onChanged: (v) {
                          if (v != null) {
                            _selectedBeat = v;
                            _applyBeatFilter();
                          }
                        },
                      ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_displayedOrders.length} orders',
                style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Select all bar + Beat Bulk button
        if (_displayedOrders.isNotEmpty && !_loading && _error == null)
          Container(
            color: AppTheme.surface,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _toggleSelectAll,
                  child: Row(
                    children: [
                      Icon(
                        _selectedIds.length == _displayedOrders.length
                            ? Icons.check_box_rounded
                            : _selectedIds.isNotEmpty
                                ? Icons.indeterminate_check_box_rounded
                                : Icons.check_box_outline_blank_rounded,
                        size: 20,
                        color: AppTheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _selectedIds.isEmpty
                            ? 'Select All'
                            : '${_selectedIds.length} selected',
                        style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Beat Bulk button
                OutlinedButton.icon(
                  onPressed: _beats.length > 1 ? _showMultiBeatStatusPicker : null,
                  icon: const Icon(Icons.map_rounded, size: 14),
                  label: Text('Beat Bulk', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primary,
                    side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.3)),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(0, 30),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                if (_selectedIds.isNotEmpty) ...[
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() => _selectedIds.clear()),
                    child: Text('Clear', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ],
              ],
            ),
          ),
        // Orders list
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline, color: Colors.red, size: 48),
                          const SizedBox(height: 8),
                          Text('Error: $_error', textAlign: TextAlign.center, style: GoogleFonts.manrope(fontSize: 12, color: Colors.red)),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: _loadOrders,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: Text('Retry', style: GoogleFonts.manrope()),
                          ),
                        ],
                      ),
                    )
                  : _displayedOrders.isEmpty
                      ? const EmptyStateWidget(
                          icon: Icons.check_circle_outline_rounded,
                          title: 'No pending orders',
                          description: 'All orders for this beat have been processed.',
                        )
                      : Stack(
                          children: [
                            RefreshIndicator(
                              onRefresh: _loadOrders,
                              child: ListView.builder(
                                padding: EdgeInsets.fromLTRB(0, 8, 0, _selectedIds.isNotEmpty ? 80 : 8),
                                itemCount: _displayedOrders.length,
                                itemBuilder: (context, index) {
                                  final order = _displayedOrders[index];
                                  final isSelected = _selectedIds.contains(order.id);
                                  return _BeatOrderCard(
                                    order: order,
                                    statusColor: _statusColor(order.status),
                                    isSelected: isSelected,
                                    selectionMode: _selectedIds.isNotEmpty,
                                    onChangeStatus: () => _showStatusPicker(order),
                                    onTap: () {
                                      if (_selectedIds.isNotEmpty) {
                                        _toggleSelection(order.id);
                                      }
                                    },
                                    onLongPress: () => _toggleSelection(order.id),
                                  );
                                },
                              ),
                            ),
                            // Bulk action bar
                            if (_selectedIds.isNotEmpty)
                              Positioned(
                                bottom: 0, left: 0, right: 0,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, -2))],
                                    borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                                  ),
                                  child: Row(
                                    children: [
                                      Text(
                                        '${_selectedIds.length} order${_selectedIds.length == 1 ? '' : 's'}',
                                        style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w700),
                                      ),
                                      const Spacer(),
                                      FilledButton.icon(
                                        onPressed: _showBulkStatusPicker,
                                        icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                                        label: Text('Change Status', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
                                        style: FilledButton.styleFrom(
                                          backgroundColor: AppTheme.primary,
                                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
        ),
      ],
    );
  }
}

class _BeatOrderCard extends StatelessWidget {
  final OrderModel order;
  final Color statusColor;
  final bool isSelected;
  final bool selectionMode;
  final VoidCallback? onChangeStatus;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _BeatOrderCard({
    required this.order,
    required this.statusColor,
    this.isSelected = false,
    this.selectionMode = false,
    this.onChangeStatus,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final orderDate =
        '${order.orderDate.day.toString().padLeft(2, '0')}/${order.orderDate.month.toString().padLeft(2, '0')}/${order.orderDate.year}';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      elevation: 1,
      color: isSelected ? AppTheme.primaryContainer.withValues(alpha: 0.3) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10.0),
        side: isSelected ? BorderSide(color: AppTheme.primary, width: 1.5) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10.0),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  if (selectionMode) ...[
                    Icon(
                      isSelected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                      size: 20, color: AppTheme.primary,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      order.customerName,
                      style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.onSurface),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: onChangeStatus,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: statusColor.withAlpha(31),
                        borderRadius: BorderRadius.circular(6.0),
                        border: onChangeStatus != null
                            ? Border.all(color: statusColor.withValues(alpha: 0.4), width: 0.8)
                            : null,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(order.status, style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w600, color: statusColor)),
                          if (onChangeStatus != null) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.edit_outlined, size: 10, color: statusColor),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Beat & date
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.map_rounded, size: 12, color: AppTheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(order.beat, style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.calendar_today_rounded, size: 12, color: AppTheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(orderDate, style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                    ],
                  ),
                ],
              ),
              // Line items
              if (order.lineItems.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 6),
                ...order.lineItems.map(
                  (item) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Text(item.productName, style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurface), overflow: TextOverflow.ellipsis),
                        ),
                        Text('x${item.quantity}', style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
                        const SizedBox(width: 8),
                        Text('\u20B9${item.lineTotal.toStringAsFixed(2)}', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.onSurface)),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 6),
              // Total
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  'Total: \u20B9${order.grandTotal.toStringAsFixed(2)}',
                  style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.onSurface),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
