import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

import './supabase_service.dart';

// Adjust this import path if needed

class UpdateService {
  static Future<void> checkForUpdates(BuildContext context) async {
    try {
      // 1. Get the current app version's build number from the device (e.g., the "+1" in 1.0.0+1)
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      int currentVersionCode = int.tryParse(packageInfo.buildNumber) ?? 0;

      // 2. Fetch the latest release info from Supabase
      final latestRelease = await SupabaseService.instance.client
          .from('app_versions')
          .select()
          .order('version_code', ascending: false)
          .limit(1)
          .maybeSingle();

      // If there are no versions in the table yet, do nothing
      if (latestRelease == null) return;

      int latestVersionCode = latestRelease['version_code'] as int;
      String downloadUrl = latestRelease['download_url'] as String;
      bool isMandatory = latestRelease['is_mandatory'] as bool? ?? false;
      String releaseNotes = latestRelease['release_notes'] as String? ??
          'A new version is available.';

      // 3. Compare versions and show the update dialog if needed
      if (latestVersionCode > currentVersionCode) {
        if (!context.mounted) return;
        _showUpdateDialog(context, downloadUrl, isMandatory, releaseNotes);
      }
    } catch (e) {
      debugPrint('Update check failed: $e');
    }
  }

  static void _showUpdateDialog(BuildContext context, String downloadUrl,
      bool isMandatory, String releaseNotes) {
    showDialog(
      context: context,
      barrierDismissible:
          !isMandatory, // Prevents tapping outside to close if mandatory
      builder: (ctx) => _UpdateDialogContent(
        downloadUrl: downloadUrl,
        isMandatory: isMandatory,
        releaseNotes: releaseNotes,
      ),
    );
  }
}

// ─── Dialog UI with Download Progress ───

class _UpdateDialogContent extends StatefulWidget {
  final String downloadUrl;
  final bool isMandatory;
  final String releaseNotes;

  const _UpdateDialogContent({
    required this.downloadUrl,
    required this.isMandatory,
    required this.releaseNotes,
  });

  @override
  State<_UpdateDialogContent> createState() => _UpdateDialogContentState();
}

class _UpdateDialogContentState extends State<_UpdateDialogContent> {
  bool _isDownloading = false;
  String _progress = '0';
  String _statusMessage = '';

  void _startDownload() {
    setState(() {
      _isDownloading = true;
      _statusMessage = 'Starting download...';
    });

    try {
      OtaUpdate()
          .execute(
        widget.downloadUrl,
        destinationFilename: 'app_update.apk',
      )
          .listen(
        (OtaEvent event) {
          if (!mounted) return;

          setState(() {
            _progress = event.value ?? '0';

            switch (event.status) {
              case OtaStatus.DOWNLOADING:
                _statusMessage = 'Downloading: $_progress%';
                break;
              case OtaStatus.INSTALLING:
                _statusMessage = 'Installing update...';
                break;
              case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
                _statusMessage = 'Storage permission denied.';
                _isDownloading = false;
                break;
              case OtaStatus.INTERNAL_ERROR:
              case OtaStatus.DOWNLOAD_ERROR:
                _statusMessage = 'Download failed. Please try again.';
                _isDownloading = false;
                break;
              default:
                break;
            }
          });

          // Let the Android installer take over
          if (event.status == OtaStatus.INSTALLING) {
            if (!widget.isMandatory && mounted) {
              Navigator.of(context).pop();
            }
          }
        },
        onError: (error) {
          if (mounted) {
            setState(() {
              _isDownloading = false;
              _statusMessage = 'An error occurred during the update.';
            });
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _statusMessage = 'Failed to start the update process.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Update Available',
          style: GoogleFonts.manrope(fontWeight: FontWeight.w700)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.releaseNotes, style: GoogleFonts.manrope(fontSize: 14)),
          const SizedBox(height: 20),
          if (_isDownloading) ...[
            LinearProgressIndicator(
              value: double.tryParse(_progress) != null
                  ? double.parse(_progress) / 100
                  : null,
            ),
            const SizedBox(height: 8),
          ],
          if (_statusMessage.isNotEmpty)
            Text(_statusMessage,
                style: GoogleFonts.manrope(
                    fontSize: 12, fontWeight: FontWeight.bold)),
        ],
      ),
      actions: [
        if (!widget.isMandatory && !_isDownloading)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
        if (!_isDownloading)
          ElevatedButton(
            onPressed: _startDownload,
            child: const Text('Update Now'),
          ),
      ],
    );
  }
}
