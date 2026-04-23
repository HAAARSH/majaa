import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// A payload delivered by Android's system share sheet while the app is
/// the selected target. Either [text] (WhatsApp message / note) is set,
/// OR [imageBytes] + [imageMime] (photo / screenshot / PDF share).
class PendingShare {
  final String? text;
  final Uint8List? fileBytes;
  final String? fileMime;      // 'image/jpeg' | 'image/png' | 'application/pdf'
  final String? fileName;

  const PendingShare({
    this.text,
    this.fileBytes,
    this.fileMime,
    this.fileName,
  });

  bool get hasPayload =>
      (text != null && text!.trim().isNotEmpty) || fileBytes != null;
}

/// Bridges Android's share-intent flow into the Smart Import UI.
///
/// main.dart calls [init] once on Android. A pending share is published
/// on [pendingShare] — the admin panel + Smart Import tab listen. When
/// the share is consumed (admin applied or declined), callers should
/// invoke [consume] so the notifier resets and subsequent shares fire
/// fresh listeners.
///
/// iOS share-intent UX is handled differently (requires Share Extension
/// target in Xcode); out of scope for v1.
class SmartImportShareService {
  static final ValueNotifier<PendingShare?> pendingShare =
      ValueNotifier<PendingShare?>(null);

  static bool _initialized = false;
  static StreamSubscription<List<SharedMediaFile>>? _sub;

  /// Start listening. Safe to call multiple times — subsequent calls no-op.
  /// Does nothing on web / iOS / desktop — Android-only for now.
  static Future<void> init() async {
    if (_initialized) return;
    if (kIsWeb) return;
    if (!Platform.isAndroid) return;
    _initialized = true;

    try {
      // Cold-start: app was launched BY the share intent.
      final initial =
          await ReceiveSharingIntent.instance.getInitialMedia();
      if (initial.isNotEmpty) {
        await _handle(initial);
      }
    } catch (e) {
      debugPrint('[ShareIntent] getInitialMedia failed: $e');
    }

    // Hot: share while the app is already running.
    _sub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_handle, onError: (e) {
      debugPrint('[ShareIntent] stream error: $e');
    });
  }

  /// Stops the listener. Tests + teardown.
  static Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _initialized = false;
  }

  /// Admin panel / Smart Import tab calls this once the pending share has
  /// been loaded into the UI, so subsequent listeners fire fresh.
  static void consume() {
    pendingShare.value = null;
    ReceiveSharingIntent.instance.reset();
  }

  static Future<void> _handle(List<SharedMediaFile> files) async {
    if (files.isEmpty) return;
    // Multi-select shares: take only the first. Per NEW_ORDER_TAB_PLAN.md
    // Phase 5, multi-file support is not in scope for v1.
    final first = files.first;

    try {
      if (first.type == SharedMediaType.text ||
          first.type == SharedMediaType.url) {
        // For text/url shares, .path is the shared string itself.
        pendingShare.value = PendingShare(text: first.path);
        return;
      }

      if (first.type == SharedMediaType.image ||
          first.type == SharedMediaType.file) {
        final mime = first.mimeType ?? _guessMime(first.path);
        // Only accept types the Smart Import tab can actually parse.
        if (!_acceptedMime(mime)) {
          debugPrint('[ShareIntent] ignoring unsupported mime: $mime');
          return;
        }
        final bytes = await File(first.path).readAsBytes();
        final name = first.path.split(RegExp(r'[\\/]')).last;
        pendingShare.value = PendingShare(
          fileBytes: bytes,
          fileMime: mime,
          fileName: name,
        );
        return;
      }
    } catch (e) {
      debugPrint('[ShareIntent] handle failed: $e');
    }
  }

  static String _guessMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }

  static bool _acceptedMime(String? mime) {
    if (mime == null) return false;
    return mime == 'application/pdf' ||
        mime == 'image/png' ||
        mime == 'image/jpeg' ||
        mime == 'image/jpg';
  }
}
