import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'google_drive_auth_service.dart';
import 'supabase_service.dart';
import 'auth_service.dart';
import 'csv_reconciliation_service.dart';

/// Syncs bill photos from Supabase Storage → Google Drive using a service account.
/// Failures are persisted in Hive and retried up to 5 times at 30-min intervals.
class DriveSyncService {
  static DriveSyncService? _instance;
  static DriveSyncService get instance => _instance ??= DriveSyncService._();
  DriveSyncService._();

  // Loaded at runtime from env.json (String.fromEnvironment truncates long values)
  static String? _jaFolderId;
  static String? _maFolderId;
  static String? _dataUploadFolderId;

  static Future<void> _ensureFolderIds() async {
    if (_jaFolderId != null) return;
    try {
      final envString = await rootBundle.loadString('env.json');
      final env = jsonDecode(envString) as Map<String, dynamic>;
      _jaFolderId = env['DRIVE_FOLDER_JA'] as String? ?? 'PLACEHOLDER_JA';
      _maFolderId = env['DRIVE_FOLDER_MA'] as String? ?? 'PLACEHOLDER_MA';
      _dataUploadFolderId = env['DRIVE_FOLDER_DATA_UPLOAD'] as String?;
    } catch (_) {
      _jaFolderId = 'PLACEHOLDER_JA';
      _maFolderId = 'PLACEHOLDER_MA';
    }
  }

  static String get jaFolderId => _jaFolderId ?? 'PLACEHOLDER_JA';
  static String get maFolderId => _maFolderId ?? 'PLACEHOLDER_MA';
  static String? get dataUploadFolderId => _dataUploadFolderId;

  static const String _failuresBoxName = 'drive_sync_failures';
  static const int _maxRetries = 5;
  static const int _retryIntervalMs = 30 * 60 * 1000; // 30 minutes

  bool _isSyncing = false;

  /// Total number of tracked failures (pending + permanently failed).
  /// Used for the admin notification badge.
  final ValueNotifier<int> failureCount = ValueNotifier(0);

  Future<Box> _failuresBox() async {
    if (Hive.isBoxOpen(_failuresBoxName)) return Hive.box(_failuresBoxName);
    return Hive.openBox(_failuresBoxName);
  }

  // ─── PUBLIC API ────────────────────────────────────────────────────────────

  /// Sync all unsynced bill photos from Supabase → Drive, then retry any
  /// pending failures that are at least 30 minutes old.
  Future<void> syncAll() async {
    if (_isSyncing) return;
    if (!GoogleDriveAuthService.instance.isSignedIn) {
      debugPrint('DriveSyncService: Google Drive not connected, skipping sync');
      return;
    }
    _isSyncing = true;
    try {
      await _ensureFolderIds();
      await _runSync();
      await _retryPending();
      await _syncAvatarPhotos();
      // Auto-sync stock (ITMRP) + bill verification (ITTR) from Drive
      try {
        await syncStockFromDrive();
      } catch (e) {
        debugPrint('DriveSyncService: Stock auto-sync failed: $e');
      }
      try {
        await syncBillsFromDrive();
      } catch (e) {
        debugPrint('DriveSyncService: Bill auto-sync failed: $e');
      }
    } catch (e) {
      debugPrint('DriveSyncService.syncAll error: $e');
    } finally {
      _isSyncing = false;
      await _refreshCount();
    }
  }

  /// Returns all tracked failures sorted newest-first.
  Future<List<Map<String, dynamic>>> getFailures() async {
    final box = await _failuresBox();
    final list = box.values
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
    list.sort((a, b) =>
        ((b['last_error_ms'] as int?) ?? 0)
            .compareTo((a['last_error_ms'] as int?) ?? 0));
    return list;
  }

  /// Admin-triggered: force retry a single failure immediately, ignoring
  /// the 30-min cooldown. Resets permanently_failed back to pending.
  Future<void> retryFailure(String orderId) async {
    final box = await _failuresBox();
    final raw = box.get(orderId);
    if (raw == null) return;
    final entry = Map<String, dynamic>.from(raw as Map);
    // Lower retry count so it gets one more attempt
    final retries = entry['retries'] as int? ?? _maxRetries;
    await box.put(orderId, {
      ...entry,
      'retries': retries >= _maxRetries ? _maxRetries - 1 : retries,
      'status': 'pending',
      'last_error_ms': 0, // force immediate retry eligibility
    });
    await syncAll();
  }

  /// Admin dismisses a failure entry from the list.
  Future<void> dismissFailure(String orderId) async {
    final box = await _failuresBox();
    await box.delete(orderId);
    await _refreshCount();
  }

  /// Manual trigger for debugging - sync with enhanced logging and UI feedback
  Future<void> syncPendingPhotosNow({bool showSnackBars = false}) async {
    if (!GoogleDriveAuthService.instance.isSignedIn) {
      throw Exception('Google Drive not connected. Sign in with Google first.');
    }
    if (_isSyncing) {
      if (showSnackBars) {
        debugPrint('DriveSyncService: Sync already in progress, skipping');
      }
      return;
    }
    
    _isSyncing = true;
    debugPrint('🚀 DriveSyncService: Starting manual sync with enhanced logging');

    try {
      await _ensureFolderIds();
      await _runSyncWithLogging();
      await _retryPendingWithLogging();
      
      if (showSnackBars) {
        debugPrint('✅ DriveSyncService: Manual sync completed successfully');
      }
    } catch (e) {
      debugPrint('❌ DriveSyncService: Manual sync failed: $e');
      if (showSnackBars) {
        // Could show SnackBar here if called from UI
      }
    } finally {
      _isSyncing = false;
      await _refreshCount();
      debugPrint('🏁 DriveSyncService: Manual sync finished');
    }
  }

