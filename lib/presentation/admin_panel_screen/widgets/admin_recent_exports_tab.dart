import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/empty_state_widget.dart';

/// Phase F of ORDERS_EXPORT_OVERHAUL: history of every admin export run.
/// Lists last 20 `export_batches` rows. Super-admins get per-row Undo
/// that restores previous statuses via the `undo_export_batch` RPC.
class AdminRecentExportsTab extends StatefulWidget {
  const AdminRecentExportsTab({super.key});

  @override
  State<AdminRecentExportsTab> createState() => _AdminRecentExportsTabState();
}

class _AdminRecentExportsTabState extends State<AdminRecentExportsTab> {
  final _service = SupabaseService.instance;
  List<Map<String, dynamic>> _batches = [];
  bool _loading = true;
  bool _isSuperAdmin = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRole();
    _loadBatches();
  }

  Future<void> _loadRole() async {
    final role = _service.currentUserRole;
    if (mounted) setState(() => _isSuperAdmin = role == 'super_admin');
  }

  Future<void> _loadBatches() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _service.getRecentExportBatches(limit: 20);
      if (!mounted) return;
      setState(() {
        _batches = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _undo(Map<String, dynamic> batch) async {
    final deliveredIds = (batch['orders_marked_delivered'] as List?) ?? const [];
    final lineItemIds = (batch['line_item_ids_written'] as List?) ?? const [];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Undo this export?',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: Text(
          'Restores previous statuses on ${deliveredIds.length} order(s) and '
          'un-tracks ${lineItemIds.length} line item(s). Cannot be re-undone.',
          style: GoogleFonts.manrope(fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Undo'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _service.undoExportBatch(batch['id'].toString());
      if (!mounted) return;
      Fluttertoast.showToast(msg: 'Export batch undone');
      await _loadBatches();
    } catch (e) {
      if (!mounted) return;
      Fluttertoast.showToast(
        msg: 'Undo failed: $e',
        toastLength: Toast.LENGTH_LONG,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 8),
            Text('Failed to load recent exports',
                style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _loadBatches,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_batches.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadBatches,
        child: ListView(
          children: const [
            SizedBox(height: 80),
            EmptyStateWidget(
              title: 'No exports yet',
              description:
                  'Runs of the CSV export will appear here, newest first.',
              icon: Icons.history_rounded,
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadBatches,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: _batches.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _buildBatchCard(_batches[i]),
      ),
    );
  }

  Widget _buildBatchCard(Map<String, dynamic> b) {
    final exportedAt = DateTime.tryParse(b['exported_at']?.toString() ?? '');
    final exportedBy = b['exported_by_name']?.toString() ?? 'unknown';
    final jaName = b['ja_file_name']?.toString();
    final maName = b['ma_file_name']?.toString();
    final jaRange = b['ja_invoice_range']?.toString();
    final maRange = b['ma_invoice_range']?.toString();
    final orderIds = (b['order_ids'] as List?) ?? const [];
    final deliveredIds = (b['orders_marked_delivered'] as List?) ?? const [];
    final lineItemIds = (b['line_item_ids_written'] as List?) ?? const [];
    final prevStatuses = b['previous_statuses'];
    final wasUndone = prevStatuses is Map && prevStatuses.isEmpty;
    final when = exportedAt != null
        ? '${exportedAt.day.toString().padLeft(2, '0')}/'
            '${exportedAt.month.toString().padLeft(2, '0')}/'
            '${exportedAt.year} '
            '${exportedAt.hour.toString().padLeft(2, '0')}:'
            '${exportedAt.minute.toString().padLeft(2, '0')}'
        : '—';

    final canUndo = _isSuperAdmin && !wasUndone && deliveredIds.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (jaName != null)
                      Text(
                        '📄 $jaName'
                        '${jaRange != null && jaRange.isNotEmpty ? '  ·  $jaRange' : ''}',
                        style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    if (maName != null)
                      Text(
                        '📄 $maName'
                        '${maRange != null && maRange.isNotEmpty ? '  ·  $maRange' : ''}',
                        style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      '$when  ·  $exportedBy',
                      style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (wasUndone)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('UNDONE',
                      style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.grey.shade700)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _miniStat('Orders', orderIds.length.toString()),
              const SizedBox(width: 12),
              _miniStat('Line items', lineItemIds.length.toString()),
              const SizedBox(width: 12),
              _miniStat(
                'Delivered',
                deliveredIds.length.toString(),
                highlight: deliveredIds.isNotEmpty && !wasUndone,
              ),
              const Spacer(),
              if (canUndo)
                TextButton.icon(
                  onPressed: () => _undo(b),
                  icon: Icon(Icons.undo_rounded, size: 16, color: Colors.red.shade700),
                  label: Text('Undo',
                      style: GoogleFonts.manrope(fontSize: 12, color: Colors.red.shade700, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value, {bool highlight = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant)),
        Text(value,
            style: GoogleFonts.manrope(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: highlight ? AppTheme.success : AppTheme.onSurface,
            )),
      ],
    );
  }
}
