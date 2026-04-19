import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:google_fonts/google_fonts.dart';

import 'supabase_service.dart';
import '../theme/app_theme.dart';

class UpdateService {
  static const _channel = MethodChannel('com.example.fmcgorders/apk_install');

  static Future<void> checkForUpdates(BuildContext context) async {
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      final String currentVersion = packageInfo.version;

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
      final String apkUrl = response['apk_download_url'] ?? '';
      final bool isMandatory = response['mandatory_update'] ?? true;

      if (_isUpdateAvailable(currentVersion, latestVersion)) {
        if (context.mounted) {
          _showUpdateDialog(context, latestVersion, apkUrl, isMandatory);
        }
      }
    } catch (e) {
      debugPrint('Update check failed: $e');
    }
  }

  static bool _isUpdateAvailable(String current, String latest) {
    try {
      final currentParts = current.split('+').first.split('.').map((p) => int.tryParse(p) ?? 0).toList();
      final latestParts = latest.split('+').first.split('.').map((p) => int.tryParse(p) ?? 0).toList();
      while (currentParts.length < 3) {
        currentParts.add(0);
      }
      while (latestParts.length < 3) {
        latestParts.add(0);
      }

      for (int i = 0; i < 3; i++) {
        if (latestParts[i] > currentParts[i]) return true;
        if (latestParts[i] < currentParts[i]) return false;
      }
      return false;
    } catch (e) {
      debugPrint('Version comparison error: $e');
      return false;
    }
  }

  static void _showUpdateDialog(BuildContext context, String newVersion, String url, bool isMandatory) {
    showDialog(
      context: context,
      barrierDismissible: !isMandatory,
      builder: (ctx) => PopScope(
        canPop: !isMandatory,
        child: _UpdateDialog(
          newVersion: newVersion,
          apkUrl: url,
          isMandatory: isMandatory,
        ),
      ),
    );
  }

  /// Download APK to internal ota_update/ directory and trigger install.
  static Future<void> downloadAndInstall(
    String url, {
    required ValueChanged<double> onProgress,
    required VoidCallback onInstalling,
    required ValueChanged<String> onError,
  }) async {
    try {
      // Check install permission first (Android 8+)
      final canInstall = await _channel.invokeMethod<bool>('canRequestInstall') ?? false;
      if (!canInstall) {
        await _channel.invokeMethod('requestInstallPermission');
        // Re-check after user returns from settings
        final granted = await _channel.invokeMethod<bool>('canRequestInstall') ?? false;
        if (!granted) {
          onError('Install permission not granted. Please allow "Install unknown apps" in settings.');
          return;
        }
      }

      // Resolve Google Drive direct download URL
      final resolvedUrl = _resolveDirectUrl(url);

      // Use a client that follows redirects and handles Drive confirmation
      final client = http.Client();
      try {
        var downloadUrl = resolvedUrl;

        // First request — may return HTML confirmation page for large files
        var response = await client.get(Uri.parse(downloadUrl));

        // Google Drive large-file / executable interstitial: returns HTML.
        // The current Drive UI uses a form with hidden fields that POSTs to
        // drive.usercontent.google.com/download. We emulate that by rebuilding
        // the URL using the form's action + its hidden inputs. Falls back to
        // the known usercontent endpoint if action parsing fails.
        if (response.statusCode == 200 &&
            response.headers['content-type']?.contains('text/html') == true) {
          final body = response.body;
          // Extract all hidden-input name/value pairs from the form.
          final params = <String, String>{};
          for (final m in RegExp(
            r'name="([^"]+)"\s+value="([^"]*)"',
          ).allMatches(body)) {
            params[m.group(1)!] = m.group(2)!;
          }
          final actionMatch = RegExp(r'action="([^"]+)"').firstMatch(body);
          final action = actionMatch?.group(1) ??
              'https://drive.usercontent.google.com/download';
          if (params.containsKey('id') && params.containsKey('confirm')) {
            final query = params.entries
                .map((e) =>
                    '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
                .join('&');
            downloadUrl = '$action?$query';
          }
        }

        // Now do the real streamed download
        final request = http.Request('GET', Uri.parse(downloadUrl));
        final streamedResponse = await client.send(request);

        if (streamedResponse.statusCode != 200) {
          onError('Download failed: HTTP ${streamedResponse.statusCode}');
          return;
        }

        // Verify content type is not HTML (fallback safety check)
        final ct = streamedResponse.headers['content-type'] ?? '';
        if (ct.contains('text/html')) {
          onError('Download failed: Google Drive returned a web page instead of the APK. Check the share link.');
          return;
        }

        final contentLength = streamedResponse.contentLength ?? 0;
        final dir = await getTemporaryDirectory();
        final otaDir = Directory('${dir.path}/ota_update');
        if (!otaDir.existsSync()) otaDir.createSync(recursive: true);
        final file = File('${otaDir.path}/update.apk');

        final sink = file.openWrite();
        int received = 0;

        await for (final chunk in streamedResponse.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (contentLength > 0) {
            onProgress(received / contentLength);
          }
        }
        await sink.close();

        // Sanity check: APK should be at least 1MB
        final fileSize = await file.length();
        if (fileSize < 1024 * 1024) {
          onError('Download failed: File too small (${(fileSize / 1024).toStringAsFixed(0)} KB). The download link may be invalid.');
          return;
        }

        onInstalling();

        // Trigger Android install intent via method channel
        await _channel.invokeMethod('installApk', {'filePath': file.path});
      } finally {
        client.close();
      }
    } catch (e) {
      onError('Download failed: $e');
    }
  }

  /// Convert Google Drive share/view URL to direct download URL.
  static String _resolveDirectUrl(String url) {
    // Handle: https://drive.google.com/file/d/FILE_ID/view...
    final match = RegExp(r'drive\.google\.com/file/d/([^/]+)').firstMatch(url);
    if (match != null) {
      return 'https://drive.google.com/uc?export=download&id=${match.group(1)}';
    }
    // Handle: https://drive.google.com/open?id=FILE_ID
    final openMatch = RegExp(r'drive\.google\.com/open\?id=([^&]+)').firstMatch(url);
    if (openMatch != null) {
      return 'https://drive.google.com/uc?export=download&id=${openMatch.group(1)}';
    }
    // Already direct or non-Drive URL
    return url;
  }
}