  // ─── INTERNAL ─────────────────────────────────────────────────────────────

  Future<void> _runSync() async {
    final client = Supabase.instance.client;
    debugPrint('📋 DriveSyncService: Fetching orders with Supabase bill photos...');
    
    final response = await client
        .from('orders')
        .select('id, team_id, bill_photo_url, final_bill_no')
        .not('bill_photo_url', 'is', null)
        .ilike('bill_photo_url', '%supabase%')
        .eq('verified_by_delivery', true);

    final orders = (response as List).cast<Map<String, dynamic>>();
    debugPrint('📊 DriveSyncService: Found ${orders.length} photos to sync');
    
    for (final order in orders) {
      await _syncOne(order);
    }
  }

  /// Enhanced version of _runSync with detailed logging for debugging
  Future<void> _runSyncWithLogging() async {
    final client = Supabase.instance.client;
    debugPrint('📋 DriveSyncService: Fetching orders with Supabase bill photos...');
    
    try {
      final response = await client
          .from('orders')
          .select('id, team_id, bill_photo_url, final_bill_no')
          .not('bill_photo_url', 'is', null)
          .ilike('bill_photo_url', '%supabase%')
          .eq('verified_by_delivery', true);

      final orders = (response as List).cast<Map<String, dynamic>>();
      debugPrint('📊 DriveSyncService: Found ${orders.length} photos to sync');
      
      if (orders.isEmpty) {
        debugPrint('✅ DriveSyncService: No pending photos to sync');
        return;
      }
      
      for (int i = 0; i < orders.length; i++) {
        final order = orders[i];
        debugPrint('🔄 DriveSyncService: Processing photo ${i + 1}/${orders.length} for order ${order['id']}');
        await _syncOneWithLogging(order);
      }
    } catch (e) {
      debugPrint('❌ DriveSyncService: Failed to fetch orders: $e');
      rethrow;
    }
  }

  /// Process pending failures whose last attempt was >30 min ago.
  Future<void> _retryPending() async {
    final box = await _failuresBox();
    final now = DateTime.now().millisecondsSinceEpoch;
    final keys = box.keys.toList();

    for (final key in keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      final entry = Map<String, dynamic>.from(raw as Map);
      if (entry['status'] != 'pending') continue;
      final lastErrorMs = entry['last_error_ms'] as int? ?? 0;
      if (now - lastErrorMs < _retryIntervalMs) continue;

      debugPrint(
          'DriveSyncService: retrying ${entry['order_id']} (attempt ${(entry['retries'] as int? ?? 0) + 1})');
      await _syncOne({
        'id': entry['order_id'],
        'team_id': entry['team_id'],
        'bill_photo_url': entry['bill_photo_url'],
        'final_bill_no': entry['final_bill_no'],
      });
    }
  }

  /// Enhanced version of _retryPending with detailed logging
  Future<void> _retryPendingWithLogging() async {
    final box = await _failuresBox();
    final now = DateTime.now().millisecondsSinceEpoch;
    final keys = box.keys.toList();

    debugPrint('🔄 DriveSyncService: Checking for pending failures to retry...');
    
    if (keys.isEmpty) {
      debugPrint('✅ DriveSyncService: No pending failures to retry');
      return;
    }

    int retryCount = 0;
    for (final key in keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      final entry = Map<String, dynamic>.from(raw as Map);
      if (entry['status'] != 'pending') continue;
      final lastErrorMs = entry['last_error_ms'] as int? ?? 0;
      if (now - lastErrorMs < _retryIntervalMs) {
        debugPrint('⏰ DriveSyncService: Skipping ${entry['order_id']} - cooldown period not elapsed');
        continue;
      }

      retryCount++;
      final currentRetries = entry['retries'] as int? ?? 0;
      debugPrint('🔄 DriveSyncService: Retrying ${entry['order_id']} (attempt ${currentRetries + 1}/$_maxRetries)');
      await _syncOneWithLogging({
        'id': entry['order_id'],
        'team_id': entry['team_id'],
        'bill_photo_url': entry['bill_photo_url'],
        'final_bill_no': entry['final_bill_no'],
      });
    }
    
    debugPrint('📊 DriveSyncService: Retried $retryCount pending failures');
  }

