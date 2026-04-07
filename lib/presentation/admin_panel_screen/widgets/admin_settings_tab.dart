import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../theme/app_theme.dart';
import '../../../services/auth_service.dart';
import '../../../services/supabase_service.dart';
import '../../../services/drive_sync_service.dart';
import '../../../services/google_drive_auth_service.dart';
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
    try {
      // Sync stock (ITMRP)
      final stockResult = await DriveSyncService.instance.syncStockFromDrive();
      // Sync bills (ITTR)
      final billResult = await DriveSyncService.instance.syncBillsFromDrive();
      if (!mounted) return;

      final msgs = <String>[];
      if (stockResult.hasError) {
        msgs.add('Stock: ${stockResult.error}');
      } else {
        msgs.add('Stock: ${stockResult.updated} updated');
      }
      if (billResult.hasError) {
        msgs.add('Bills: ${billResult.error}');
      } else {
        final parts = <String>['${billResult.totalBills} bills'];
        if (billResult.applied > 0) parts.add('${billResult.applied} verified');
        if (billResult.discrepancies > 0) parts.add('${billResult.discrepancies} to review');
        msgs.add('Bills: ${parts.join(', ')}');
      }

      final hasError = stockResult.hasError || billResult.hasError;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msgs.join(' | ')),
          backgroundColor: hasError ? Colors.orange : Colors.green,
          duration: const Duration(seconds: 5),
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
            _buildInfoTile('App Version', '1.0.0+1'),
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
          subtitle: Text('Removes cached products, customers and categories.', style: GoogleFonts.manrope(fontSize: 11)),
          onTap: () async {
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