/// Stateful dialog that handles download progress and install.
class _UpdateDialog extends StatefulWidget {
  final String newVersion;
  final String apkUrl;
  final bool isMandatory;

  const _UpdateDialog({
    required this.newVersion,
    required this.apkUrl,
    required this.isMandatory,
  });

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

enum _UpdateState { prompt, downloading, installing, error }

class _UpdateDialogState extends State<_UpdateDialog> {
  _UpdateState _state = _UpdateState.prompt;
  double _progress = 0;
  String _errorMsg = '';

  void _startDownload() {
    setState(() => _state = _UpdateState.downloading);

    UpdateService.downloadAndInstall(
      widget.apkUrl,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
      onInstalling: () {
        if (mounted) setState(() => _state = _UpdateState.installing);
      },
      onError: (msg) {
        if (mounted) setState(() { _state = _UpdateState.error; _errorMsg = msg; });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Icon(
            _state == _UpdateState.error ? Icons.error_outline_rounded : Icons.system_update_rounded,
            color: _state == _UpdateState.error ? Colors.red : AppTheme.primary,
            size: 28,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _titleText,
              style: GoogleFonts.manrope(fontWeight: FontWeight.w800, color: AppTheme.onSurface, fontSize: 18),
            ),
          ),
        ],
      ),
      content: _buildContent(),
      actions: _buildActions(),
    );
  }

  String get _titleText {
    switch (_state) {
      case _UpdateState.prompt: return 'Update Available';
      case _UpdateState.downloading: return 'Downloading...';
      case _UpdateState.installing: return 'Installing...';
      case _UpdateState.error: return 'Update Failed';
    }
  }

  Widget _buildContent() {
    switch (_state) {
      case _UpdateState.prompt:
        return Text(
          'A new version (v${widget.newVersion}) is available.\n\nPlease update to continue.',
          style: GoogleFonts.manrope(fontSize: 14, color: AppTheme.onSurfaceVariant),
        );

      case _UpdateState.downloading:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 8,
                backgroundColor: AppTheme.primary.withValues(alpha: 0.15),
                valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primary),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _progress > 0 ? '${(_progress * 100).toStringAsFixed(0)}%' : 'Starting download...',
              style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.onSurfaceVariant),
            ),
          ],
        );

      case _UpdateState.installing:
        return Row(
          children: [
            const SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary),
            ),
            const SizedBox(width: 12),
            Text(
              'Opening installer...',
              style: GoogleFonts.manrope(fontSize: 14, color: AppTheme.onSurfaceVariant),
            ),
          ],
        );

      case _UpdateState.error:
        return Text(
          _errorMsg,
          style: GoogleFonts.manrope(fontSize: 13, color: Colors.red.shade700),
        );
    }
  }

  List<Widget> _buildActions() {
    switch (_state) {
      case _UpdateState.prompt:
        return [
          if (!widget.isMandatory)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Later', style: GoogleFonts.manrope(color: AppTheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
            ),
          FilledButton.icon(
            icon: const Icon(Icons.download_rounded, size: 18, color: Colors.white),
            label: Text('Update Now', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, color: Colors.white)),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: _startDownload,
          ),
        ];

      case _UpdateState.downloading:
        return []; // No actions during download

      case _UpdateState.installing:
        return [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close', style: GoogleFonts.manrope(color: AppTheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
          ),
        ];

      case _UpdateState.error:
        return [
          if (!widget.isMandatory)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: GoogleFonts.manrope(color: AppTheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
            ),
          FilledButton.icon(
            icon: const Icon(Icons.refresh_rounded, size: 18, color: Colors.white),
            label: Text('Retry', style: GoogleFonts.manrope(fontWeight: FontWeight.w700, color: Colors.white)),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: _startDownload,
          ),
        ];
    }
  }
}