  Future<void> _syncOne(Map<String, dynamic> order) async {
    final orderId = order['id'] as String? ?? '';
    if (orderId.isEmpty) return;

    try {
      final teamId = order['team_id'] as String? ?? 'JA';
      final supabaseUrl = order['bill_photo_url'] as String? ?? '';
      if (supabaseUrl.isEmpty) return;
      final billNo = order['final_bill_no'] as String? ??
          orderId.split('-').first.toUpperCase();

      // 1. Download photo bytes from Supabase
      final photoResponse = await http.get(Uri.parse(supabaseUrl));
      if (photoResponse.statusCode != 200) {
        throw Exception('Photo download failed: HTTP ${photoResponse.statusCode}');
      }
      final bytes = photoResponse.bodyBytes;

      // 2. Get service account auth headers
      final headers = await GoogleDriveAuthService.instance.authHeaders();

      // 3. Determine parent folder
      final parentFolderId = teamId == 'MA' ? maFolderId : jaFolderId;

      // 4. Get/create month subfolder
      final now = DateTime.now();
      final monthName = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      final monthFolderId =
          await _getOrCreateFolder(headers, parentFolderId, monthName);
      if (monthFolderId == null) throw Exception('Could not get/create Drive folder');

      // 5. Upload to Drive
      final fileName =
          '${billNo}_${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.jpg';
      final fileId = await _uploadToDrive(headers, bytes, fileName, monthFolderId);
      if (fileId == null) throw Exception('Drive upload returned no fileId');

      // 6. Make public
      await _makePublic(headers, fileId);

      // 7. Build direct-image URL
      final driveUrl =
          'https://drive.google.com/thumbnail?id=$fileId&sz=w2048-h2048';

      // 8. Update order in Supabase
      await Supabase.instance.client
          .from('orders')
          .update({'bill_photo_url': driveUrl}).eq('id', orderId);

      // 9. Delete original from Supabase Storage
      final storagePath =
          supabaseUrl.split('/bill-photos/').last.split('?').first;
      try {
        await Supabase.instance.client.storage
            .from('bill-photos')
            .remove([storagePath]);
      } catch (_) {}

      // 10. Clear failure record on success
      await _clearFailure(orderId);
      debugPrint('DriveSyncService: synced $orderId → $driveUrl');
    } catch (e) {
      debugPrint('DriveSyncService._syncOne error for $orderId: $e');
      await _recordFailure(order, e.toString());
    }
  }

  /// Enhanced version of _syncOne with detailed step-by-step logging
  Future<void> _syncOneWithLogging(Map<String, dynamic> order) async {
    final orderId = order['id'] as String? ?? '';
    if (orderId.isEmpty) {
      debugPrint('❌ DriveSyncService: Skipping order - empty ID');
      return;
    }

    debugPrint('📸 DriveSyncService: Starting sync for order $orderId');

    try {
      final teamId = order['team_id'] as String? ?? 'JA';
      final supabaseUrl = order['bill_photo_url'] as String? ?? '';
      if (supabaseUrl.isEmpty) {
        debugPrint('❌ DriveSyncService: Skipping $orderId - empty bill photo URL');
        return;
      }
      final billNo = order['final_bill_no'] as String? ??
          orderId.split('-').first.toUpperCase();

      debugPrint('📋 DriveSyncService: Order details - Team: $teamId, Bill: $billNo');
      debugPrint('🔗 DriveSyncService: Supabase URL: $supabaseUrl');

      // 1. Download photo bytes from Supabase
      debugPrint('⬇️ DriveSyncService: Step 1 - Downloading photo from Supabase...');
      final photoResponse = await http.get(Uri.parse(supabaseUrl));
      if (photoResponse.statusCode != 200) {
        throw Exception('Photo download failed: HTTP ${photoResponse.statusCode} - ${photoResponse.reasonPhrase}');
      }
      final bytes = photoResponse.bodyBytes;
      debugPrint('✅ DriveSyncService: Downloaded ${bytes.length} bytes successfully');

      // 2. Get service account auth headers
      debugPrint('🔐 DriveSyncService: Step 2 - Getting service account auth headers...');
      final headers = await GoogleDriveAuthService.instance.authHeaders();
      if (headers.isEmpty) {
        throw Exception('Failed to get service account auth headers');
      }
      debugPrint('✅ DriveSyncService: Auth headers obtained successfully');

      // 3. Determine parent folder
      debugPrint('📁 DriveSyncService: Step 3 - Determining parent folder...');
      final parentFolderId = teamId == 'MA' ? maFolderId : jaFolderId;
      debugPrint('📂 DriveSyncService: Parent folder ID: $parentFolderId (Team: $teamId)');

      // 4. Get/create month subfolder
      debugPrint('📅 DriveSyncService: Step 4 - Getting/creating month subfolder...');
      final now = DateTime.now();
      final monthName = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      debugPrint('📆 DriveSyncService: Month folder: $monthName');
      final monthFolderId =
          await _getOrCreateFolder(headers, parentFolderId, monthName);
      if (monthFolderId == null) {
        throw Exception('Could not get/create Drive folder for month: $monthName');
      }
      debugPrint('✅ DriveSyncService: Month folder ID: $monthFolderId');

      // 5. Upload to Drive
      debugPrint('⬆️ DriveSyncService: Step 5 - Uploading to Google Drive...');
      final fileName =
          '${billNo}_${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.jpg';
      debugPrint('📄 DriveSyncService: Filename: $fileName');
      final fileId = await _uploadToDrive(headers, bytes, fileName, monthFolderId);
      if (fileId == null) {
        throw Exception('Drive upload returned no fileId - upload may have failed');
      }
      debugPrint('✅ DriveSyncService: Upload successful - File ID: $fileId');

      // 6. Make public
      debugPrint('🌐 DriveSyncService: Step 6 - Making file public...');
      await _makePublic(headers, fileId);
      debugPrint('✅ DriveSyncService: File made public successfully');

      // 7. Build direct-image URL
      debugPrint('🔗 DriveSyncService: Step 7 - Building public URL...');
      final driveUrl =
          'https://drive.google.com/thumbnail?id=$fileId&sz=w2048-h2048';
      debugPrint('🖼️ DriveSyncService: Public URL: $driveUrl');

      // 8. Update order in Supabase
      debugPrint('💾 DriveSyncService: Step 8 - Updating order in Supabase...');
      await Supabase.instance.client
          .from('orders')
          .update({'bill_photo_url': driveUrl}).eq('id', orderId);
      debugPrint('✅ DriveSyncService: Order updated in Supabase');

      // 9. Delete original from Supabase Storage
      debugPrint('🗑️ DriveSyncService: Step 9 - Deleting original from Supabase Storage...');
      final storagePath =
          supabaseUrl.split('/bill-photos/').last.split('?').first;
      debugPrint('📦 DriveSyncService: Storage path to delete: $storagePath');
      try {
        await Supabase.instance.client.storage
            .from('bill-photos')
            .remove([storagePath]);
        debugPrint('✅ DriveSyncService: Original file deleted from Supabase Storage');
      } catch (e) {
        debugPrint('⚠️ DriveSyncService: Warning - Could not delete original file: $e');
      }

      // 10. Clear failure record on success
      debugPrint('🧹 DriveSyncService: Step 10 - Clearing failure record...');
      await _clearFailure(orderId);
      debugPrint('🎉 DriveSyncService: ✅ SUCCESS - $orderId synced to $driveUrl');
    } catch (e) {
      debugPrint('💥 DriveSyncService: ❌ FAILED for $orderId: $e');
      await _recordFailure(order, e.toString());
    }
  }

