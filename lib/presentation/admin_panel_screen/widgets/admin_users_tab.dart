import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../services/supabase_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import '../../../services/auth_service.dart';
import '../../../services/hero_cache_service.dart';
import '../../../theme/app_theme.dart';
import './admin_shared_widgets.dart';

class AdminUsersTab extends StatefulWidget {
  const AdminUsersTab({super.key});

  @override
  State<AdminUsersTab> createState() => _AdminUsersTabState();
}

class _AdminUsersTabState extends State<AdminUsersTab> {
  bool _isLoading = true;
  List<AppUserModel> _users = [];
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

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final users = await SupabaseService.instance.getAppUsers(forceRefresh: forceRefresh, allTeams: true);
      users.sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
      if (!mounted) return;
      setState(() { _users = users; _filtered = users; _isLoading = false; });
      _applySearch();
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  void _applySearch() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filtered = _users.where((u) =>
        u.fullName.toLowerCase().contains(q) ||
        u.email.toLowerCase().contains(q) ||
        u.teamId.toLowerCase().contains(q),
      ).toList();
    });
  }

  Color _roleColor(String role) {
    switch (role) {
      case 'super_admin': return Colors.purple;
      case 'admin': return Colors.blue;
      case 'delivery_rep': return Colors.orange;
      default: return Colors.green;
    }
  }

  void _showSetPasswordDialog(AppUserModel user) {
    final passCtrl = TextEditingController();
    bool obscure = true;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Set Password', style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(user.fullName, style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              TextField(
                controller: passCtrl,
                obscureText: obscure,
                decoration: InputDecoration(
                  labelText: 'New Password (min 6 chars)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  suffixIcon: IconButton(
                    icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setD(() => obscure = !obscure),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final pass = passCtrl.text.trim();
                if (pass.length < 6) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Password must be at least 6 characters')));
                  return;
                }
                Navigator.pop(ctx);
                try {
                  await SupabaseService.instance.adminSetPassword(user.id, pass);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Password updated for ${user.fullName}'), backgroundColor: Colors.green),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
                    );
                  }
                }
              },
              child: const Text('Update'),
            ),
          ],
        ),
      ),
    ).then((_) => passCtrl.dispose());
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'super_admin': return 'Super Admin';
      case 'admin': return 'Admin';
      case 'delivery_rep': return 'Delivery Rep';
      case 'brand_rep': return 'Brand Rep';
      default: return 'Sales Rep';
    }
  }

  void _showUserDialog(AppUserModel? user) async {
    final currentRole = await SupabaseService.instance.getUserRole();
    // Admin cannot manage other admins/super admins
    if (user != null && currentRole == 'admin' && (user.role == 'admin' || user.role == 'super_admin')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You cannot edit admin-level users')),
      );
      return;
    }

    final nameCtrl = TextEditingController(text: user?.fullName ?? '');
    final emailCtrl = TextEditingController(text: user?.email ?? '');
    final passCtrl = TextEditingController();
    final upiCtrl = TextEditingController(text: user?.upiId ?? '');
    String selectedRole = user?.role ?? 'sales_rep';
    String selectedTeam = user?.teamId ?? AuthService.currentTeam;
    bool isActive = user?.isActive ?? true;
    bool obscurePass = true;

    final isNew = user == null;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(isNew ? 'Add New User' : 'Edit User', style: GoogleFonts.manrope(fontWeight: FontWeight.w800)),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                buildAdminTextField('Full Name', nameCtrl),
                const SizedBox(height: 10),
                buildAdminTextField('Email', emailCtrl, keyboardType: TextInputType.emailAddress),
                const SizedBox(height: 10),
                TextField(
                  controller: passCtrl,
                  obscureText: obscurePass,
                  decoration: InputDecoration(
                    labelText: isNew ? 'Password (min 6 chars)' : 'New Password (leave empty to keep)',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    suffixIcon: IconButton(
                      icon: Icon(obscurePass ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setD(() => obscurePass = !obscurePass),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                buildAdminTextField('UPI ID (optional)', upiCtrl),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: selectedRole,
                  decoration: InputDecoration(labelText: 'Role', border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
                  items: const [
                    DropdownMenuItem(value: 'sales_rep', child: Text('Sales Rep')),
                    DropdownMenuItem(value: 'brand_rep', child: Text('Brand Rep')),
                    DropdownMenuItem(value: 'delivery_rep', child: Text('Delivery Rep')),
                    DropdownMenuItem(value: 'admin', child: Text('Admin')),
                    DropdownMenuItem(value: 'super_admin', child: Text('Super Admin')),
                  ],
                  onChanged: (v) => setD(() => selectedRole = v!),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: selectedTeam,
                  decoration: InputDecoration(labelText: 'Team', border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
                  items: const [
                    DropdownMenuItem(value: 'JA', child: Text('Jagannath (JA)')),
                    DropdownMenuItem(value: 'MA', child: Text('Madhav (MA)')),
                  ],
                  onChanged: (v) => setD(() => selectedTeam = v!),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  title: Text('Active', style: GoogleFonts.manrope(fontWeight: FontWeight.w600)),
                  value: isActive,
                  onChanged: (v) => setD(() => isActive = v),
                  activeColor: AppTheme.primary,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final email = emailCtrl.text.trim();
                final pass = passCtrl.text.trim();
                if (name.isEmpty || email.isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Name and email required')));
                  return;
                }
                if (isNew && pass.length < 6) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Password must be at least 6 characters')));
                  return;
                }
                Navigator.pop(ctx);
                try {
                  if (isNew) {
                    await SupabaseService.instance.adminCreateUser(
                      email: email, password: pass, fullName: name,
                      role: selectedRole, teamId: selectedTeam, upiId: upiCtrl.text.trim(),
                    );
                    if (mounted) _load(forceRefresh: true);
                  } else {
                    await SupabaseService.instance.updateAppUser(
                      id: user.id, email: email, fullName: name,
                      role: selectedRole, isActive: isActive,
                    );
                    await SupabaseService.instance.client.from('app_users').update({
                      'team_id': selectedTeam, 'upi_id': upiCtrl.text.trim(),
                    }).eq('id', user.id);
                    // Update auth email if changed
                    if (email.toLowerCase() != user.email.toLowerCase()) {
                      await SupabaseService.instance.adminSetEmail(user.id, email);
                    }
                    // Set new password if provided
                    if (pass.isNotEmpty) {
                      if (pass.length < 6) {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password must be at least 6 characters'), backgroundColor: Colors.red));
                      } else {
                        await SupabaseService.instance.adminSetPassword(user.id, pass);
                      }
                    }
                    // Refresh only the edited user in-place
                    if (mounted) {
                      final resp = await SupabaseService.instance.client
                          .from('app_users').select().eq('id', user.id).single();
                      final updated = AppUserModel.fromJson(Map<String, dynamic>.from(resp));
                      setState(() {
                        final idx = _users.indexWhere((u) => u.id == user.id);
                        if (idx != -1) _users[idx] = updated;
                        final fIdx = _filtered.indexWhere((u) => u.id == user.id);
                        if (fIdx != -1) _filtered[fIdx] = updated;
                      });
                    }
                  }
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(isNew ? 'User created successfully' : 'User updated'), backgroundColor: Colors.green),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
                    );
                  }
                }
              },
              child: Text(isNew ? 'Create User' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeAvatar(AppUserModel user) async {
    final picker = ImagePicker();
    final photo = await picker.pickImage(
      source: ImageSource.camera, // On web: shows "Take Photo" or "Photo Library" menu on iOS
      imageQuality: 85,
      maxWidth: 800,
      maxHeight: 800,
      preferredCameraDevice: CameraDevice.front,
    );
    if (photo == null) return;

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Uploading avatar...'), duration: Duration(seconds: 2)),
    );

    try {
      final bytes = await photo.readAsBytes();
      final url = await SupabaseService.instance.uploadHeroAvatarToStorage(user.id, bytes.toList());
      if (url != null) {
        // Clear old cache
        if (user.heroImageUrl != null) {
          await HeroCacheService.instance.clearCacheForUrl(user.heroImageUrl!);
        }
        // Cache new image
        await HeroCacheService.instance.cacheImage(url, bytes);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Avatar updated'), backgroundColor: Colors.green),
          );
          _load(forceRefresh: true);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Upload failed'), backgroundColor: Colors.red),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _confirmDelete(AppUserModel user) async {
    final currentRole = await SupabaseService.instance.getUserRole();
    if (currentRole == 'admin' && (user.role == 'admin' || user.role == 'super_admin')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot delete admin-level users')));
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete User?', style: TextStyle(fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${user.fullName} (${user.email})'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  Icon(Icons.warning_rounded, color: Colors.red.shade700, size: 16),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('This will delete the user\'s login and all data. This cannot be undone.', style: TextStyle(fontSize: 12))),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    try {
      await SupabaseService.instance.adminDeleteUser(user.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User deleted'), backgroundColor: Colors.green));
        _load(forceRefresh: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return AdminErrorRetry(message: _error!, onRetry: _load);

    return Scaffold(
      backgroundColor: AppTheme.background,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_rounded),
        label: Text('Add User', style: GoogleFonts.manrope(fontSize: 13)),
        onPressed: () => _showUserDialog(null),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search by name, email or team...',
                prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.primary, size: 20),
                filled: true,
                fillColor: AppTheme.primary.withValues(alpha: 0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Text('${_filtered.length} users', style: GoogleFonts.manrope(fontSize: 12, color: Colors.grey.shade500)),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _filtered.isEmpty
                  ? Center(child: Text('No users found', style: GoogleFonts.manrope(color: Colors.grey)))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                      itemCount: _filtered.length,
                      itemBuilder: (context, index) {
                        final u = _filtered[index];
                        final roleColor = _roleColor(u.role);
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: BoxDecoration(
                            color: AppTheme.surface,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: u.isActive ? AppTheme.outlineVariant : Colors.red.shade200),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            leading: CircleAvatar(
                              backgroundColor: roleColor.withValues(alpha: 0.12),
                              child: Text(
                                u.fullName.isNotEmpty ? u.fullName[0].toUpperCase() : '?',
                                style: TextStyle(color: roleColor, fontWeight: FontWeight.w800),
                              ),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    u.fullName,
                                    style: GoogleFonts.manrope(fontWeight: FontWeight.w700, fontSize: 14),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (!u.isActive) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(6)),
                                    child: Text('INACTIVE', style: GoogleFonts.manrope(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.red)),
                                  ),
                                ],
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  u.email,
                                  style: GoogleFonts.manrope(fontSize: 12, color: AppTheme.onSurfaceVariant),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(color: roleColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
                                      child: Text(_roleLabel(u.role), style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: roleColor)),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(color: AppTheme.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6)),
                                      child: Text(u.teamId, style: GoogleFonts.manrope(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                                    ),
                                    if (u.upiId.isNotEmpty)
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(maxWidth: 180),
                                        child: Text(
                                          'UPI: ${u.upiId}',
                                          style: GoogleFonts.manrope(fontSize: 10, color: Colors.grey),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                            trailing: PopupMenuButton<String>(
                              onSelected: (v) {
                                if (v == 'edit') _showUserDialog(u);
                                if (v == 'avatar') _changeAvatar(u);
                                if (v == 'delete') _confirmDelete(u);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'edit', child: Row(children: [Icon(Icons.edit_rounded, size: 16), SizedBox(width: 8), Text('Edit')])),
                                PopupMenuItem(value: 'avatar', child: Row(children: [Icon(Icons.camera_alt_rounded, size: 16, color: Colors.orange), SizedBox(width: 8), Text('Change Avatar')])),
                                PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_rounded, size: 16, color: Colors.red), SizedBox(width: 8), Text('Delete', style: TextStyle(color: Colors.red))])),
                              ],
                            ),
                            onTap: () => _showUserDialog(u),
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
}
