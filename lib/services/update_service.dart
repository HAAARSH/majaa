import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_fonts/google_fonts.dart';

import 'supabase_service.dart';
import '../theme/app_theme.dart';

class UpdateService {
  static Future<void> checkForUpdates(BuildContext context) async {
    try {
      // 1. Get the current app version from the phone's pubspec.yaml
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      final String currentVersion = packageInfo.version;

      // 2. Get the latest version and Drive link from Supabase
      final response = await SupabaseService.instance.client
          .from('app_settings')
          .select()
          .eq('id', 1)
          .maybeSingle();

      if (response == null) {
        debugPrint('No app_settings record found, skipping update check');
        return;
      }

      final String latestVersion = response['latest_version'];
      final String apkUrl = response['apk_download_url'];
      final bool isMandatory = response['mandatory_update'] ?? true;

      // 3. Compare versions
      if (_isUpdateAvailable(currentVersion, latestVersion)) {
        if (context.mounted) {
          _showUpdateDialog(context, latestVersion, apkUrl, isMandatory);
        }
      }
    } catch (e) {
      debugPrint('Update check failed: $e');
      // Show user-friendly error message if context is available
      if (context.mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Update check failed: ${e.toString()}'),
                duration: const Duration(seconds: 3),
                backgroundColor: Colors.orange,
              ),
            );
          }
        });
      }
      // If they are deep in a warehouse without internet, let them in anyway
    }
  }

  // Improved version string comparison (e.g. "1.0.0" vs "1.0.1")
  // Handles build numbers like "1.0.0+2" gracefully
  static bool _isUpdateAvailable(String current, String latest) {
    try {
      // Extract version numbers before any build number suffix
      String currentVersion = current.split('+').first;
      String latestVersion = latest.split('+').first;
      
      List<int> currentParts = currentVersion.split('.').map((part) {
        try {
          return int.parse(part);
        } catch (e) {
          return 0; // Default to 0 if parsing fails
        }
      }).toList();
      
      List<int> latestParts = latestVersion.split('.').map((part) {
        try {
          return int.parse(part);
        } catch (e) {
          return 0; // Default to 0 if parsing fails
        }
      }).toList();

      // Ensure both lists have at least 3 elements for comparison
      while (currentParts.length < 3) currentParts.add(0);
      while (latestParts.length < 3) latestParts.add(0);

      for (int i = 0; i < 3; i++) {
        int c = i < currentParts.length ? currentParts[i] : 0;
        int l = i < latestParts.length ? latestParts[i] : 0;
        if (l > c) return true;
        if (l < c) return false;
      }
      return false;
    } catch (e) {
      debugPrint('Version comparison error: $e');
      return false; // Conservative approach: don't update if comparison fails
    }
  }

  static void _showUpdateDialog(BuildContext context, String newVersion, String url, bool isMandatory) {
    showDialog(
      context: context,
      barrierDismissible: !isMandatory,
      builder: (BuildContext context) {
        return PopScope(
          canPop: !isMandatory, // Disables the Android back button if mandatory
          child: AlertDialog(
            backgroundColor: AppTheme.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                const Icon(Icons.system_update_rounded, color: AppTheme.primary, size: 28),
                const SizedBox(width: 10),
                Text('Update Required', style: GoogleFonts.manrope(fontWeight: FontWeight.w800, color: AppTheme.onSurface)),
              ],
            ),
            content: Text(
              'A new version of the M.A.J.A.A. app (v$newVersion) is available.\n\nPlease update to continue taking orders and making deliveries.',
              style: GoogleFonts.manrope(fontSize: 14, color: AppTheme.onSurfaceVariant),
            ),
            actions: [
              if (!isMandatory)
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Later', style: GoogleFonts.manrope(color: AppTheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
                ),
              FilledButton.icon(
                icon: const Icon(Icons.download_rounded, size: 18, color: Colors.white),
                label: Text('Update Now', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, color: Colors.white)),
                style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                onPressed: () async {
                  final Uri launchUri = Uri.parse(url);
                  // LaunchMode.externalApplication forces the Android Browser to handle the Drive download
                  if (await canLaunchUrl(launchUri)) {
                    await launchUrl(launchUri, mode: LaunchMode.externalApplication);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }
}