  Future<void> _recordFailure(Map<String, dynamic> order, String error) async {
    final box = await _failuresBox();
    final orderId = order['id'] as String? ?? '';
    if (orderId.isEmpty) return;

    final existing = box.get(orderId);
    final prevRetries = existing != null
        ? (Map<String, dynamic>.from(existing as Map)['retries'] as int? ?? 0)
        : 0;
    final retries = prevRetries + 1;

    await box.put(orderId, {
      'order_id': orderId,
      'team_id': order['team_id'] as String? ?? 'JA',
      'bill_photo_url': order['bill_photo_url'] as String? ?? '',
      'final_bill_no': order['final_bill_no'] as String?,
      'retries': retries,
      'last_error_ms': DateTime.now().millisecondsSinceEpoch,
      'last_error':
          error.length > 200 ? '${error.substring(0, 200)}…' : error,
      'status': retries >= _maxRetries ? 'permanently_failed' : 'pending',
    });
  }

  Future<void> _clearFailure(String orderId) async {
    final box = await _failuresBox();
    await box.delete(orderId);
  }

  Future<void> _refreshCount() async {
    final box = await _failuresBox();
    failureCount.value = box.length;
  }

  // ─── DRIVE API HELPERS ────────────────────────────────────────────────────

  Future<String?> _getOrCreateFolder(
      Map<String, String> headers, String parentId, String name) async {
    try {
      final q = Uri.encodeComponent(
          "name='$name' and '$parentId' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false");
      final searchResp = await http.get(
        Uri.parse(
            'https://www.googleapis.com/drive/v3/files?q=$q&fields=files(id)&supportsAllDrives=true&includeItemsFromAllDrives=true'),
        headers: headers,
      );
      debugPrint('📂 _getOrCreateFolder search "$name" in $parentId → ${searchResp.statusCode}: ${searchResp.body}');
      if (searchResp.statusCode == 200) {
        final data = jsonDecode(searchResp.body) as Map<String, dynamic>;
        final files = (data['files'] as List?) ?? [];
        if (files.isNotEmpty) return files.first['id'] as String;
      }

      // Folder not found — create it
      final createResp = await http.post(
        Uri.parse('https://www.googleapis.com/drive/v3/files?supportsAllDrives=true'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': name,
          'mimeType': 'application/vnd.google-apps.folder',
          'parents': [parentId],
        }),
      );
      debugPrint('📂 _getOrCreateFolder create "$name" → ${createResp.statusCode}: ${createResp.body}');
      if (createResp.statusCode == 200 || createResp.statusCode == 201) {
        final data = jsonDecode(createResp.body) as Map<String, dynamic>;
        return data['id'] as String?;
      }
      return null;
    } catch (e) {
      debugPrint('_getOrCreateFolder error: $e');
      return null;
    }
  }

  Future<String?> _uploadToDrive(Map<String, String> headers, Uint8List bytes,
      String fileName, String parentFolderId) async {
    try {
      debugPrint('📤 DriveSyncService: Preparing upload request...');
      final boundary =
          'MAJAABoundary${DateTime.now().millisecondsSinceEpoch}';
      final metadata = jsonEncode({
        'name': fileName,
        'mimeType': 'image/jpeg',
        'parents': [parentFolderId],
      });
      final body = utf8.encode(
            '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n--$boundary\r\nContent-Type: image/jpeg\r\n\r\n',
          ) +
          bytes +
          utf8.encode('\r\n--$boundary--');

      debugPrint('📤 DriveSyncService: Uploading ${bytes.length} bytes to Google Drive...');
      final resp = await http.post(
        Uri.parse(
            'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true'),
        headers: {
          ...headers,
          'Content-Type': 'multipart/related; boundary=$boundary',
          'Content-Length': body.length.toString(),
        },
        body: body,
      );
      
      debugPrint('📊 DriveSyncService: Upload response status: ${resp.statusCode}');
      
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final fileId = data['id'] as String?;
        debugPrint('✅ DriveSyncService: Upload successful - File ID: $fileId');
        return fileId;
      } else {
        debugPrint('❌ DriveSyncService: Upload failed with status ${resp.statusCode}');
        debugPrint('❌ DriveSyncService: Response body: ${resp.body}');
        debugPrint('❌ DriveSyncService: Response headers: ${resp.headers}');
        return null;
      }
    } catch (e) {
      debugPrint('💥 DriveSyncService: Upload exception: $e');
      return null;
    }
  }

  Future<void> _makePublic(Map<String, String> headers, String fileId) async {
    try {
      debugPrint('🌐 DriveSyncService: Making file $fileId public...');
      final resp = await http.post(
        Uri.parse(
            'https://www.googleapis.com/drive/v3/files/$fileId/permissions'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'type': 'anyone', 'role': 'reader'}),
      );
      
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        debugPrint('✅ DriveSyncService: File made public successfully');
      } else {
        debugPrint('⚠️ DriveSyncService: Failed to make file public - Status: ${resp.statusCode}');
        debugPrint('⚠️ DriveSyncService: Permission response: ${resp.body}');
      }
    } catch (e) {
      debugPrint('💥 DriveSyncService: Permission error: $e');
    }
  }

  /// Syncs avatar photos from Supabase Storage → Google Drive.
  /// Organizes into {team}/SalesRep/ or {team}/DeliveryRep/ folders.
  Future<void> _syncAvatarPhotos() async {
    try {
      // Find users with Supabase-hosted avatars (not yet on Drive)
      final users = await Supabase.instance.client
          .from('app_users')
          .select('id, full_name, role, team_id, hero_image_url')
          .not('hero_image_url', 'is', null)
          .like('hero_image_url', '%supabase%');

      if (users.isEmpty) {
        debugPrint('📸 AvatarSync: No avatars to sync');
        return;
      }
      debugPrint('📸 AvatarSync: Found ${users.length} avatars to sync');

      final headers = await GoogleDriveAuthService.instance.authHeaders();

      for (final user in users) {
        try {
          final userId = user['id'] as String;
          final role = user['role'] as String? ?? 'sales_rep';
          final teamId = user['team_id'] as String? ?? 'JA';
          final imageUrl = user['hero_image_url'] as String;
          final fullName = user['full_name'] as String? ?? userId;

          // Determine folder: {team}/SalesRep or {team}/DeliveryRep
          final roleFolder = role.contains('delivery') ? 'DeliveryRep' : 'SalesRep';
          final parentFolderId = teamId == 'MA' ? maFolderId : jaFolderId;

          // Get/create role subfolder
          final roleFolderId = await _getOrCreateFolder(headers, parentFolderId, roleFolder);
          if (roleFolderId == null) {
            debugPrint('⚠️ AvatarSync: Could not create $roleFolder folder');
            continue;
          }

          // Download from Supabase
          final resp = await http.get(Uri.parse(imageUrl));
          if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) continue;

          // Upload to Drive
          final safeName = fullName.replaceAll(RegExp(r'[^a-zA-Z0-9_\- ]'), '').trim();
          final fileName = '${safeName}_$userId.jpg';
          final fileId = await _uploadToDrive(headers, resp.bodyBytes, fileName, roleFolderId);
          if (fileId == null) continue;

          await _makePublic(headers, fileId);
          final driveUrl = 'https://drive.google.com/thumbnail?id=$fileId&sz=w2048-h2048';

          // Update user record with Drive URL
          await Supabase.instance.client.from('app_users')
              .update({'hero_image_url': driveUrl})
              .eq('id', userId);

          // Delete from Supabase Storage
          try {
            final uri = Uri.parse(imageUrl);
            final segments = uri.pathSegments;
            final bucketIndex = segments.indexOf('bill-photos');
            if (bucketIndex >= 0) {
              final storagePath = segments.sublist(bucketIndex + 1).join('/');
              await Supabase.instance.client.storage.from('bill-photos').remove([storagePath]);
            }
          } catch (_) {}

          debugPrint('✅ AvatarSync: $fullName → Drive ($roleFolder)');
        } catch (e) {
          debugPrint('⚠️ AvatarSync: Failed for ${user['id']}: $e');
        }
      }
    } catch (e) {
      debugPrint('💥 AvatarSync error: $e');
    }
  }

  // ─── ITMRP STOCK SYNC ──────────────────────────────────────────────────────

  bool _isStockSyncing = false;

  /// Result of an ITMRP stock sync — matched/unmatched/updated counts.
  StockSyncResult? lastStockSyncResult;

  /// Sync stock from ITMRP CSV files in Google Drive "data upload" subfolders.
  /// Finds the "data upload" folder inside JA/MA team folders, locates ITMRP*.csv,
  /// downloads, parses, and updates product stock_qty (and unit_price if MRP differs
  /// for duplicate items — picks the one with higher stock).
  Future<StockSyncResult> syncStockFromDrive() async {
    if (_isStockSyncing) return StockSyncResult(error: 'Stock sync already in progress');
    _isStockSyncing = true;

    try {
      await _ensureFolderIds();
      final headers = await GoogleDriveAuthService.instance.authHeaders();
      if (headers.isEmpty) return StockSyncResult(error: 'Not signed in to Google Drive');

      // 1. Use standalone "data upload" folder from env.json
      if (dataUploadFolderId == null || dataUploadFolderId!.isEmpty) {
        return StockSyncResult(error: 'DRIVE_FOLDER_DATA_UPLOAD not set in env.json');
      }
      final dataUploadId = dataUploadFolderId!;
      debugPrint('📂 StockSync: Using "data upload" folder: $dataUploadId');

      // 2. List all files in folder for diagnostics, then find ITMRP*.csv
      final allFiles = await _listFilesInFolder(headers, dataUploadId);
      debugPrint('📂 StockSync: Files in data upload folder: ${allFiles.map((f) => f['name']).join(', ')}');

      final itmrpFiles = await _findFilesByPrefix(headers, dataUploadId, 'ITMRP');
      if (itmrpFiles.isEmpty) {
        final fileList = allFiles.isEmpty
            ? 'Folder is empty or not shared with service account'
            : 'Files found: ${allFiles.map((f) => f['name']).join(', ')}';
        return StockSyncResult(error: 'No ITMRP*.csv files found. $fileList');
      }

      // 3. Load products from cache (fast), only update Supabase for changes
      final products = await SupabaseService.instance.getProducts();
      final Map<String, dynamic> nameLookup = {};
      for (final p in products) {
        nameLookup[p.name.toLowerCase().trim()] = p;
        if (p.billingName != null && p.billingName!.isNotEmpty) {
          nameLookup[p.billingName!.toLowerCase().trim()] = p;
        }
      }

      // 4. Process each ITMRP file and merge results
      final Map<String, Map<String, dynamic>> bestRows = {};
      for (final file in itmrpFiles) {
        debugPrint('📄 StockSync: Processing ${file['name']}');
        final csvContent = await _downloadFile(headers, file['id']!);
        if (csvContent == null || csvContent.isEmpty) {
          debugPrint('⚠️ StockSync: Skipping ${file['name']} — empty');
          continue;
        }

        final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
            .convert(csvContent);
        if (rows.isEmpty) continue;

        // Parse dBASE headers
        final rawHeaders = rows.first.map((h) {
          final s = h.toString().trim();
          if (s.contains(',')) return s.split(',').first.trim();
          return s;
        }).toList();

        final itemNameIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'ITEMNAME');
        final cfQtyIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'CFQUANTITY');
        final mrpIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'MRP');

        if (itemNameIdx < 0 || cfQtyIdx < 0) {
          debugPrint('⚠️ StockSync: ${file['name']} missing ITEMNAME/CFQUANTITY columns, skipping');
          continue;
        }

        for (int i = 1; i < rows.length; i++) {
          final row = rows[i];
          if (row.length <= itemNameIdx || row.length <= cfQtyIdx) continue;
          final itemName = row[itemNameIdx].toString().trim();
          if (itemName.isEmpty) continue;
          final cfQty = int.tryParse(row[cfQtyIdx].toString().trim().split('.').first) ?? 0;
          double? mrp;
          if (mrpIdx >= 0 && row.length > mrpIdx) {
            mrp = double.tryParse(row[mrpIdx].toString().trim());
          }
          final key = itemName.toLowerCase().trim();
          final existing = bestRows[key];
          if (existing == null || cfQty > (existing['qty'] as int)) {
            bestRows[key] = {'itemName': itemName, 'qty': cfQty, 'mrp': mrp};
          }
        }
        debugPrint('📊 StockSync: ${file['name']} — ${rows.length - 1} rows parsed');
      }

      // 5. Match and update
      int updated = 0;
      int skipped = 0;
      final List<String> unmatched = [];
      for (final entry in bestRows.entries) {
        final csvRow = entry.value;
        final product = nameLookup[entry.key];
        if (product == null) {
          final name = csvRow['itemName'] as String;
          if (!unmatched.contains(name)) unmatched.add(name);
          continue;
        }
        final p = product as dynamic;
        final newQty = csvRow['qty'] as int;
        final newMrp = csvRow['mrp'] as double?;
        final mrpChanged = newMrp != null && newMrp != p.unitPrice;

        if (p.stockQty != newQty || mrpChanged) {
          try {
            final data = <String, dynamic>{'stock_qty': newQty};
            if (mrpChanged) data['unit_price'] = newMrp;
            await SupabaseService.instance.updateProduct(p.id, data);
            updated++;
          } catch (e) {
            debugPrint('StockSync: Failed to update ${p.name}: $e');
          }
        } else {
          skipped++;
        }
      }

      // Clear product cache so app shows fresh data
      if (updated > 0) {
        await SupabaseService.instance.invalidateCache('products');
      }

      final result = StockSyncResult(
        matched: bestRows.length - unmatched.length,
        unmatched: unmatched.length,
        updated: updated,
        skipped: skipped,
        unmatchedNames: unmatched,
      );
      lastStockSyncResult = result;
      debugPrint('✅ StockSync: Done — ${result.matched} matched, $updated updated, ${unmatched.length} unmatched');
      return result;
    } catch (e) {
      debugPrint('❌ StockSync error: $e');
      return StockSyncResult(error: e.toString());
    } finally {
      _isStockSyncing = false;
    }
  }

  // ─── ITTR BILL VERIFICATION SYNC ────────────────────────────────────────────

  bool _isBillSyncing = false;
  BillSyncResult? lastBillSyncResult;

  /// Sync bills from ITTR CSV file in Google Drive "data upload" folder.
  /// Downloads ITTR*.csv, parses it, and reconciles against Supabase orders.
  Future<BillSyncResult> syncBillsFromDrive() async {
    if (_isBillSyncing) return BillSyncResult(error: 'Bill sync already in progress');
    _isBillSyncing = true;

    try {
      await _ensureFolderIds();
      final headers = await GoogleDriveAuthService.instance.authHeaders();
      if (headers.isEmpty) return BillSyncResult(error: 'Not signed in to Google Drive');

      if (dataUploadFolderId == null || dataUploadFolderId!.isEmpty) {
        return BillSyncResult(error: 'DRIVE_FOLDER_DATA_UPLOAD not set in env.json');
      }

      // 1. Find ALL ITTR*.csv files (e.g. ITTR07.csv for JA, ITTR11.csv for MA)
      debugPrint('📄 BillSync: Looking for ITTR*.csv in data upload folder');
      final ittrFiles = await _findFilesByPrefix(headers, dataUploadFolderId!, 'ITTR');
      if (ittrFiles.isEmpty) {
        final allFiles = await _listFilesInFolder(headers, dataUploadFolderId!);
        final fileList = allFiles.isEmpty
            ? 'Folder is empty or not shared with service account'
            : 'Files found: ${allFiles.map((f) => f['name']).join(', ')}';
        return BillSyncResult(error: 'No ITTR*.csv files found. $fileList');
      }

      // 2. Download and parse all ITTR files, merge bills
      final List<Map<String, dynamic>> allBills = [];
      for (final file in ittrFiles) {
        debugPrint('📄 BillSync: Processing ${file['name']}');
        final csvContent = await _downloadFile(headers, file['id']!);
        if (csvContent == null || csvContent.isEmpty) {
          debugPrint('⚠️ BillSync: Skipping ${file['name']} — empty');
          continue;
        }
        final bills = CsvReconciliationService.instance.parseCsv(csvContent);
        debugPrint('📊 BillSync: ${file['name']} — ${bills.length} bills parsed');
        allBills.addAll(bills);
      }

      debugPrint('📊 BillSync: Total ${allBills.length} bills from ${ittrFiles.length} files');

      if (allBills.isEmpty) {
        return BillSyncResult(totalBills: 0);
      }

      // 3. Reconcile against Supabase orders
      final changes = await CsvReconciliationService.instance.reconcile(allBills);
      debugPrint('📊 BillSync: Found ${changes.length} differences');

      // 4. Auto-apply only safe changes (auto-verify matching bills)
      //    Discrepancies are stored in Hive for the Bill Verification tab
      int applied = 0;
      final List<Map<String, dynamic>> discrepancies = [];
      if (changes.isNotEmpty) {
        final autoApplyable = changes.where((c) => c['type'] == 'can_auto_verify').toList();
        final nonAutoApplyable = changes.where((c) => c['type'] != 'can_auto_verify').toList();

        // Auto-apply only safe verifications
        if (autoApplyable.isNotEmpty) {
          applied = await CsvReconciliationService.instance.applyChanges(autoApplyable);
          debugPrint('✅ BillSync: Auto-verified $applied bills');
        }

        // Store discrepancies in Hive for Bill Verification tab
        discrepancies.addAll(nonAutoApplyable);
        if (discrepancies.isNotEmpty) {
          await _saveDriveDiscrepancies(discrepancies);
          debugPrint('📋 BillSync: Saved ${discrepancies.length} discrepancies for review');
        }
      }

      // Clear order cache so app shows fresh data
      if (applied > 0) {
        await SupabaseService.instance.invalidateCache('recent_orders');
      }

      final result = BillSyncResult(
        totalBills: allBills.length,
        differences: changes.length,
        applied: applied,
        discrepancies: discrepancies.length,
        changes: changes,
      );
      lastBillSyncResult = result;
      debugPrint('✅ BillSync: Done — ${allBills.length} bills, $applied auto-verified, ${discrepancies.length} need review');
      return result;
    } catch (e) {
      debugPrint('❌ BillSync error: $e');
      return BillSyncResult(error: e.toString());
    } finally {
      _isBillSyncing = false;
    }
  }

  // ─── DISCREPANCY PERSISTENCE (Hive) ─────────────────────────────────────────

  static const String _discrepancyBoxName = 'drive_bill_discrepancies';

  Future<void> _saveDriveDiscrepancies(List<Map<String, dynamic>> discrepancies) async {
    final box = await _openDiscrepancyBox();
    // Replace all — each sync overwrites previous discrepancies
    await box.clear();
    for (int i = 0; i < discrepancies.length; i++) {
      await box.put('disc_$i', discrepancies[i]);
    }
  }

  /// Get saved discrepancies for the Bill Verification tab.
  Future<List<Map<String, dynamic>>> getDriveDiscrepancies() async {
    final box = await _openDiscrepancyBox();
    return box.values.map((v) => Map<String, dynamic>.from(v as Map)).toList();
  }

  /// Clear discrepancies after admin reviews them.
  Future<void> clearDriveDiscrepancies() async {
    final box = await _openDiscrepancyBox();
    await box.clear();
  }

  Future<Box> _openDiscrepancyBox() async {
    if (Hive.isBoxOpen(_discrepancyBoxName)) return Hive.box(_discrepancyBoxName);
    return Hive.openBox(_discrepancyBoxName);
  }

  /// Find a subfolder by name (case-insensitive) in a parent folder.
  Future<String?> _findFolder(Map<String, String> headers, String parentId, String folderName) async {
    try {
      final q = Uri.encodeComponent(
          "name='$folderName' and '$parentId' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false");
      final resp = await http.get(
        Uri.parse('https://www.googleapis.com/drive/v3/files?q=$q&fields=files(id,name)&supportsAllDrives=true&includeItemsFromAllDrives=true'),
        headers: headers,
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final files = (data['files'] as List?) ?? [];
        if (files.isNotEmpty) return files.first['id'] as String;
      }
      return null;
    } catch (e) {
      debugPrint('_findFolder error: $e');
      return null;
    }
  }

  /// Find ALL CSV files matching a name prefix (e.g. "ITMRP" → ITMRP07.csv, ITMRP11.csv).
  Future<List<Map<String, String>>> _findFilesByPrefix(Map<String, String> headers, String parentId, String prefix) async {
    final List<Map<String, String>> results = [];
    try {
      // Try with mimeType filter first
      final q = Uri.encodeComponent(
          "name contains '$prefix' and '$parentId' in parents and mimeType='text/csv' and trashed=false");
      final resp = await http.get(
        Uri.parse('https://www.googleapis.com/drive/v3/files?q=$q&fields=files(id,name)&supportsAllDrives=true&includeItemsFromAllDrives=true'),
        headers: headers,
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final files = (data['files'] as List?) ?? [];
        for (final f in files) {
          results.add({'id': f['id'] as String, 'name': f['name'] as String});
        }
      }
      // Also try without mimeType filter (some CSVs may have different MIME)
      if (results.isEmpty) {
        final q2 = Uri.encodeComponent(
            "name contains '$prefix' and '$parentId' in parents and trashed=false");
        final resp2 = await http.get(
          Uri.parse('https://www.googleapis.com/drive/v3/files?q=$q2&fields=files(id,name,mimeType)&supportsAllDrives=true&includeItemsFromAllDrives=true'),
          headers: headers,
        );
        if (resp2.statusCode == 200) {
          final data = jsonDecode(resp2.body) as Map<String, dynamic>;
          final files = (data['files'] as List?) ?? [];
          for (final f in files) {
            final name = (f['name'] as String).toLowerCase();
            if (name.endsWith('.csv')) {
              results.add({'id': f['id'] as String, 'name': f['name'] as String});
            }
          }
        }
      }
      if (results.isNotEmpty) {
        debugPrint('DriveSync: Found ${results.length} $prefix files: ${results.map((f) => f['name']).join(', ')}');
      }
    } catch (e) {
      debugPrint('_findFilesByPrefix error: $e');
    }
    return results;
  }

  /// List all files in a folder (for diagnostics).
  Future<List<Map<String, String>>> _listFilesInFolder(Map<String, String> headers, String folderId) async {
    try {
      final q = Uri.encodeComponent("'$folderId' in parents and trashed=false");
      final resp = await http.get(
        Uri.parse('https://www.googleapis.com/drive/v3/files?q=$q&fields=files(id,name,mimeType)&supportsAllDrives=true&includeItemsFromAllDrives=true'),
        headers: headers,
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final files = (data['files'] as List?) ?? [];
        return files.map((f) => {
          'id': f['id'] as String,
          'name': f['name'] as String,
          'mimeType': (f['mimeType'] as String?) ?? '',
        }).toList();
      }
      debugPrint('_listFilesInFolder: ${resp.statusCode} ${resp.body}');
      return [];
    } catch (e) {
      debugPrint('_listFilesInFolder error: $e');
      return [];
    }
  }

  /// Download file content as string from Drive.
  Future<String?> _downloadFile(Map<String, String> headers, String fileId) async {
    try {
      final resp = await http.get(
        Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId?alt=media&supportsAllDrives=true'),
        headers: headers,
      );
      if (resp.statusCode == 200) {
        // Try UTF-8 first, fallback to Latin-1 (dBASE exports often use Latin-1)
        try {
          return utf8.decode(resp.bodyBytes);
        } catch (_) {
          return latin1.decode(resp.bodyBytes);
        }
      }
      debugPrint('Download failed: ${resp.statusCode}');
      return null;
    } catch (e) {
      debugPrint('_downloadFile error: $e');
      return null;
    }
  }
}

/// Result of a stock sync operation.
class StockSyncResult {
  final int matched;
  final int unmatched;
  final int updated;
  final int skipped;
  final List<String> unmatchedNames;
  final String? error;

  StockSyncResult({
    this.matched = 0,
    this.unmatched = 0,
    this.updated = 0,
    this.skipped = 0,
    this.unmatchedNames = const [],
    this.error,
  });

  bool get hasError => error != null;
}

/// Result of a bill sync operation.
class BillSyncResult {
  final int totalBills;
  final int differences;
  final int applied;
  final int discrepancies;
  final List<Map<String, dynamic>> changes;
  final String? error;

  BillSyncResult({
    this.totalBills = 0,
    this.differences = 0,
    this.applied = 0,
    this.discrepancies = 0,
    this.changes = const [],
    this.error,
  });

  bool get hasError => error != null;
}

/// Top-level callback for WorkManager background task.
@pragma('vm:entry-point')
void driveWorkManagerCallback() {
  // WorkManager callback registered in main.dart
}
