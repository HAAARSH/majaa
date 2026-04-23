import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../theme/app_theme.dart';
import '../../../services/auth_service.dart';
import '../../../services/supabase_service.dart';
import '../../../services/drive_sync_service.dart';
import '../../../services/google_drive_auth_service.dart';
import '../../../services/offline_service.dart';
import '../../../services/pin_service.dart';
import '../../../routes/app_routes.dart';

class AdminSettingsTab extends StatefulWidget {
  final bool isSuperAdmin;
  const AdminSettingsTab({super.key, this.isSuperAdmin = false});

  @override
  State<AdminSettingsTab> createState() => _AdminSettingsTabState();
}

class _AdminSettingsTabState extends State<AdminSettingsTab> {
  bool _isChecking = false;
  String? _statusMessage;
  bool _isHealthy = false;
  bool _driveSyncing = false;
  bool _stockSyncing = false;
  bool _isGoogleSignedIn = false;
  String? _googleEmail;

  @override
  void initState() {
    super.initState();
    _checkDatabaseHealth();
    _isGoogleSignedIn = GoogleDriveAuthService.instance.isSignedIn;
    _googleEmail = GoogleDriveAuthService.instance.userEmail;
    DriveSyncService.instance.authError.addListener(_onDriveAuthError);
  }

  void _onDriveAuthError() {
    final error = DriveSyncService.instance.authError.value;
    if (error != null && mounted) {
      // Service already called signOut — just refresh local state
      setState(() {
        _isGoogleSignedIn = GoogleDriveAuthService.instance.isSignedIn;
        _googleEmail = null;
      });
    }
  }

