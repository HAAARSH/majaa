import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';
import './admin_shared_widgets.dart';

class AdminUserBeatsTab extends StatefulWidget {
  const AdminUserBeatsTab({super.key});

  @override
  State<AdminUserBeatsTab> createState() => _AdminUserBeatsTabState();
}

class _AdminUserBeatsTabState extends State<AdminUserBeatsTab> {
  bool _isLoading = true;
  List<AppUserModel> _users = [];
  List<BeatModel> _allBeats = [];
  Map<String, List<String>> _userBeatIds = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final users = await SupabaseService.instance.getAppUsers();
      final beats = await SupabaseService.instance.getBeats();
      final Map<String, List<String>> userBeatIds = {};
      for (final user in users) {
        final userBeats = await SupabaseService.instance.getUserBeats(user.id);
        userBeatIds[user.id] = userBeats.map((b) => b.id).toList();
      }
      if (!mounted) return;
      setState(() {
        _users = users;
        _allBeats = beats;
        _userBeatIds = userBeatIds;
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

  // THIS IS THE NEW FULL-FEATURED EDIT DIALOG
  void _showEditUserDialog(AppUserModel user) {
    final nameCtrl = TextEditingController(text: user.fullName);
    final emailCtrl = TextEditingController(text: user.email);
    final passCtrl = TextEditingController(); // Empty for security
    String selectedRole = user.role.isEmpty ? 'sales_rep' : user.role;

    final currentBeatIds = List<String>.from(_userBeatIds[user.id] ?? []);
    final selectedBeats = <String>{...currentBeatIds};

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            'Edit User & Beats',
            style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Account Details',
                    style: GoogleFonts.manrope(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: 'Full Name',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: emailCtrl,
                    decoration: InputDecoration(
                      labelText: 'Email Address',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'New Password',
                      hintText: 'Leave blank to keep current',
                      hintStyle: GoogleFonts.manrope(fontSize: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: selectedRole,
                    decoration: InputDecoration(
                      labelText: 'Role',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'sales_rep',
                        child: Text('Sales Rep', style: GoogleFonts.manrope()),
                      ),
                      DropdownMenuItem(
                        value: 'admin',
                        child: Text('Admin', style: GoogleFonts.manrope()),
                      ),
                    ],
                    onChanged: (v) =>
                        setDialogState(() => selectedRole = v ?? 'sales_rep'),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Assigned Beats',
                    style: GoogleFonts.manrope(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_allBeats.isEmpty)
                    Text(
                      'No beats available in the system.',
                      style: GoogleFonts.manrope(
                        fontSize: 12,
                        color: AppTheme.onSurfaceVariant,
                      ),
                    ),
                  ..._allBeats.map((beat) {
                    final isSelected = selectedBeats.contains(beat.id);
                    return CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: isSelected,
                      activeColor: AppTheme.primary,
                      title: Text(
                        beat.beatName,
                        style: GoogleFonts.manrope(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        beat.beatCode,
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          color: AppTheme.onSurfaceVariant,
                        ),
                      ),
                      onChanged: (val) {
                        setDialogState(() {
                          if (val == true) {
                            selectedBeats.add(beat.id);
                          } else {
                            selectedBeats.remove(beat.id);
                          }
                        });
                      },
                    );
                  }),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: GoogleFonts.manrope()),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () async {
                Navigator.pop(ctx); // close dialog
                try {
                  // 1. Update the User Account Data First
                  await SupabaseService.instance.updateAppUser(
                    id: user.id,
                    email: emailCtrl.text,
                    password: passCtrl.text,
                    fullName: nameCtrl.text,
                    role: selectedRole,
                  );

                  // 2. Update their Assigned Beats
                  await SupabaseService.instance.setUserBeats(
                    userId: user.id,
                    beatIds: selectedBeats.toList(),
                  );

                  // 3. Reload screen to show fresh data
                  _load();

                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'User updated successfully!',
                          style: GoogleFonts.manrope(),
                        ),
                        backgroundColor: AppTheme.success,
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Error updating user: $e',
                          style: GoogleFonts.manrope(),
                        ),
                        backgroundColor: AppTheme.error,
                      ),
                    );
                  }
                }
              },
              child: Text(
                'Save Changes',
                style: GoogleFonts.manrope(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return AdminErrorRetry(message: _error!, onRetry: _load);
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.primary,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: _users.length,
        itemBuilder: (context, index) {
          final user = _users[index];
          final beatIds = _userBeatIds[user.id] ?? [];
          final assignedBeats = _allBeats
              .where((b) => beatIds.contains(b.id))
              .map((b) => b.beatName)
              .toList();
          return AdminCard(
            title: user.fullName.isNotEmpty ? user.fullName : user.email,
            subtitle: user.email,
            trailing: '${beatIds.length} beat${beatIds.length == 1 ? '' : 's'}',
            badge: user.role,
            badgeColor:
                user.role == 'admin' ? AppTheme.primary : AppTheme.secondary,
            extraInfo: assignedBeats.isEmpty
                ? 'No beats assigned'
                : assignedBeats.join(', '),
            onEdit: () => _showEditUserDialog(user), // Hooked up new dialog
            editLabel: 'Edit', // Changed label from 'Assign' to 'Edit'
          );
        },
      ),
    );
  }
}
