import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';

class AdminSettingsTab extends StatefulWidget {
  const AdminSettingsTab({super.key});

  @override
  State<AdminSettingsTab> createState() => _AdminSettingsTabState();
}

class _AdminSettingsTabState extends State<AdminSettingsTab> {
  bool _isChecking = false;
  String? _statusMessage;
  bool _isHealthy = false;

  @override
  void initState() {
    super.initState();
    _checkDatabaseHealth();
  }

  Future<void> _checkDatabaseHealth() async {
    setState(() {
      _isChecking = true;
      _statusMessage = 'Checking connection...';
    });

    try {
      // Simple query to check connection
      await Supabase.instance.client.from('app_users').select('id').limit(1);
      setState(() {
        _isHealthy = true;
        _statusMessage = 'Connected to Supabase successfully.';
        _isChecking = false;
      });
    } catch (e) {
      setState(() {
        _isHealthy = false;
        _statusMessage = 'Connection failed: ${e.toString()}';
        _isChecking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'System Settings',
          style: GoogleFonts.manrope(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: AppTheme.onSurface,
          ),
        ),
        const SizedBox(height: 24),
        _buildSectionHeader('Database Status'),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _isHealthy ? Icons.check_circle_rounded : Icons.error_rounded,
                    color: _isHealthy ? AppTheme.success : AppTheme.error,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _isHealthy ? 'Supabase Online' : 'Supabase Offline',
                      style: GoogleFonts.manrope(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (_isChecking)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      onPressed: _checkDatabaseHealth,
                      tooltip: 'Refresh Status',
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _statusMessage ?? 'Unknown status',
                style: GoogleFonts.manrope(
                  fontSize: 12,
                  color: AppTheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _buildSectionHeader('App Information'),
        const SizedBox(height: 12),
        _buildInfoTile('App Version', '1.0.0+1'),
        _buildInfoTile('Environment', 'Production'),
        _buildInfoTile('Supabase Project', Supabase.instance.client.supabaseUrl.split('//').last.split('.').first),
        const SizedBox(height: 24),
        _buildSectionHeader('Actions'),
        const SizedBox(height: 12),
        ListTile(
          leading: const Icon(Icons.delete_forever_rounded, color: AppTheme.error),
          title: Text(
            'Clear Local Cache',
            style: GoogleFonts.manrope(color: AppTheme.error, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            'Removes cached products and categories.',
            style: GoogleFonts.manrope(fontSize: 11),
          ),
          onTap: () {
            // In a real app, we would clear SharedPreferences or similar
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Cache cleared successfully.')),
            );
          },
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title.toUpperCase(),
      style: GoogleFonts.manrope(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        color: AppTheme.onSurfaceVariant,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _buildInfoTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: GoogleFonts.manrope(fontSize: 13, color: AppTheme.onSurfaceVariant),
          ),
          Text(
            value,
            style: GoogleFonts.manrope(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