  @override
  void dispose() {
    DriveSyncService.instance.authError.removeListener(_onDriveAuthError);
    super.dispose();
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() => _driveSyncing = true);
    try {
      final success = await GoogleDriveAuthService.instance.signIn();
      if (!mounted) return;
      if (success) {
        setState(() {
          _isGoogleSignedIn = true;
          _googleEmail = GoogleDriveAuthService.instance.userEmail;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Signed in as $_googleEmail'), backgroundColor: Colors.green),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign-in cancelled'), backgroundColor: Colors.orange),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sign-in failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _driveSyncing = false);
    }
  }

  Future<void> _handleGoogleSignOut() async {
    await GoogleDriveAuthService.instance.signOut();
    if (mounted) {
      setState(() {
        _isGoogleSignedIn = false;
        _googleEmail = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google Drive disconnected')),
      );
    }
  }

  Future<void> _manualSync() async {
    setState(() => _driveSyncing = true);
    try {
      await DriveSyncService.instance.syncPendingPhotosNow(showSnackBars: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Drive sync completed'), backgroundColor: Colors.green, duration: Duration(seconds: 4)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sync failed: $e'), backgroundColor: Colors.red, duration: Duration(seconds: 6)),
      );
    } finally {
      if (mounted) setState(() => _driveSyncing = false);
    }
  }

  Future<void> _syncFromDrive() async {
    setState(() => _stockSyncing = true);
    // Structured per-step summary. Each entry:
    //   { 'step': 'CRN', 'status': 'ok'|'error', 'detail': '...', 'ms': 1234 }
    // Stored to Hive so the UI panel below the button persists across rebuilds
    // and tab switches — supersedes the old 6-second snackbar.
    final summary = <Map<String, dynamic>>[];
    final startedAt = DateTime.now();

    Future<void> runStep(String step, Future<void> Function() fn) async {
      final t = DateTime.now();
      try {
        await fn();
        summary.add({
          'step': step,
          'status': 'ok',
          'detail': 'done',
          'ms': DateTime.now().difference(t).inMilliseconds,
        });
      } catch (e) {
        summary.add({
          'step': step,
          'status': 'error',
          'detail': e.toString(),
          'ms': DateTime.now().difference(t).inMilliseconds,
        });
      }
    }

    try {
      // Cleanup old app collections first
      await SupabaseService.instance.cleanupOldAppCollections();

      // 1. ITMRP (Stock) — uses a result object, not a throw
      final stockT = DateTime.now();
      final stockResult = await DriveSyncService.instance.syncStockFromDrive();
      summary.add({
        'step': 'Stock (ITMRP)',
        'status': stockResult.hasError ? 'error' : 'ok',
        'detail': stockResult.hasError ? stockResult.error : '${stockResult.updated} updated',
        'ms': DateTime.now().difference(stockT).inMilliseconds,
      });

      // 2. ITTR (Bills)
      final billT = DateTime.now();
      final billResult = await DriveSyncService.instance.syncBillsFromDrive();
      summary.add({
        'step': 'Bills (ITTR)',
        'status': billResult.hasError ? 'error' : 'ok',
        'detail': billResult.hasError ? billResult.error : '${billResult.totalBills} bills',
        'ms': DateTime.now().difference(billT).inMilliseconds,
      });

      // 3. ACMAST (Customers)
      final custT = DateTime.now();
      final custResult = await DriveSyncService.instance.syncCustomersFromDrive();
      summary.add({
        'step': 'Customers (ACMAST)',
        'status': custResult.hasError ? 'error' : 'ok',
        'detail': custResult.hasError ? custResult.error : '${custResult.matched} matched',
        'ms': DateTime.now().difference(custT).inMilliseconds,
      });

      // 4-10. Remaining steps share the same try/catch pattern.
      await runStep('OPNBIL (Opening Bills)', DriveSyncService.instance.syncOutstandingBillsFromDrive);
      await runStep('INV (Invoices)', DriveSyncService.instance.syncInvoicesFromDrive);
      await runStep('Receipts (RECT+RCTBIL)', DriveSyncService.instance.syncReceiptsFromDrive);
      await runStep('Billed Items (ITTR)', DriveSyncService.instance.syncBilledItemsFromDrive);
      // Phase B additions — parity with syncAll()'s step order.
      await runStep('Credit Notes (CRN)', DriveSyncService.instance.syncCreditNotesFromDrive);
      await runStep('Advances (ADV)', DriveSyncService.instance.syncAdvancesFromDrive);
      // Tier 4 (2026-04-21) — new tables
      await runStep('Opening Bills (OPUBL)', DriveSyncService.instance.syncOpeningBillsFromDrive);
      await runStep('Ledger (LEDGER)', DriveSyncService.instance.syncLedgerFromDrive);
      await runStep('Discount Schemes (CSDS)', DriveSyncService.instance.syncCustomerDiscountSchemesFromDrive);
      await runStep('Item Master (ITEM)', DriveSyncService.instance.syncItemMasterFromDrive);
      await runStep('Item Batches (ITBNO)', DriveSyncService.instance.syncItemBatchesFromDrive);
      await runStep('Bill Books (IBOOK)', DriveSyncService.instance.syncBillBooksFromDrive);
      await runStep('Outstanding (BILLED_COLLECTED)', DriveSyncService.instance.syncBilledCollectedFromDrive);
      // 2026-04-21 — pull sync_metadata.csv last so the "DUA exported X hrs ago"
      // banner reflects a successful, complete sync cycle.
      await runStep('DUA Export Timestamp (sync_metadata)', DriveSyncService.instance.syncDuaMetadataFromDrive);

      final errorCount = summary.where((s) => s['status'] == 'error').length;

      // Persist summary + timestamp for the UI panel to read
      final box = await Hive.openBox('app_settings');
      await box.put('last_drive_sync', DateTime.now().toIso8601String());
      await box.put('last_drive_sync_summary', summary);
      await box.put('last_drive_sync_total_ms', DateTime.now().difference(startedAt).inMilliseconds);

      if (!mounted) return;
      setState(() {});

      final quick = summary.map((s) {
        final icon = s['status'] == 'ok' ? '✓' : '✗';
        return '$icon ${s['step']}';
      }).join(' · ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            errorCount == 0
                ? 'Sync complete — ${summary.length} steps OK'
                : 'Sync finished with $errorCount error${errorCount == 1 ? "" : "s"}. $quick',
            maxLines: 3,
          ),
          backgroundColor: errorCount == 0 ? Colors.green : Colors.orange,
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sync error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _stockSyncing = false);
    }
  }

  void _changePinDialog() {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Change PIN', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: oldCtrl, obscureText: true, maxLength: 4, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Current PIN', counterText: '', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: newCtrl, obscureText: true, maxLength: 4, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'New PIN (4 digits)', counterText: '', border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final ok = await PinService.instance.verify(oldCtrl.text.trim());
              if (!ok) { scaffoldMessenger.showSnackBar(const SnackBar(content: Text('Wrong current PIN'), backgroundColor: Colors.red)); return; }
              if (newCtrl.text.trim().length != 4) { scaffoldMessenger.showSnackBar(const SnackBar(content: Text('New PIN must be 4 digits'), backgroundColor: Colors.red)); return; }
              await PinService.instance.setPin(newCtrl.text.trim());
              Navigator.pop(ctx);
              scaffoldMessenger.showSnackBar(const SnackBar(content: Text('PIN changed'), backgroundColor: Colors.green));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ).then((_) { oldCtrl.dispose(); newCtrl.dispose(); });
  }

  Future<void> _checkDatabaseHealth() async {
    setState(() { _isChecking = true; _statusMessage = 'Checking connection...'; });
    try {
      await Supabase.instance.client.from('app_users').select('id').limit(1);
      setState(() { _isHealthy = true; _statusMessage = 'Connected to Supabase successfully.'; _isChecking = false; });
    } catch (e) {
      setState(() { _isHealthy = false; _statusMessage = 'Connection failed: ${e.toString()}'; _isChecking = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('System Settings', style: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.onSurface)),
        const SizedBox(height: 24),

        // ── Google Drive Sync ──────────────────────────────
        _buildSectionHeader('Google Drive Sync'),
        const SizedBox(height: 12),
        _buildDriveCard(),
        const SizedBox(height: 24),

        // ── Database Status ────────────────────────────────
        _buildSectionHeader('Database Status'),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.outlineVariant)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(_isHealthy ? Icons.check_circle_rounded : Icons.error_rounded, color: _isHealthy ? AppTheme.success : AppTheme.error, size: 20),
                const SizedBox(width: 12),
                Expanded(child: Text(_isHealthy ? 'Supabase Online' : 'Supabase Offline', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 14))),
                if (_isChecking)
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  IconButton(icon: const Icon(Icons.refresh_rounded, size: 18), onPressed: _checkDatabaseHealth, tooltip: 'Refresh Status'),
              ]),
              const SizedBox(height: 8),
              Text(_statusMessage ?? 'Unknown status', style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant)),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // ── App Information ────────────────────────────────
        _buildSectionHeader('App Information'),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.outlineVariant)),
          child: Column(children: [
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (_, snap) {
                // Pubspec version like "1.2.5+9" maps to version + buildNumber.
                // Fall back to "loading..." during the first frame; "unknown"
                // if the plugin fails (shouldn't happen on mobile builds).
                final v = snap.data;
                final label = v == null
                    ? 'loading…'
                    : '${v.version}+${v.buildNumber}';
                return _buildInfoTile('App Version', label);
              },
            ),
            const Divider(height: 12),
            _buildInfoTile('Environment', 'Production'),
            const Divider(height: 12),
            _buildInfoTile('Current Team', AuthService.currentTeam == 'JA' ? 'Jagannath (JA)' : 'Madhav (MA)'),
            const Divider(height: 12),
            _buildInfoTile('Logged-in User', Supabase.instance.client.auth.currentUser?.email ?? '—'),
          ]),
        ),
        const SizedBox(height: 24),

        // ── PIN Management (Super Admin only) ──────────────
        if (widget.isSuperAdmin) ...[
          _buildSectionHeader('Security PIN'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.outlineVariant)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.lock_rounded, color: AppTheme.primary, size: 20),
                const SizedBox(width: 10),
                Text('Destructive Operations PIN', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 14)),
              ]),
              const SizedBox(height: 8),
              Text('PIN required for bulk deletes and dangerous operations. Only super admin can change this.',
                style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _changePinDialog,
                    icon: const Icon(Icons.edit_rounded, size: 16),
                    label: Text('Change PIN', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await PinService.instance.resetToDefault();
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN reset to default (0903)'), backgroundColor: Colors.green));
                    },
                    icon: const Icon(Icons.restore_rounded, size: 16),
                    label: Text('Reset to Default', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ]),
          ),
          const SizedBox(height: 24),
        ],

        // ── Actions ────────────────────────────────────────
        _buildSectionHeader('Actions'),
        const SizedBox(height: 12),
        ListTile(
          leading: const Icon(Icons.delete_forever_rounded, color: AppTheme.error),
          title: Text('Clear Local Cache', style: GoogleFonts.manrope(color: AppTheme.error, fontWeight: FontWeight.w600)),
          subtitle: Text('Removes cached products, customers and brands.', style: GoogleFonts.manrope(fontSize: 11)),
          onTap: () async {
            // #SA10 (2026-04-18 overnight): added confirmation because this
            // action wipes 8 Hive boxes including `offline_orders`,
            // `offline_operations`, and `cart` — which hold queued-but-
            // unsynced orders and partial cart state. A single accidental
            // tap previously destroyed work irreversibly.

            // GUARD 1: refuse if currently offline. Previously the dialog
            // only WARNED about being online; user could see the warning,
            // tap Clear, and lose queued orders if their assumption was
            // wrong. Now the action is blocked outright when offline.
            final isOnline = await OfflineService.instance.isOnline();
            if (!mounted) return;
            if (!isOnline) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text(
                    'Cannot clear cache while offline. Queued orders may not have synced yet — come back when you have internet.',
                  ),
                  backgroundColor: Colors.red.shade700,
                  duration: const Duration(seconds: 5),
                ),
              );
              return;
            }

            // Count pending queue content so the dialog shows REAL risk
            // (e.g. "3 offline orders + 2 ops will be destroyed") instead
            // of generic text.
            int pendingOrders = 0;
            int pendingOps = 0;
            try {
              pendingOrders = Hive.isBoxOpen('offline_orders')
                  ? Hive.box('offline_orders').length
                  : (await Hive.openBox('offline_orders')).length;
              pendingOps = Hive.isBoxOpen('offline_operations')
                  ? Hive.box('offline_operations').length
                  : (await Hive.openBox('offline_operations')).length;
            } catch (_) {}
            final hasPending = (pendingOrders + pendingOps) > 0;
            if (!mounted) return;

            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                title: Text('Clear Local Cache?', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'This will permanently delete:',
                      style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '• Cached products, customers, brands\n'
                      '• Queued offline orders (not yet synced)\n'
                      '• Pending offline operations\n'
                      '• Unsubmitted cart contents\n'
                      '• Hero-image cache\n'
                      '• Drive-sync failure log',
                      style: GoogleFonts.manrope(fontSize: 12),
                    ),
                    const SizedBox(height: 10),
                    if (hasPending)
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: Colors.red.shade100, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red.shade700)),
                        child: Row(
                          children: [
                            Icon(Icons.error_rounded, color: Colors.red.shade900, size: 18),
                            const SizedBox(width: 8),
                            Expanded(child: Text(
                              'STOP: ${pendingOrders > 0 ? "$pendingOrders queued order${pendingOrders == 1 ? "" : "s"}" : ""}'
                              '${(pendingOrders > 0 && pendingOps > 0) ? " and " : ""}'
                              '${pendingOps > 0 ? "$pendingOps pending operation${pendingOps == 1 ? "" : "s"}" : ""}'
                              ' have NOT reached Supabase. Run sync first — these will be permanently lost if you clear now.',
                              style: GoogleFonts.manrope(fontSize: 11, color: Colors.red.shade900, fontWeight: FontWeight.w800),
                            )),
                          ],
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
                        child: Row(
                          children: [
                            Icon(Icons.warning_rounded, color: Colors.red.shade700, size: 16),
                            const SizedBox(width: 8),
                            Expanded(child: Text(
                              'Queue is currently empty. Still, you\'ll have to re-download products, customers and brands on next login.',
                              style: GoogleFonts.manrope(fontSize: 11, color: Colors.red.shade900, fontWeight: FontWeight.w600),
                            )),
                          ],
                        ),
                      ),
                  ],
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.manrope(fontWeight: FontWeight.w600))),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text('Clear Cache', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
            );
            if (confirmed != true || !mounted) return;

            // GUARD 2: re-check connectivity right before clearing in case
            // it dropped between confirm-tap and now (background sync might
            // have pushed the phone off Wi-Fi, etc).
            final stillOnline = await OfflineService.instance.isOnline();
            if (!mounted) return;
            if (!stillOnline) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Connection dropped — cache clear aborted to protect queued orders.'),
                  backgroundColor: Colors.red.shade700,
                ),
              );
              return;
            }
            try {
              // Clear ALL Hive boxes
              final boxNames = ['cache_JA', 'cache_MA', 'orders', 'offline_orders', 'offline_operations', 'cart', 'hero_cache', 'drive_sync_failures'];
              for (final boxName in boxNames) {
                try {
                  if (Hive.isBoxOpen(boxName)) {
                    await Hive.box(boxName).clear();
                  } else {
                    final box = await Hive.openBox(boxName);
                    await box.clear();
                  }
                } catch (_) {} // skip if box doesn't exist
              }
              // Also clear SharedPreferences cache keys
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('session_last_active_ms');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('All local data cleared. Restart app for fresh data.'), backgroundColor: Colors.green),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error clearing cache: $e'), backgroundColor: Colors.red),
                );
              }
            }
          },
        ),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.logout_rounded, color: AppTheme.primary),
          title: Text('Log Out', style: GoogleFonts.manrope(color: AppTheme.primary, fontWeight: FontWeight.w600)),
          subtitle: Text('Sign out of the current session.', style: GoogleFonts.manrope(fontSize: 11)),
          onTap: () async {
            await SupabaseService.instance.signOut();
            if (context.mounted) Navigator.pushReplacementNamed(context, AppRoutes.loginScreen);
          },
        ),
      ],
    );
  }

  Widget _buildDriveCard() {
    if (!_isGoogleSignedIn) {
      // ── Not connected state ──
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.cloud_off_rounded, color: Colors.orange.shade700, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text('Google Drive not connected', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 14, color: Colors.orange.shade700))),
            ]),
            const SizedBox(height: 8),
            Text(
              'Sign in with your Google account to sync bill photos from Supabase to your Drive. Photos are auto-synced every 24 hours and deleted from Supabase after upload.',
              style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _driveSyncing ? null : _handleGoogleSignIn,
                icon: _driveSyncing
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.login_rounded, size: 18),
                label: Text(
                  _driveSyncing ? 'Signing in...' : 'Sign in with Google',
                  style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // ── Connected state ──
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.cloud_done_rounded, color: Colors.green, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text('Google Drive connected', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 14, color: Colors.green.shade700))),
          ]),
          const SizedBox(height: 4),
          Text(
            'Signed in as $_googleEmail',
            style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            'Bill photos auto-sync to JA/MA folders every 24 hours. Supabase photos are deleted after upload to save storage.',
            style: GoogleFonts.manrope(fontSize: 11, color: AppTheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _driveSyncing ? null : _manualSync,
                icon: _driveSyncing
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync_rounded, size: 18),
                label: Text(_driveSyncing ? 'Syncing...' : 'Sync Photos', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: _handleGoogleSignOut,
              child: Text('Disconnect', style: GoogleFonts.manrope(fontWeight: FontWeight.w600, color: Colors.red.shade400, fontSize: 13)),
            ),
          ]),
          if (widget.isSuperAdmin) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _stockSyncing ? null : _syncFromDrive,
                icon: _stockSyncing
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.inventory_rounded, size: 18, color: Colors.green.shade700),
                label: Text(
                  _stockSyncing ? 'Syncing...' : 'Sync from Drive',
                  style: GoogleFonts.manrope(fontWeight: FontWeight.w600, color: Colors.green.shade700),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.green.shade300),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(height: 6),
            FutureBuilder<String?>(
              future: Hive.openBox('app_settings').then((b) => b.get('last_drive_sync') as String?),
              builder: (_, snap) {
                final ts = snap.data;
                if (ts == null) return Text('Never synced', style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant));
                final dt = DateTime.tryParse(ts);
                final label = dt != null ? DateFormat('dd MMM yyyy, hh:mm a').format(dt) : ts;
                return Text('Last synced: $label', style: GoogleFonts.manrope(fontSize: 10, color: Colors.green.shade700));
              },
            ),
            // 2026-04-21 — DUA export freshness. Red when > 24h stale so
            // super_admin knows the office PC export hasn't run today.
            FutureBuilder<String?>(
              future: Hive.openBox('app_settings').then((b) => b.get('last_dua_export') as String?),
              builder: (_, snap) {
                final ts = snap.data;
                if (ts == null || ts.isEmpty) {
                  return Text(
                    'DUA export: unknown',
                    style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant),
                  );
                }
                // sync_metadata.csv writes 'YYYY-MM-DD HH:MM:SS' in IST.
                DateTime? dt;
                try {
                  dt = DateTime.parse(ts.replaceFirst(' ', 'T'));
                } catch (_) {}
                final ageHours = dt != null
                    ? DateTime.now().difference(dt).inHours
                    : null;
                final stale = (ageHours ?? 0) > 24;
                final color = stale ? Colors.red.shade700 : Colors.green.shade700;
                final ageStr = ageHours == null
                    ? ''
                    : ageHours < 1
                        ? ' (<1h ago)'
                        : ' (${ageHours}h ago)';
                return Text(
                  'DUA export: $ts$ageStr',
                  style: GoogleFonts.manrope(
                    fontSize: 10,
                    color: color,
                    fontWeight: stale ? FontWeight.w700 : FontWeight.w400,
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            const _SyncSummaryPanel(),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(title.toUpperCase(), style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w800, color: AppTheme.onSurfaceVariant, letterSpacing: 1.2));
  }

  Widget _buildInfoTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant)),
          Text(value, style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// Collapsible panel under the "Sync from Drive" button that shows the
/// outcome of every step of the last sync run. Persisted in Hive under
/// `last_drive_sync_summary` so it survives tab switches and app restarts.
/// Read-only — the summary is written by `_syncFromDrive`.
class _SyncSummaryPanel extends StatefulWidget {
  const _SyncSummaryPanel();

  @override
  State<_SyncSummaryPanel> createState() => _SyncSummaryPanelState();
}

class _SyncSummaryPanelState extends State<_SyncSummaryPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Box>(
      future: Hive.openBox('app_settings'),
      builder: (_, snap) {
        final box = snap.data;
        // Waiting for Hive to open — show a tiny placeholder so the panel
        // slot is visible instead of silently empty.
        if (box == null) {
          return _placeholder('Loading sync details…');
        }

        final raw = box.get('last_drive_sync_summary');
        // No sync has been run yet (or last summary was cleared). Show an
        // explainer so the user knows the panel exists and will populate
        // after they tap Sync from Drive.
        if (raw is! List || raw.isEmpty) {
          return _placeholder('No sync details yet — press Sync from Drive to populate.');
        }

        // Hive may return List<dynamic> of Map<dynamic,dynamic> — coerce.
        final entries = raw
            .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{})
            .where((m) => m.isNotEmpty)
            .toList();
        if (entries.isEmpty) {
          return _placeholder('Sync summary empty — press Sync from Drive to populate.');
        }

        final okCount = entries.where((e) => e['status'] == 'ok').length;
        final errCount = entries.where((e) => e['status'] == 'error').length;
        final totalMs = box.get('last_drive_sync_total_ms') as int? ?? 0;
        final totalSec = (totalMs / 1000).toStringAsFixed(1);
        final headerColor = errCount == 0 ? Colors.green.shade700 : Colors.orange.shade800;

        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: headerColor.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(10),
            color: headerColor.withValues(alpha: 0.05),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        errCount == 0 ? Icons.check_circle_rounded : Icons.warning_rounded,
                        size: 16,
                        color: headerColor,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          errCount == 0
                              ? 'Sync Summary — all ${entries.length} steps OK · ${totalSec}s'
                              : 'Sync Summary — $okCount OK, $errCount failed · ${totalSec}s',
                          style: GoogleFonts.manrope(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: headerColor,
                          ),
                        ),
                      ),
                      Icon(
                        _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                        size: 18,
                        color: headerColor,
                      ),
                    ],
                  ),
                ),
              ),
              if (_expanded) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: entries.map((e) => _buildRow(e)).toList(),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildRow(Map<String, dynamic> entry) {
    final step = entry['step']?.toString() ?? '?';
    final status = entry['status']?.toString() ?? '?';
    final detail = entry['detail']?.toString() ?? '';
    final ms = entry['ms'] is int ? entry['ms'] as int : 0;
    final isOk = status == 'ok';
    final color = isOk ? Colors.green.shade700 : Colors.red.shade700;
    final icon = isOk ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step,
                  style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w700, color: color),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    style: GoogleFonts.manrope(
                      fontSize: 10,
                      color: AppTheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          Text(
            '${(ms / 1000).toStringAsFixed(1)}s',
            style: GoogleFonts.manrope(fontSize: 10, color: AppTheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// Shown when no sync summary exists yet (or Hive is still loading).
  /// Makes the panel slot visible so the user knows the feature exists
  /// instead of wondering where the "sync details" went.
  Widget _placeholder(String message) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
        color: Colors.grey.shade50,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 14, color: AppTheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.manrope(
                fontSize: 11,
                color: AppTheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

