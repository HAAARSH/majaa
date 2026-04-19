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

  /// Fires when Drive sync fails due to expired/invalid Google auth.
  /// UI can listen to this and show a re-login prompt.
  final ValueNotifier<String?> authError = ValueNotifier(null);

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
    authError.value = null; // Clear previous auth error
    try {
      await _ensureFolderIds();
      await _runSync();
      await _retryPending();
      await _syncAvatarPhotos();
      // Pre-load shared data once for all sync steps (cache-first, fast)
      await _preloadSyncCache();

      // Cleanup app collections older than 6 days (before RECT brings in billing software records)
      await SupabaseService.instance.cleanupOldAppCollections();

      // Auto-sync all CSV file types from Drive
      // Order matters: ACMAST first (links acc_codes), then data files, BILLED_COLLECTED last (source of truth for outstanding)
      final syncSteps = <String, Future<void> Function()>{
        'ITMRP (Stock)': syncStockFromDrive,
        'ITTR (Bills)': syncBillsFromDrive,
        'ACMAST (Customers)': syncCustomersFromDrive,
        'OPNBIL (Opening Bills)': syncOutstandingBillsFromDrive,
        'INV (Invoices)': syncInvoicesFromDrive,
        'RECT+RCTBIL (Receipts)': syncReceiptsFromDrive,
        'ITTR (Billed Items)': syncBilledItemsFromDrive,
        'BILLED_COLLECTED (Outstanding)': syncBilledCollectedFromDrive,
      };
      for (final entry in syncSteps.entries) {
        try {
          await entry.value();
        } catch (e) {
          debugPrint('DriveSyncService: ${entry.key} auto-sync failed: $e');
        }
      }

      // Save last synced timestamp
      try {
        final box = await Hive.openBox('app_settings');
        await box.put('last_drive_sync', DateTime.now().toIso8601String());
      } catch (_) {}

      // Clear shared cache after sync completes
      _syncCustomersCache = null;
      _syncProductsJaCache = null;
      _syncProductsMaCache = null;
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
        if (files.isNotEmpty) {
          final id = files.first['id'] as String?;
          if (id != null) return id;
        }
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

  // ─── SHARED SYNC CACHE ───────────────────────────────────────────────────────
  // Loaded once per syncAll cycle, used by all sync methods to avoid repeated DB calls.

  List<CustomerModel>? _syncCustomersCache;
  List<ProductModel>? _syncProductsJaCache;
  List<ProductModel>? _syncProductsMaCache;

  /// Pre-load customers + products from local Hive cache (fast) for all sync steps.
  Future<void> _preloadSyncCache() async {
    // Customers (shared across teams, one fetch)
    _syncCustomersCache ??= await SupabaseService.instance.getCustomers();
    // Products per team (cache-first, no forceRefresh)
    final savedTeam = AuthService.currentTeam;
    AuthService.currentTeam = 'JA';
    _syncProductsJaCache ??= await SupabaseService.instance.getProducts();
    AuthService.currentTeam = 'MA';
    _syncProductsMaCache ??= await SupabaseService.instance.getProducts();
    AuthService.currentTeam = savedTeam;
    debugPrint('📦 SyncCache: ${_syncCustomersCache!.length} customers, '
        '${_syncProductsJaCache!.length} JA products, ${_syncProductsMaCache!.length} MA products');
  }

  /// Get cached customers (falls back to fresh fetch if cache not loaded).
  Future<List<CustomerModel>> _getCachedCustomers() async {
    return _syncCustomersCache ?? await SupabaseService.instance.getCustomers();
  }

  /// Get cached products for both teams combined.
  Future<List<ProductModel>> _getCachedAllProducts() async {
    if (_syncProductsJaCache != null && _syncProductsMaCache != null) {
      return [..._syncProductsJaCache!, ..._syncProductsMaCache!];
    }
    // Fallback: load both teams
    final savedTeam = AuthService.currentTeam;
    final all = <ProductModel>[];
    for (final t in ['JA', 'MA']) {
      AuthService.currentTeam = t;
      all.addAll(await SupabaseService.instance.getProducts());
    }
    AuthService.currentTeam = savedTeam;
    return all;
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
      // Clear stale in-memory product cache so we get fresh data from Supabase
      _syncProductsJaCache = null;
      _syncProductsMaCache = null;
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

      // 3. Load products + categories for BOTH teams (cache-first)
      final allProducts = await _getCachedAllProducts();
      final Map<String, List<ProductModel>> nameLookup = {};
      for (final p in allProducts) {
        final key = p.name.toLowerCase().trim();
        nameLookup.putIfAbsent(key, () => []);
        nameLookup[key]!.add(p);
        if (p.billingName != null && p.billingName!.isNotEmpty) {
          final bKey = p.billingName!.toLowerCase().trim();
          nameLookup.putIfAbsent(bKey, () => []);
          nameLookup[bKey]!.add(p);
        }
      }
      final savedTeam = AuthService.currentTeam;
      final Map<String, String> catToTeam = {};
      for (final teamId in ['JA', 'MA']) {
        AuthService.currentTeam = teamId;
        final cats = await SupabaseService.instance.getProductCategories();
        for (final c in cats) {
          if (c.isActive) catToTeam[c.name.toLowerCase().trim()] = teamId;
        }
      }
      AuthService.currentTeam = savedTeam;

      // 4. Process each ITMRP file — collect ALL rows per product per file
      // Same product can appear in both JA and MA files with different stock/MRP
      // Key: "itemName_lower|company_lower" to keep per-company separation
      final Map<String, List<Map<String, dynamic>>> allRows = {};
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
        final rateIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'RATE');
        final companyIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'COMPANY');

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
          double? rate;
          if (rateIdx >= 0 && row.length > rateIdx) {
            rate = double.tryParse(row[rateIdx].toString().trim());
          }
          String? company;
          if (companyIdx >= 0 && row.length > companyIdx) {
            company = row[companyIdx].toString().trim();
          }

          // Key by itemName only — same product in different files merges
          // (products are matched to DB by name, not by company)
          final key = itemName.toLowerCase().trim();
          allRows.putIfAbsent(key, () => []);
          allRows[key]!.add({
            'itemName': itemName,
            'qty': cfQty,
            'mrp': mrp,
            'rate': rate,
            'company': company,
          });
        }
        debugPrint('📊 StockSync: ${file['name']} — ${rows.length - 1} rows parsed');
      }

      // 5. Merge multi-row products:
      //    - Sum ALL qty (across all rows, all MRPs)
      //    - MRP & Rate: from the row with highest stock qty
      //    - Safety: rate must not exceed MRP (prevents billing loss)
      //    - Company: from the row with highest stock
      final Map<String, Map<String, dynamic>> mergedRows = {};
      for (final entry in allRows.entries) {
        final rows = entry.value;
        // Total stock = sum of ALL rows (including different MRPs)
        final totalQty = rows.fold<int>(0, (sum, r) => sum + (r['qty'] as int));
        // Pick MRP, rate, company from the row with highest stock
        rows.sort((a, b) => (b['qty'] as int).compareTo(a['qty'] as int));
        final picked = rows.first;
        final pickedMrp = (picked['mrp'] as double?) ?? 0.0;
        final pickedRate = (picked['rate'] as double?) ?? 0.0;
        // Safety: rate must not exceed MRP (selling above MRP is illegal & causes loss)
        // If rate is 0/negative, don't include it — preserve existing DB price
        double? finalRate;
        if (pickedRate > 0) {
          finalRate = (pickedMrp > 0 && pickedRate > pickedMrp) ? pickedMrp : pickedRate;
        }
        if (rows.length > 1) {
          debugPrint('📊 StockSync merge "${picked['itemName']}": ${rows.length} rows, '
              'picked MRP=$pickedMrp rate=$finalRate from highest-stock row (qty=${picked['qty']}, total=$totalQty)');
        }
        mergedRows[entry.key] = {
          'itemName': picked['itemName'],
          'qty': totalQty,
          'mrp': picked['mrp'],
          'rate': finalRate,
          'company': picked['company'],
        };
      }

      // 6. Match, update, and detect changes
      int updated = 0;
      int skipped = 0;
      int matched = 0;
      int mrpUpdated = 0;
      final List<String> unmatched = [];
      final List<Map<String, dynamic>> newProducts = [];
      final List<Map<String, dynamic>> priceChanges = [];
      final List<Map<String, dynamic>> stockUpdates = [];

      for (final entry in mergedRows.entries) {
        final csvRow = entry.value;
        final products = nameLookup[entry.key];

        if (products == null || products.isEmpty) {
          // Unmatched — check if it belongs to an existing category
          final company = (csvRow['company'] as String?)?.trim() ?? '';
          final name = csvRow['itemName'] as String;
          final companyKey = company.toLowerCase().trim();
          final newQtyCheck = csvRow['qty'] as int;
          if (company.isNotEmpty && catToTeam.containsKey(companyKey) && newQtyCheck > 0) {
            // New product in existing category with stock — surface for admin review
            newProducts.add({
              'itemName': name,
              'company': company,
              'team_id': catToTeam[companyKey],
              'qty': csvRow['qty'] as int,
              'mrp': csvRow['mrp'] as double?,
              'rate': csvRow['rate'] as double?,
            });
          }
          if (!unmatched.contains(name)) unmatched.add(name);
          continue;
        }

        // Update ALL matching products (same name in both teams)
        final newQty = csvRow['qty'] as int;
        final newMrp = csvRow['mrp'] as double?;
        final newRate = csvRow['rate'] as double?;

        for (final p in products) {
          // Auto-apply: stock_qty and mrp
          final data = <String, dynamic>{};
          bool changed = false;

          if (p.stockQty != newQty) {
            data['stock_qty'] = newQty;
            // Auto-update status based on stock thresholds
            if (newQty > 10 && p.status != 'available') {
              data['status'] = 'available';
            } else if (newQty > 0 && newQty <= 10 && p.status != 'lowStock') {
              data['status'] = 'lowStock';
            } else if (newQty <= 0 && p.status != 'outOfStock') {
              data['status'] = 'outOfStock';
            }
            changed = true;
          }
          if (newMrp != null && newMrp != p.mrp) {
            data['mrp'] = newMrp;
            changed = true;
            mrpUpdated++;
          }

          // Auto-apply unit_price change from RATE (same as MRP)
          if (newRate != null && newRate > 0 && newRate != p.unitPrice) {
            data['unit_price'] = newRate;
            changed = true;
          }

          if (changed) {
            stockUpdates.add({'id': p.id, 'data': data});
            updated++;
          } else {
            skipped++;
          }
        }
        matched += products.length;
      }

      // Batch execute stock updates: 20 concurrent at a time
      for (int i = 0; i < stockUpdates.length; i += 10) {
        final chunk = stockUpdates.sublist(i, (i + 10).clamp(0, stockUpdates.length));
        try {
          await Future.wait(chunk.map((u) =>
            SupabaseService.instance.updateProduct(u['id'] as String, u['data'] as Map<String, dynamic>)
          ));
        } catch (e) {
          debugPrint('⚠️ Sync batch ${i ~/ 10 + 1} failed: $e — continuing');
        }
      }

      // Clear product cache so app shows fresh data
      if (updated > 0) {
        await SupabaseService.instance.invalidateCache('products');
      }

      // Pending changes kept in lastStockSyncResult (in-memory), not Hive

      final result = StockSyncResult(
        matched: matched,
        unmatched: unmatched.length,
        updated: updated,
        skipped: skipped,
        unmatchedNames: unmatched,
        newProducts: newProducts,
        priceChanges: priceChanges,
        mrpUpdated: mrpUpdated,
      );
      lastStockSyncResult = result;
      debugPrint('✅ StockSync: Done — ${result.matched} matched, $updated updated, '
          '$mrpUpdated MRP updated, ${unmatched.length} unmatched, '
          '${newProducts.length} new products, ${priceChanges.length} price changes pending');
      return result;
    } catch (e) {
      debugPrint('❌ StockSync error: $e');
      return StockSyncResult(error: e.toString());
    } finally {
      _isStockSyncing = false;
    }
  }

  // ─── STOCK SYNC PENDING CHANGES (Hive) ─────────────────────────────────────

  static const String _stockPendingBoxName = 'stock_sync_pending';

  Future<void> _saveStockSyncPendingChanges(
    List<Map<String, dynamic>> newProducts,
    List<Map<String, dynamic>> priceChanges,
  ) async {
    final box = Hive.isBoxOpen(_stockPendingBoxName)
        ? Hive.box(_stockPendingBoxName)
        : await Hive.openBox(_stockPendingBoxName);
    await box.clear();
    await box.put('new_products', newProducts);
    await box.put('price_changes', priceChanges);
    await box.put('timestamp', DateTime.now().millisecondsSinceEpoch);
  }

  /// Get pending stock sync changes for the Data Changes tab.
  Future<Map<String, dynamic>> getStockSyncPendingChanges() async {
    final box = Hive.isBoxOpen(_stockPendingBoxName)
        ? Hive.box(_stockPendingBoxName)
        : await Hive.openBox(_stockPendingBoxName);
    final newProducts = (box.get('new_products') as List?)
        ?.map((v) => Map<String, dynamic>.from(v as Map))
        .toList() ?? [];
    final priceChanges = (box.get('price_changes') as List?)
        ?.map((v) => Map<String, dynamic>.from(v as Map))
        .toList() ?? [];
    final timestamp = box.get('timestamp') as int?;
    return {
      'new_products': newProducts,
      'price_changes': priceChanges,
      'timestamp': timestamp,
    };
  }

  /// Apply a price change (admin verified). Updates unit_price in Supabase.
  Future<void> applyPriceChange(String productId, double newPrice) async {
    await SupabaseService.instance.updateProduct(productId, {'unit_price': newPrice});
  }

  /// Add a new product discovered from ITMRP (admin approved).
  /// Checks for duplicate by name+team before inserting.
  Future<void> applyNewProduct(Map<String, dynamic> item) async {
    final name = item['itemName'] as String;
    final teamId = item['team_id'] as String? ?? AuthService.currentTeam;
    // Check if product already exists for this team
    final existing = await SupabaseService.instance.client
        .from('products')
        .select('id')
        .eq('name', name)
        .eq('team_id', teamId)
        .maybeSingle();
    if (existing != null) {
      debugPrint('StockSync: Product "$name" already exists in $teamId, skipping');
      return;
    }
    await SupabaseService.instance.addProduct({
      'name': name,
      'billing_name': name,
      'category': item['company'] as String,
      'unit_price': (item['rate'] as double?) ?? 0,
      'mrp': (item['mrp'] as double?) ?? 0,
      'stock_qty': item['qty'] as int? ?? 0,
      'team_id': teamId,
    });
  }

  /// Remove a pending change after it's applied or dismissed.
  Future<void> removePendingChange(String type, int index) async {
    final box = Hive.isBoxOpen(_stockPendingBoxName)
        ? Hive.box(_stockPendingBoxName)
        : await Hive.openBox(_stockPendingBoxName);
    final list = (box.get(type) as List?)
        ?.map((v) => Map<String, dynamic>.from(v as Map))
        .toList() ?? [];
    if (index >= 0 && index < list.length) {
      list.removeAt(index);
      await box.put(type, list);
    }
  }

  /// Clear all pending stock sync changes.
  Future<void> clearStockSyncPendingChanges() async {
    final box = Hive.isBoxOpen(_stockPendingBoxName)
        ? Hive.box(_stockPendingBoxName)
        : await Hive.openBox(_stockPendingBoxName);
    await box.clear();
  }

  // ─── ACMAST CUSTOMER SYNC ────────────────────────────────────────────────────

  bool _isCustomerSyncing = false;
  CustomerSyncResult? lastCustomerSyncResult;

  /// Sync customers from ACMAST CSV in Google Drive "data upload" folder.
  /// Only processes "Sundry Debtors". Detects new and changed customers.
  Future<CustomerSyncResult> syncCustomersFromDrive() async {
    if (_isCustomerSyncing) return CustomerSyncResult(error: 'Customer sync already in progress');
    _isCustomerSyncing = true;

    try {
      // Clear stale in-memory customer cache so we get fresh data from Supabase
      _syncCustomersCache = null;
      await _ensureFolderIds();
      final headers = await GoogleDriveAuthService.instance.authHeaders();
      if (headers.isEmpty) return CustomerSyncResult(error: 'Not signed in to Google Drive');

      if (dataUploadFolderId == null || dataUploadFolderId!.isEmpty) {
        return CustomerSyncResult(error: 'DRIVE_FOLDER_DATA_UPLOAD not set in env.json');
      }

      // 1. Find ACMAST*.csv files
      final acmastFiles = await _findFilesByPrefix(headers, dataUploadFolderId!, 'ACMAST');
      if (acmastFiles.isEmpty) {
        return CustomerSyncResult(error: 'No ACMAST*.csv files found');
      }

      // 2. Determine team from file suffix: <10 (07,08,09) = JA, >=10 (11,12,13) = MA

      // 3. Load all existing customers (cache-first)
      final customers = await _getCachedCustomers();
      // Build lookups: by acc_code per team, by name, by normalized name, and by GSTIN
      final Map<String, CustomerModel> accCodeJaLookup = {};
      final Map<String, CustomerModel> accCodeMaLookup = {};
      final Map<String, CustomerModel> nameLookup = {};
      final Map<String, CustomerModel> normalizedNameLookup = {};
      final Map<String, CustomerModel> gstinLookup = {};
      for (final c in customers) {
        if (c.accCodeJa != null && c.accCodeJa!.isNotEmpty) {
          accCodeJaLookup[c.accCodeJa!] = c;
        }
        if (c.accCodeMa != null && c.accCodeMa!.isNotEmpty) {
          accCodeMaLookup[c.accCodeMa!] = c;
        }
        nameLookup[c.name.toLowerCase().trim()] = c;
        normalizedNameLookup[_normalizeName(c.name)] = c;
        if (c.gstin != null && c.gstin!.isNotEmpty) {
          gstinLookup[c.gstin!.trim().toUpperCase()] = c;
        }
      }

      // Pre-load each team's beats once so the GROUP → beat lookup in the
      // existing-customer update path is O(1). Keyed by lowercased beat
      // name, matching how ACMAST's GROUP column is compared.
      final savedTeamForBeatLoad = AuthService.currentTeam;
      AuthService.currentTeam = 'JA';
      final jaBeats = await SupabaseService.instance.getBeats();
      AuthService.currentTeam = 'MA';
      final maBeats = await SupabaseService.instance.getBeats();
      AuthService.currentTeam = savedTeamForBeatLoad;
      final Map<String, BeatModel> jaBeatByName = {
        for (final b in jaBeats) b.beatName.toLowerCase().trim(): b,
      };
      final Map<String, BeatModel> maBeatByName = {
        for (final b in maBeats) b.beatName.toLowerCase().trim(): b,
      };

      // 4. Parse each ACMAST file with team tagging
      final List<Map<String, dynamic>> allDebtors = [];
      for (final file in acmastFiles) {
        final fileName = file['name'] ?? '';
        final fileTeam = _teamFromSuffix(fileName);
        debugPrint('📄 CustomerSync: Processing $fileName as team $fileTeam');

        final csvContent = await _downloadFile(headers, file['id']!);
        if (csvContent == null || csvContent.isEmpty) continue;

        final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
            .convert(csvContent);
        if (rows.isEmpty) continue;

        final rawHeaders = rows.first.map((h) {
          final s = h.toString().trim();
          if (s.contains(',')) return s.split(',').first.trim();
          return s;
        }).toList();

        final acCodeIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'ACCODE');
        final acNameIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'ACNAME');
        final addr1Idx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'ADDRESS1');
        final addr2Idx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'ADDRESS2');
        final phoneIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'PHONENO');
        final groupIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'GROUP');
        final amountIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'AMOUNT');
        final scheduleIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'SCHEDULE');
        final gstIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'GSTINNO');
        final cityIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'CITY');
        final lockBillIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'LOCKBILL');
        final creditDaysIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'CREDITDAYS');
        final credLimitIdx = rawHeaders.indexWhere((h) => h.toString().toUpperCase() == 'CREDLIMIT');

        if (acCodeIdx < 0 || acNameIdx < 0 || scheduleIdx < 0) {
          debugPrint('⚠️ CustomerSync: ${file['name']} missing required columns, skipping');
          continue;
        }

        for (int i = 1; i < rows.length; i++) {
          final row = rows[i];
          if (row.length <= scheduleIdx) continue;

          final schedule = row[scheduleIdx].toString().trim();
          if (schedule != 'Sundry Debtors') continue;

          final acCode = row[acCodeIdx].toString().trim();
          final acName = row[acNameIdx].toString().trim();
          if (acName.isEmpty) continue;

          String safeCol(int idx) => idx >= 0 && row.length > idx ? row[idx].toString().trim() : '';

          allDebtors.add({
            'acc_code': acCode,
            'team_id': fileTeam,
            'name': acName,
            'address': [safeCol(addr1Idx), safeCol(addr2Idx), safeCol(cityIdx)]
                .where((s) => s.isNotEmpty).join(', '),
            'phone': () {
              final raw = safeCol(phoneIdx).replaceAll(RegExp(r'[^0-9]'), '');
              final digits = raw.length > 10 ? raw.substring(raw.length - 10) : raw;
              return (digits.length == 10 && RegExp(r'^[6-9]').hasMatch(digits)) ? '+91$digits' : digits;
            }(),
            'group': safeCol(groupIdx),
            'amount': double.tryParse(safeCol(amountIdx)) ?? 0.0,
            'gstin': safeCol(gstIdx),
            'lock_bill': safeCol(lockBillIdx).toUpperCase() == 'Y',
            'credit_days': int.tryParse(safeCol(creditDaysIdx)) ?? 0,
            'credit_limit': double.tryParse(safeCol(credLimitIdx)) ?? 0.0,
          });
        }
        debugPrint('📊 CustomerSync: ${file['name']} — ${allDebtors.length} sundry debtors total');
      }

      // 5. Match, auto-apply (outstanding, GSTIN, acc_code), detect new/changed
      final List<Map<String, dynamic>> newCustomers = [];
      final List<Map<String, dynamic>> changedCustomers = [];
      final List<Map<String, dynamic>> accCodeMismatches = [];
      int matched = 0;
      int autoLinked = 0;
      int outstandingUpdated = 0;
      int gstinUpdated = 0;
      final dbClient = SupabaseService.instance.client;

      // Collect all updates first, then batch execute
      final pendingUpdates = <Future<void> Function()>[];

      for (final debtor in allDebtors) {
        final code = debtor['acc_code'] as String;
        final name = debtor['name'] as String;
        final team = debtor['team_id'] as String;
        final accCodeCol = team == 'JA' ? 'acc_code_ja' : 'acc_code_ma';
        final csvGstin = (debtor['gstin'] as String?)?.trim() ?? '';

        // Try match by team-specific acc_code first, then by name
        final accLookup = team == 'JA' ? accCodeJaLookup : accCodeMaLookup;
        CustomerModel? existing = accLookup[code];
        // If matched by acc_code, verify name is >=95% similar — reject if mismatch
        if (existing != null && _nameSimilarity(name, existing.name) < 0.95) {
          final similarity = (_nameSimilarity(name, existing.name) * 100).toStringAsFixed(0);
          debugPrint('⚠️ CustomerSync: acc_code "$code" matched "${existing.name}" but CSV name "$name" is only $similarity% similar — auto-clearing wrong acc_code & treating as new');
          accCodeMismatches.add({
            'acc_code': code,
            'csv_name': name,
            'db_name': existing.name,
            'db_id': existing.id,
            'team': team,
            'similarity': similarity,
          });
          // Auto-fix: clear the wrong acc_code from the wrongly-linked customer
          final wrongId = existing.id;
          final colToClear = accCodeCol;
          pendingUpdates.add(() => dbClient.from('customers').update({colToClear: null}).eq('id', wrongId));
          existing = null;
        }
        existing ??= nameLookup[name.toLowerCase().trim()];
        // Fallback: match by normalized name (handles dash/space/dot differences)
        existing ??= normalizedNameLookup[_normalizeName(name)];
        // Fallback: match by GSTIN (same business entity across teams)
        if (existing == null && csvGstin.isNotEmpty) {
          existing = gstinLookup[csvGstin.toUpperCase()];
          if (existing != null) {
            debugPrint('🔗 CustomerSync: Matched "$name" to "${existing.name}" via GSTIN $csvGstin');
          }
        }
        // Fallback: similarity search across all customers (catches minor spelling differences)
        if (existing == null) {
          for (final c in customers) {
            if (_nameSimilarity(name, c.name) >= 0.90) {
              debugPrint('🔗 CustomerSync: Matched "$name" to "${c.name}" via ${(_nameSimilarity(name, c.name) * 100).toStringAsFixed(0)}% similarity');
              existing = c;
              break;
            }
          }
        }

        if (existing == null) {
          newCustomers.add(debtor);
          continue;
        }

        matched++;

        // Consolidate all fields into a single update map
        final custUpdate = <String, dynamic>{};

        // acc_code — auto-link if name is >=90% similar OR matched via GSTIN
        final existingCode = team == 'JA' ? existing.accCodeJa : existing.accCodeMa;
        if (code.isNotEmpty && (existingCode == null || existingCode.isEmpty)) {
          final nameSim = _nameSimilarity(name, existing.name);
          final matchedViaGstin = csvGstin.isNotEmpty && existing.gstin != null && existing.gstin!.trim().toUpperCase() == csvGstin.toUpperCase();
          if (nameSim >= 0.90 || matchedViaGstin) {
            custUpdate[accCodeCol] = code;
            autoLinked++;
          } else {
            debugPrint('⚠️ CustomerSync: Skipped auto-link acc_code "$code" to "${existing.name}" — CSV name "$name" too different (${(nameSim * 100).toStringAsFixed(0)}%)');
          }
        }

        // Ensure team flag is set in customer_team_profiles
        if (!(team == 'JA' ? existing.belongsToTeam('JA') : existing.belongsToTeam('MA'))) {
          final teamCol = team == 'JA' ? 'team_ja' : 'team_ma';
          final custId = existing.id;
          pendingUpdates.add(() => dbClient.from('customer_team_profiles').upsert({
            'customer_id': custId, teamCol: true,
          }, onConflict: 'customer_id'));
          debugPrint('🔗 CustomerSync: Enabled $teamCol for "${existing.name}"');
        }

        // GSTIN
        if (csvGstin.isNotEmpty && (existing.gstin == null || existing.gstin!.isEmpty || existing.gstin != csvGstin)) {
          custUpdate['gstin'] = csvGstin;
          gstinUpdated++;
        }

        // lock_bill, credit_days, credit_limit
        final csvLockBill = debtor['lock_bill'] as bool? ?? false;
        final csvCreditDays = debtor['credit_days'] as int? ?? 0;
        final csvCreditLimit = (debtor['credit_limit'] as num?)?.toDouble() ?? 0.0;
        if (csvLockBill != existing.lockBill) custUpdate['lock_bill'] = csvLockBill;
        if (csvCreditDays != existing.creditDays) custUpdate['credit_days'] = csvCreditDays;
        if (csvCreditLimit != existing.creditLimit) custUpdate['credit_limit'] = csvCreditLimit;

        // address, phone
        final csvAddr = (debtor['address'] as String).trim();
        final csvPhone = (debtor['phone'] as String).trim();
        if (csvAddr.isNotEmpty && csvAddr != existing.address.trim()) custUpdate['address'] = csvAddr;
        if (csvPhone.isNotEmpty && csvPhone != existing.phone.trim()) custUpdate['phone'] = csvPhone;

        // Outstanding is now handled by BILLED_COLLECTED sync — not ACMAST

        if (custUpdate.isNotEmpty) {
          final id = existing.id;
          pendingUpdates.add(() => dbClient.from('customers').update(custUpdate).eq('id', id));
        }

        // Beat correction: ACMAST's GROUP is the authoritative
        // collection/billing beat for this team. Update customer_team_profiles
        // if it differs from current. This ONLY touches beat_id_<team> and
        // beat_name_<team> — order_beat_id_<team> (admin manual override)
        // is never read or written here, so manual splits are preserved
        // across syncs.
        final group = (debtor['group'] as String?)?.trim() ?? '';
        if (group.isNotEmpty) {
          final beatLookup = team == 'JA' ? jaBeatByName : maBeatByName;
          final targetBeat = beatLookup[group.toLowerCase()];
          if (targetBeat != null) {
            final currentBeatId = existing.beatIdForTeam(team);
            final currentBeatName = existing.beatNameForTeam(team);
            if (currentBeatId != targetBeat.id ||
                currentBeatName != targetBeat.beatName) {
              final custId = existing.id;
              final beatIdCol = team == 'JA' ? 'beat_id_ja' : 'beat_id_ma';
              final beatNameCol = team == 'JA' ? 'beat_name_ja' : 'beat_name_ma';
              pendingUpdates.add(() => dbClient.from('customer_team_profiles').upsert({
                    'customer_id': custId,
                    beatIdCol: targetBeat.id,
                    beatNameCol: targetBeat.beatName,
                  }, onConflict: 'customer_id'));
              debugPrint(
                '🗺️ CustomerSync: Beat updated for "${existing.name}" ($team) — "$currentBeatName" → "${targetBeat.beatName}"',
              );
            }
          }
        }
      }

      // Execute all updates in parallel batches of 20
      for (int i = 0; i < pendingUpdates.length; i += 10) {
        final chunk = pendingUpdates.sublist(i, (i + 10).clamp(0, pendingUpdates.length));
        try {
          await Future.wait(chunk.map((fn) => fn()));
        } catch (e) {
          debugPrint('⚠️ Sync batch ${i ~/ 10 + 1} failed: $e — continuing');
        }
      }
      debugPrint('📊 CustomerSync: ${pendingUpdates.length} customers updated in ${(pendingUpdates.length / 20).ceil()} batches');

      // Invalidate cache — always refresh after customer sync
      await SupabaseService.instance.invalidateCache('customers');

      // Only persist NEW customers to Hive (changed ones are auto-applied above)
      if (newCustomers.isNotEmpty) {
        await _saveCustomerSyncPendingChanges(newCustomers, []);
      }

      final result = CustomerSyncResult(
        totalDebtors: allDebtors.length,
        matched: matched,
        newCustomers: newCustomers,
        changedCustomers: changedCustomers,
        accCodeMismatches: accCodeMismatches,
      );
      lastCustomerSyncResult = result;
      if (accCodeMismatches.isNotEmpty) {
        debugPrint('🔴 CustomerSync: ${accCodeMismatches.length} ACC_CODE MISMATCHES FOUND & AUTO-FIXED:');
        for (final m in accCodeMismatches) {
          debugPrint('   acc_code=${m['acc_code']}: DB="${m['db_name']}" ≠ CSV="${m['csv_name']}" (${m['similarity']}% similar) — cleared from DB');
        }
      }
      debugPrint('✅ CustomerSync: Done — ${allDebtors.length} debtors, $matched matched, '
          '$autoLinked acc_codes linked, $outstandingUpdated outstanding updated, '
          '$gstinUpdated GSTIN updated, ${newCustomers.length} new, ${changedCustomers.length} changed');
      return result;
    } catch (e) {
      debugPrint('❌ CustomerSync error: $e');
      return CustomerSyncResult(error: e.toString());
    } finally {
      _isCustomerSyncing = false;
    }
  }

  // ─── CUSTOMER SYNC PENDING CHANGES (Hive) ──────────────────────────────────

  static const String _customerPendingBoxName = 'customer_sync_pending';

  Future<void> _saveCustomerSyncPendingChanges(
    List<Map<String, dynamic>> newCustomers,
    List<Map<String, dynamic>> changedCustomers,
  ) async {
    final box = Hive.isBoxOpen(_customerPendingBoxName)
        ? Hive.box(_customerPendingBoxName)
        : await Hive.openBox(_customerPendingBoxName);
    await box.clear();
    await box.put('new_customers', newCustomers);
    await box.put('changed_customers', changedCustomers);
    await box.put('timestamp', DateTime.now().millisecondsSinceEpoch);
  }

  Future<Map<String, dynamic>> getCustomerSyncPendingChanges() async {
    final box = Hive.isBoxOpen(_customerPendingBoxName)
        ? Hive.box(_customerPendingBoxName)
        : await Hive.openBox(_customerPendingBoxName);
    final rawNew = box.get('new_customers');
    final rawChanged = box.get('changed_customers');
    final newCusts = _hiveToListOfMaps(rawNew);
    final changedCusts = _hiveToListOfMaps(rawChanged);
    return {'new_customers': newCusts, 'changed_customers': changedCusts};
  }

  /// Apply a new customer from ACMAST (admin approved).
  /// Apply a new customer from ACMAST (admin approved).
  /// Checks for duplicate by name before inserting. Creates customer_team_profiles row.
  Future<void> applyNewCustomer(Map<String, dynamic> debtor) async {
    final team = debtor['team_id'] as String? ?? 'JA';
    final name = debtor['name'] as String;
    final client = SupabaseService.instance.client;

    // Check duplicate: first by team-specific acc_code, then by name
    final accCol = team == 'JA' ? 'acc_code_ja' : 'acc_code_ma';
    final accCode = debtor['acc_code'] as String? ?? '';

    // 1. Check if acc_code already linked to a customer for this team
    CustomerModel? existing;
    if (accCode.isNotEmpty) {
      final byCode = await client.from('customers')
          .select('id').eq(accCol, accCode).maybeSingle();
      if (byCode != null) {
        debugPrint('CustomerSync: "$name" acc_code $accCode already linked');
        return;
      }
    }

    // 2. Check by GSTIN (most reliable cross-team match)
    final csvGstin = (debtor['gstin'] as String?)?.trim() ?? '';
    if (csvGstin.isNotEmpty) {
      final byGstin = await client.from('customers')
          .select('id, name, customer_team_profiles(team_ja, team_ma)')
          .eq('gstin', csvGstin);
      for (final row in byGstin) {
        final profiles = row['customer_team_profiles'] as List? ?? [];
        final profile = profiles.isNotEmpty ? profiles.first : null;
        // Link acc_code and enable team regardless of name spelling
        await client.from('customers').update({accCol: accCode}).eq('id', row['id']);
        final teamCol = team == 'JA' ? 'team_ja' : 'team_ma';
        if (profile == null || (team == 'JA' ? profile['team_ja'] != true : profile['team_ma'] != true)) {
          await client.from('customer_team_profiles').upsert({
            'customer_id': row['id'], teamCol: true,
          }, onConflict: 'customer_id');
        }
        debugPrint('CustomerSync: "$name" matched "${row['name']}" via GSTIN $csvGstin, linked $accCol for $team');
        return;
      }
    }

    // 3. Check by name — but only match if customer belongs to this team
    final byName = await client.from('customers')
        .select('id, customer_team_profiles(team_ja, team_ma)')
        .eq('name', name);
    for (final row in byName) {
      final profiles = row['customer_team_profiles'] as List? ?? [];
      final profile = profiles.isNotEmpty ? profiles.first : null;
      final belongsToTeam = profile != null &&
          ((team == 'JA' && profile['team_ja'] == true) ||
           (team == 'MA' && profile['team_ma'] == true));
      if (belongsToTeam || profiles.isEmpty) {
        // Link acc_code to existing customer
        await client.from('customers').update({accCol: accCode}).eq('id', row['id']);
        // Ensure team profile exists
        if (profiles.isEmpty || !belongsToTeam) {
          final teamCol = team == 'JA' ? 'team_ja' : 'team_ma';
          await client.from('customer_team_profiles').upsert({
            'customer_id': row['id'], teamCol: true,
          }, onConflict: 'customer_id');
        }
        debugPrint('CustomerSync: "$name" exists for $team, linked $accCol');
        return;
      }
    }

    final custId = 'CUST-${DateTime.now().millisecondsSinceEpoch}';
    await client.from('customers').insert({
      'id': custId,
      'name': name,
      'address': debtor['address'] as String? ?? '',
      'phone': debtor['phone'] as String? ?? '',
      if (team == 'JA') 'acc_code_ja': debtor['acc_code'] as String?,
      if (team == 'MA') 'acc_code_ma': debtor['acc_code'] as String?,
      'type': 'General Trade',
      'last_order_value': 0,
      'delivery_route': 'Unassigned',
    });

    // Create customer_team_profiles row with beat assignment from ACMAST GROUP
    final group = (debtor['group'] as String?)?.trim() ?? '';
    String? beatId;
    String beatName = '';
    if (group.isNotEmpty) {
      // Try to match GROUP to a beat name
      final savedTeam = AuthService.currentTeam;
      AuthService.currentTeam = team;
      final beats = await SupabaseService.instance.getBeats();
      AuthService.currentTeam = savedTeam;
      final match = beats.where((b) => b.beatName.toLowerCase().trim() == group.toLowerCase().trim()).firstOrNull;
      if (match != null) { beatId = match.id; beatName = match.beatName; }
    }

    final beatIdCol = team == 'JA' ? 'beat_id_ja' : 'beat_id_ma';
    final beatNameCol = team == 'JA' ? 'beat_name_ja' : 'beat_name_ma';
    await client.from('customer_team_profiles').insert({
      'customer_id': custId,
      'team_ja': team == 'JA',
      'team_ma': team == 'MA',
      'outstanding_ja': 0,
      'outstanding_ma': 0,
      if (beatId != null) beatIdCol: beatId,
      if (beatName.isNotEmpty) beatNameCol: beatName,
    });
  }

  /// Apply changed customer data from ACMAST (admin approved).
  Future<void> applyCustomerChange(String customerId, Map<String, dynamic> changes) async {
    final data = <String, dynamic>{};
    for (final entry in changes.entries) {
      if (entry.key == 'acc_code') {
        data['acc_code'] = (entry.value as Map)['new'];
      } else {
        data[entry.key] = (entry.value as Map)['new'];
      }
    }
    if (data.isNotEmpty) {
      await SupabaseService.instance.client.from('customers').update(data).eq('id', customerId);
    }
  }

  Future<void> removeCustomerPendingChange(String type, int index) async {
    final box = Hive.isBoxOpen(_customerPendingBoxName)
        ? Hive.box(_customerPendingBoxName)
        : await Hive.openBox(_customerPendingBoxName);
    final list = (box.get(type) as List?)
        ?.map((v) => Map<String, dynamic>.from(v as Map)).toList() ?? [];
    if (index >= 0 && index < list.length) {
      list.removeAt(index);
      await box.put(type, list);
    }
  }

  Future<void> clearCustomerSyncPendingChanges() async {
    final box = Hive.isBoxOpen(_customerPendingBoxName)
        ? Hive.box(_customerPendingBoxName)
        : await Hive.openBox(_customerPendingBoxName);
    await box.clear();
  }

  // ─── OPNBIL (Outstanding Bills) SYNC ─────────────────────────────────────────

  bool _isOpnbilSyncing = false;

  /// Sync outstanding bills from OPNBIL CSV in Drive.
  /// Upserts into customer_bills table matched by acc_code per team.
  Future<void> syncOutstandingBillsFromDrive() async {
    if (_isOpnbilSyncing) return;
    _isOpnbilSyncing = true;
    try {
      await _ensureFolderIds();
      final headers = await GoogleDriveAuthService.instance.authHeaders();
      if (headers.isEmpty) return;
      if (dataUploadFolderId == null || dataUploadFolderId!.isEmpty) return;

      final files = await _findFilesByPrefix(headers, dataUploadFolderId!, 'OPNBIL');
      if (files.isEmpty) { debugPrint('⚠️ OPNBIL: No files found'); return; }

      // Build acc_code → customer_id lookup
      final customers = await _getCachedCustomers();
      final Map<String, String> jaLookup = {};
      final Map<String, String> maLookup = {};
      for (final c in customers) {
        if (c.accCodeJa != null && c.accCodeJa!.isNotEmpty) jaLookup[c.accCodeJa!] = c.id;
        if (c.accCodeMa != null && c.accCodeMa!.isNotEmpty) maLookup[c.accCodeMa!] = c.id;
      }

      final dbClient = SupabaseService.instance.client;
      int upserted = 0;
      final allBillRows = <Map<String, dynamic>>[];

      for (final file in files) {
        final fileName = file['name'] ?? '';
        final team = _teamFromSuffix(fileName);
        final lookup = team == 'JA' ? jaLookup : maLookup;
        debugPrint('📄 OPNBIL: Processing $fileName as $team');

        final csv = await _downloadFile(headers, file['id']!);
        if (csv == null || csv.isEmpty) continue;

        final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(csv);
        if (rows.isEmpty) continue;
        final hdr = _parseHeaders(rows.first);

        final acCodeI = hdr['ACCODE'] ?? -1;
        final invoiceI = hdr['INVOICENO'] ?? -1;
        final bookI = hdr['BOOK'] ?? -1;
        final dateI = hdr['DATE'] ?? -1;
        final billAmtI = hdr['BILLAMOUNT'] ?? -1;
        final amtI = hdr['AMOUNT'] ?? -1;
        final recdI = hdr['RECDAMOUNT'] ?? -1;
        final clearedI = hdr['CLEARED'] ?? -1;
        final creditDaysI = hdr['CREDITDAYS'] ?? -1;
        final smanNameI = hdr['SMANNAME'] ?? -1;

        if (acCodeI < 0 || invoiceI < 0) continue;

        for (int i = 1; i < rows.length; i++) {
          final row = rows[i];
          if (row.length <= acCodeI) continue;
          final acCode = row[acCodeI].toString().trim();
          final custId = lookup[acCode];
          if (custId == null) continue;

          final invoiceNo = _col(row, invoiceI);
          if (invoiceNo.isEmpty) continue;

          // AMOUNT = net bill (after scheme), BILLAMOUNT = gross (before scheme)
          // Use AMOUNT as bill_amount — matches billing software
          final netAmt = double.tryParse(_col(row, amtI)) ?? 0;
          final recdAmt = double.tryParse(_col(row, recdI)) ?? 0;
          final clearedFlag = _col(row, clearedI).toUpperCase();
          final isClearedBill = clearedFlag == 'Y' || clearedFlag == 'YES';
          final pendingAmt = isClearedBill ? 0.0 : (netAmt - recdAmt).clamp(0.0, double.infinity);

          allBillRows.add({
            'customer_id': custId,
            'acc_code': acCode,
            'invoice_no': invoiceNo,
            'book': _col(row, bookI),
            'bill_date': _parseDate(_col(row, dateI)),
            'bill_amount': netAmt,
            'pending_amount': pendingAmt,
            'received_amount': recdAmt,
            'cleared': isClearedBill,
            'credit_days': int.tryParse(_col(row, creditDaysI)) ?? 0,
            'sman_name': _col(row, smanNameI),
            'team_id': team,
            'synced_at': DateTime.now().toIso8601String(),
          });
        }
      }

      // Delete stale bills before fresh insert — bills cleared by cheques in
      // the billing software are removed from OPNBIL CSV, but upsert alone
      // never removes them from the database.
      final teamsInData = allBillRows.map((r) => r['team_id'] as String).toSet();
      for (final team in teamsInData) {
        await dbClient.from('customer_bills').delete().eq('team_id', team);
        debugPrint('🗑️ OPNBIL: Cleared old customer_bills for team $team');
      }

      // De-dup and batch insert fresh
      final deduped = _dedup(allBillRows, ['customer_id', 'invoice_no', 'book', 'team_id']);
      for (int i = 0; i < deduped.length; i += 50) {
        final chunk = deduped.sublist(i, (i + 50).clamp(0, deduped.length));
        await dbClient.from('customer_bills').upsert(chunk, onConflict: 'customer_id,invoice_no,book,team_id');
        upserted += chunk.length;
      }
      debugPrint('✅ OPNBIL: Done — $upserted bills upserted (${allBillRows.length} raw, ${deduped.length} deduped)');
      // Outstanding is now handled by BILLED_COLLECTED sync — not OPNBIL
    } catch (e) {
      debugPrint('❌ OPNBIL error: $e');
    } finally {
      _isOpnbilSyncing = false;
    }
  }

  // ─── INV (Invoice-level Outstanding) SYNC ──────────────────────────────────

  bool _isInvSyncing = false;

  /// Sync invoice-level bill data from INV CSV in Drive.
  /// This replaces OPNBIL as the source of truth for the Outstanding tab —
  /// INV has every invoice for the current year with BILLAMOUNT, RECDAMOUNT, CLEARED.
  Future<void> syncInvoicesFromDrive() async {
    if (_isInvSyncing) return;
    _isInvSyncing = true;
    try {
      await _ensureFolderIds();
      final headers = await GoogleDriveAuthService.instance.authHeaders();
      if (headers.isEmpty) return;
      if (dataUploadFolderId == null || dataUploadFolderId!.isEmpty) return;

      final files = await _findFilesByPrefix(headers, dataUploadFolderId!, 'INV');
      // Filter out INVOICE files — only want INV07.csv / INV11.csv pattern
      final invFiles = files.where((f) {
        final name = (f['name'] ?? '').toUpperCase();
        return name.startsWith('INV') && !name.startsWith('INVOICE');
      }).toList();
      if (invFiles.isEmpty) { debugPrint('⚠️ INV: No INV files found'); return; }

      final customers = await _getCachedCustomers();
      final Map<String, String> jaLookup = {};
      final Map<String, String> maLookup = {};
      for (final c in customers) {
        if (c.accCodeJa != null && c.accCodeJa!.isNotEmpty) jaLookup[c.accCodeJa!] = c.id;
        if (c.accCodeMa != null && c.accCodeMa!.isNotEmpty) maLookup[c.accCodeMa!] = c.id;
      }

      final dbClient = SupabaseService.instance.client;
      int upserted = 0;
      final allBillRows = <Map<String, dynamic>>[];

      for (final file in invFiles) {
        final fileName = file['name'] ?? '';
        final team = _teamFromSuffix(fileName);
        final lookup = team == 'JA' ? jaLookup : maLookup;
        debugPrint('📄 INV: Processing $fileName as $team');

        final csv = await _downloadFile(headers, file['id']!);
        if (csv == null || csv.isEmpty) continue;

        final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(csv);
        if (rows.isEmpty) continue;
        final hdr = _parseHeaders(rows.first);

        final acCodeI = hdr['ACCODE'] ?? -1;
        final bookI = hdr['BOOK'] ?? -1;
        final invoiceI = hdr['INVOICENO'] ?? -1;
        final dateI = hdr['DATE'] ?? -1;
        final billAmtI = hdr['BILLAMOUNT'] ?? -1;
        final netAmtI = hdr['NETAMOUNT'] ?? -1;
        final recdI = hdr['RECDAMOUNT'] ?? -1;
        final clearedI = hdr['CLEARED'] ?? -1;
        final creditDaysI = hdr['CREDITDAYS'] ?? -1;
        final displayI = hdr['DISPLAY'] ?? -1;
        final smanNameI = hdr['SMANNAME'] ?? -1;

        if (acCodeI < 0 || invoiceI < 0) continue;

        for (int i = 1; i < rows.length; i++) {
          final row = rows[i];
          if (row.length <= acCodeI) continue;
          final acCode = row[acCodeI].toString().trim();
          final custId = lookup[acCode];
          if (custId == null) continue;

          final invoiceNo = _col(row, invoiceI);
          if (invoiceNo.isEmpty) continue;

          final billAmt = double.tryParse(_col(row, billAmtI)) ?? 0;
          final recdAmt = double.tryParse(_col(row, recdI)) ?? 0;
          final clearedFlag = _col(row, clearedI).toUpperCase();
          final isClearedBill = clearedFlag == 'Y' || clearedFlag == 'YES';
          final pendingAmt = isClearedBill ? 0.0 : (billAmt - recdAmt).clamp(0.0, double.infinity);

          allBillRows.add({
            'customer_id': custId,
            'acc_code': acCode,
            'invoice_no': invoiceNo,
            'book': _col(row, bookI),
            'bill_date': _parseDate(_col(row, dateI)),
            'bill_amount': billAmt,
            'pending_amount': pendingAmt,
            'received_amount': recdAmt,
            'cleared': isClearedBill,
            'credit_days': int.tryParse(_col(row, creditDaysI)) ?? 0,
            'sman_name': _col(row, smanNameI),
            'team_id': team,
            'synced_at': DateTime.now().toIso8601String(),
          });
        }
        debugPrint('📊 INV: $fileName — ${rows.length - 1} rows parsed');
      }

      // De-dup and batch upsert into customer_bills (same table as OPNBIL)
      final deduped = _dedup(allBillRows, ['customer_id', 'invoice_no', 'book', 'team_id']);
      for (int i = 0; i < deduped.length; i += 50) {
        final chunk = deduped.sublist(i, (i + 50).clamp(0, deduped.length));
        await dbClient.from('customer_bills').upsert(chunk, onConflict: 'customer_id,invoice_no,book,team_id');
        upserted += chunk.length;
      }
      debugPrint('✅ INV: Done — $upserted bills upserted (${allBillRows.length} raw, ${deduped.length} deduped)');
    } catch (e) {
      debugPrint('❌ INV error: $e');
    } finally {
      _isInvSyncing = false;
    }
  }

  // ─── BILLED_COLLECTED (Customer Outstanding Summary) SYNC ─────────────────

  bool _isBilledCollectedSyncing = false;

  /// Sync customer outstanding totals from BILLED_COLLECTED CSV.
  /// This is the source of truth for customer outstanding — writes CLOSING_BALANCE
  /// to customer_team_profiles.outstanding_ja/ma.
  Future<void> syncBilledCollectedFromDrive() async {
    if (_isBilledCollectedSyncing) return;
    _isBilledCollectedSyncing = true;
    try {
      await _ensureFolderIds();
      final headers = await GoogleDriveAuthService.instance.authHeaders();
      if (headers.isEmpty) return;
      if (dataUploadFolderId == null || dataUploadFolderId!.isEmpty) return;

      final files = await _findFilesByPrefix(headers, dataUploadFolderId!, 'BILLED_COLLECTED');
      if (files.isEmpty) { debugPrint('⚠️ BILLED_COLLECTED: No files found'); return; }

      final customers = await _getCachedCustomers();
      final Map<String, String> jaLookup = {};
      final Map<String, String> maLookup = {};
      for (final c in customers) {
        if (c.accCodeJa != null && c.accCodeJa!.isNotEmpty) jaLookup[c.accCodeJa!] = c.id;
        if (c.accCodeMa != null && c.accCodeMa!.isNotEmpty) maLookup[c.accCodeMa!] = c.id;
      }

      final dbClient = SupabaseService.instance.client;
      int updated = 0;

      // Track which teams we've reset so we only reset once per team
      final teamsReset = <String>{};

      for (final file in files) {
        final fileName = file['name'] ?? '';
        final team = _teamFromSuffix(fileName);
        final lookup = team == 'JA' ? jaLookup : maLookup;
        final outCol = team == 'JA' ? 'outstanding_ja' : 'outstanding_ma';
        debugPrint('📄 BILLED_COLLECTED: Processing $fileName as $team');

        // Reset all customers' outstanding to 0 for this team (once per team)
        // Customers in the file will get their real balance; others stay at 0
        if (!teamsReset.contains(team)) {
          await dbClient.from('customer_team_profiles')
              .update({outCol: 0})
              .neq(outCol, 0);
          teamsReset.add(team);
          debugPrint('📊 BILLED_COLLECTED: Reset $outCol to 0 for all customers');
        }

        final csv = await _downloadFile(headers, file['id']!);
        if (csv == null || csv.isEmpty) continue;

        final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(csv);
        if (rows.isEmpty) continue;
        final hdr = _parseHeaders(rows.first);

        final acCodeI = hdr['ACCODE'] ?? -1;
        final closingI = hdr['CLOSING_BALANCE'] ?? -1;
        final creditNotesI = hdr['CREDIT_NOTES'] ?? -1;
        final currentYearBilledI = hdr['CURRENT_YEAR_BILLED'] ?? -1;

        if (acCodeI < 0 || closingI < 0) {
          debugPrint('⚠️ BILLED_COLLECTED: $fileName missing ACCODE/CLOSING_BALANCE columns');
          continue;
        }

        final crNotesCol = team == 'JA' ? 'credit_notes_ja' : 'credit_notes_ma';
        final yrBilledCol = team == 'JA' ? 'current_year_billed_ja' : 'current_year_billed_ma';

        // Collect all updates first
        final updates = <Map<String, dynamic>>[];
        for (int i = 1; i < rows.length; i++) {
          final row = rows[i];
          if (row.length <= acCodeI) continue;
          final acCode = row[acCodeI].toString().trim();
          final custId = lookup[acCode];
          if (custId == null) continue;

          final closingBalance = double.tryParse(_col(row, closingI)) ?? 0;
          final creditNotes = creditNotesI >= 0 ? (double.tryParse(_col(row, creditNotesI)) ?? 0) : 0.0;
          final currentYearBilled = currentYearBilledI >= 0 ? (double.tryParse(_col(row, currentYearBilledI)) ?? 0) : 0.0;
          updates.add({
            'customer_id': custId,
            outCol: closingBalance,
            crNotesCol: creditNotes,
            yrBilledCol: currentYearBilled,
          });
        }
        debugPrint('📊 BILLED_COLLECTED: $fileName — ${updates.length} matched customers');

        // Batch update: 20 concurrent requests at a time
        for (int i = 0; i < updates.length; i += 10) {
          final chunk = updates.sublist(i, (i + 10).clamp(0, updates.length));
          try {
            await Future.wait(chunk.map((u) =>
              dbClient.from('customer_team_profiles')
                  .update({
                    outCol: u[outCol],
                    crNotesCol: u[crNotesCol],
                    yrBilledCol: u[yrBilledCol],
                  })
                  .eq('customer_id', u['customer_id'])
            ));
            updated += chunk.length;
          } catch (e) {
            debugPrint('⚠️ Sync batch ${i ~/ 10 + 1} failed: $e — continuing');
          }
        }
      }

      if (updated > 0) {
        await SupabaseService.instance.invalidateCache('customers');
      }
      debugPrint('✅ BILLED_COLLECTED: Done — $updated customers updated');
    } catch (e) {
      debugPrint('❌ BILLED_COLLECTED error: $e');
    } finally {
      _isBilledCollectedSyncing = false;
    }
  }

  // ─── RECT (Receipts) + RCTBIL (Receipt Bill Details) SYNC ──────────────────

  bool _isReceiptSyncing = false;

  /// Sync receipts from RECT + RCTBIL CSV in Drive.
  Future<void> syncReceiptsFromDrive() async {
    if (_isReceiptSyncing) return;
    _isReceiptSyncing = true;
    try {
      await _ensureFolderIds();
      final headers = await GoogleDriveAuthService.instance.authHeaders();
      if (headers.isEmpty) return;
      if (dataUploadFolderId == null || dataUploadFolderId!.isEmpty) return;

      // Build acc_code → customer_id lookup
      final customers = await _getCachedCustomers();
      final Map<String, String> jaLookup = {};
      final Map<String, String> maLookup = {};
      for (final c in customers) {
        if (c.accCodeJa != null && c.accCodeJa!.isNotEmpty) jaLookup[c.accCodeJa!] = c.id;
        if (c.accCodeMa != null && c.accCodeMa!.isNotEmpty) maLookup[c.accCodeMa!] = c.id;
      }

      final dbClient = SupabaseService.instance.client;

      // ── RECT (Receipt headers) ──
      final rectFiles = await _findFilesByPrefix(headers, dataUploadFolderId!, 'RECT');
      int receiptsUpserted = 0;
      for (final file in rectFiles) {
        // Skip RCTBIL files
        if ((file['name'] ?? '').toString().toUpperCase().contains('RCTBIL')) continue;

        final fileName = file['name'] ?? '';
        final team = _teamFromSuffix(fileName);
        final lookup = team == 'JA' ? jaLookup : maLookup;
        debugPrint('📄 RECT: Processing $fileName as $team');

        final csv = await _downloadFile(headers, file['id']!);
        if (csv == null || csv.isEmpty) continue;

        final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(csv);
        if (rows.isEmpty) continue;
        final hdr = _parseHeaders(rows.first);

        final dateI = hdr['DATE'] ?? -1;
        final acCodeI = hdr['ACCODE'] ?? -1;
        final amtI = hdr['AMOUNT'] ?? -1;
        final bankI = hdr['BANKNAME'] ?? -1;
        final receiptNoI = hdr['RECEIPTNO'] ?? -1;
        final cashI = hdr['CASHYN'] ?? -1;
        final rectvnoI = hdr['RECTVNO'] ?? -1;

        if (acCodeI < 0 || dateI < 0) continue;

        final batch = <Map<String, dynamic>>[];
        for (int i = 1; i < rows.length; i++) {
          final row = rows[i];
          if (row.length <= acCodeI) continue;
          final acCode = row[acCodeI].toString().trim();
          final custId = lookup[acCode];
          if (custId == null) continue;

          final receiptNo = _col(row, rectvnoI).isNotEmpty ? _col(row, rectvnoI) : _col(row, receiptNoI);
          final dateStr = _col(row, dateI);
          if (dateStr.isEmpty) continue;

          batch.add({
            'customer_id': custId,
            'acc_code': acCode,
            'receipt_date': _parseDate(dateStr),
            'amount': double.tryParse(_col(row, amtI)) ?? 0,
            'bank_name': _col(row, bankI),
            'receipt_no': receiptNo,
            'cash_yn': _col(row, cashI).toUpperCase() == 'Y',
            'team_id': team,
            'synced_at': DateTime.now().toIso8601String(),
          });

          if (batch.length >= 100) {
            await dbClient.from('customer_receipts').upsert(batch, onConflict: 'receipt_no,receipt_date,team_id');
            receiptsUpserted += batch.length;
            batch.clear();
          }
        }
        if (batch.isNotEmpty) {
          await dbClient.from('customer_receipts').upsert(batch, onConflict: 'receipt_no,receipt_date,team_id');
          receiptsUpserted += batch.length;
        }
      }
      debugPrint('✅ RECT: Done — $receiptsUpserted receipts upserted');

      // ── RCTBIL (Receipt bill breakdown) ──
      final rctbilFiles = await _findFilesByPrefix(headers, dataUploadFolderId!, 'RCTBIL');
      int billsUpserted = 0;
      for (final file in rctbilFiles) {
        final fileName = file['name'] ?? '';
        final team = _teamFromSuffix(fileName);
        debugPrint('📄 RCTBIL: Processing $fileName as $team');

        final csv = await _downloadFile(headers, file['id']!);
        if (csv == null || csv.isEmpty) continue;

        final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(csv);
        if (rows.isEmpty) continue;
        final hdr = _parseHeaders(rows.first);

        final dateI = hdr['DATE'] ?? -1;
        final rectvnoI = hdr['RECTVNO'] ?? -1;
        final invoiceI = hdr['INVOICENO'] ?? -1;
        final billDateI = hdr['BILLDATE'] ?? -1;
        final billAmtI = hdr['BILLAMT'] ?? -1;
        final amtI = hdr['AMOUNT'] ?? -1;
        final discI = hdr['DISCOUNT'] ?? -1;
        final retI = hdr['RETAMOUNT'] ?? -1;
        final schemeI = hdr['SCHEMEAMT'] ?? -1;

        if (rectvnoI < 0 || invoiceI < 0) continue;

        final batch = <Map<String, dynamic>>[];
        for (int i = 1; i < rows.length; i++) {
          final row = rows[i];
          if (row.length <= invoiceI) continue;
          final invoiceNo = _col(row, invoiceI);
          if (invoiceNo.isEmpty) continue;

          batch.add({
            'receipt_date': _parseDate(_col(row, dateI)),
            'receipt_no': _col(row, rectvnoI),
            'invoice_no': invoiceNo,
            'bill_date': _parseDate(_col(row, billDateI)),
            'bill_amount': double.tryParse(_col(row, billAmtI)) ?? 0,
            'paid_amount': double.tryParse(_col(row, amtI)) ?? 0,
            'discount': double.tryParse(_col(row, discI)) ?? 0,
            'return_amount': double.tryParse(_col(row, retI)) ?? 0,
            'scheme_amount': double.tryParse(_col(row, schemeI)) ?? 0,
            'team_id': team,
            'synced_at': DateTime.now().toIso8601String(),
          });

          if (batch.length >= 100) {
            await dbClient.from('customer_receipt_bills').upsert(batch, onConflict: 'receipt_no,invoice_no,receipt_date,team_id');
            billsUpserted += batch.length;
            batch.clear();
          }
        }
        if (batch.isNotEmpty) {
          await dbClient.from('customer_receipt_bills').upsert(batch, onConflict: 'receipt_no,invoice_no,receipt_date,team_id');
          billsUpserted += batch.length;
        }
      }
      debugPrint('✅ RCTBIL: Done — $billsUpserted receipt bills upserted');
    } catch (e) {
      debugPrint('❌ Receipt sync error: $e');
    } finally {
      _isReceiptSyncing = false;
    }
  }


  // ─── SHARED CSV HELPERS ─────────────────────────────────────────────────────

  /// De-duplicate a list of maps by a composite key (list of field names).
  /// Keeps the last occurrence of each duplicate.
  List<Map<String, dynamic>> _dedup(List<Map<String, dynamic>> rows, List<String> keyFields) {
    final seen = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final key = keyFields.map((f) => (row[f] ?? '').toString()).join('|');
      seen[key] = row;
    }
    return seen.values.toList();
  }

  /// Parse dBASE CSV headers into uppercase name → index map.
  Map<String, int> _parseHeaders(List<dynamic> headerRow) {
    final map = <String, int>{};
    for (int i = 0; i < headerRow.length; i++) {
      final s = headerRow[i].toString().trim();
      final name = s.contains(',') ? s.split(',').first.trim() : s;
      map[name.toUpperCase()] = i;
    }
    return map;
  }

  /// Safe column access — returns trimmed string or empty.
  String _col(List<dynamic> row, int idx) =>
      idx >= 0 && row.length > idx ? row[idx].toString().trim() : '';

  /// Parse date from DD/MM/YYYY, DD-MM-YYYY, or YYYY-MM-DD format to ISO string.
  String? _parseDate(String dateStr) {
    if (dateStr.isEmpty) return null;
    // DD/MM/YYYY
    if (dateStr.contains('/')) {
      final parts = dateStr.split('/');
      if (parts.length == 3) {
        return '${parts[2]}-${parts[1].padLeft(2, "0")}-${parts[0].padLeft(2, "0")}';
      }
    }
    if (dateStr.contains('-')) {
      final parts = dateStr.split('-');
      if (parts.length == 3) {
        // DD-MM-YYYY (first part ≤ 2 digits = day)
        if (parts[0].length <= 2) {
          return '${parts[2]}-${parts[1].padLeft(2, "0")}-${parts[0].padLeft(2, "0")}';
        }
        // Already YYYY-MM-DD
        return '${parts[0]}-${parts[1].padLeft(2, "0")}-${parts[2].padLeft(2, "0")}';
      }
    }
    return null;
  }

  // ─── ITTR PER-CUSTOMER BILLED ITEMS SYNC ─────────────────────────────────────

  bool _isBilledItemsSyncing = false;

  /// Parse ITTR CSV and store per-customer billed items in customer_billed_items table.
  /// Separate from bill verification — this powers the "Billed" tab in customer details.
  Future<void> syncBilledItemsFromDrive() async {
    if (_isBilledItemsSyncing) return;
    _isBilledItemsSyncing = true;
    try {
      await _ensureFolderIds();
      final headers = await GoogleDriveAuthService.instance.authHeaders();
      if (headers.isEmpty) return;
      if (dataUploadFolderId == null || dataUploadFolderId!.isEmpty) return;

      final ittrFiles = await _findFilesByPrefix(headers, dataUploadFolderId!, 'ITTR');
      if (ittrFiles.isEmpty) { debugPrint('⚠️ BilledItems: No ITTR files found'); return; }

      // Build ACNAME → customer_id lookup
      final customers = await _getCachedCustomers();
      final Map<String, String> nameLookup = {};
      for (final c in customers) {
        nameLookup[c.name.toLowerCase().trim()] = c.id;
      }

      final dbClient = SupabaseService.instance.client;
      int upserted = 0;
      final allItemRows = <Map<String, dynamic>>[];
      // Collect GST rates per item name (lowercase) → gst% (VATPER + SATPER)
      // Latest occurrence wins (most recent bill has the current rate)
      final Map<String, double> itemGstRates = {};

      for (final file in ittrFiles) {
        final fileName = file['name'] ?? '';
        final team = _teamFromSuffix(fileName);
        debugPrint('📄 BilledItems: Processing $fileName as $team');

        final csv = await _downloadFile(headers, file['id']!);
        if (csv == null || csv.isEmpty) continue;

        final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(csv);
        if (rows.isEmpty) continue;
        final hdr = _parseHeaders(rows.first);

        final dateI = hdr['DATE'] ?? -1;
        final acNameI = hdr['ACNAME'] ?? -1;
        final itemNameI = hdr['ITEMNAME'] ?? -1;
        final packingI = hdr['PACKING'] ?? -1;
        final companyI = hdr['COMPANY'] ?? -1;
        final qtyI = hdr['QUANTITY'] ?? -1;
        final mrpI = hdr['MRP'] ?? -1;
        final rateI = hdr['RATE'] ?? -1;
        final amountI = hdr['AMOUNT'] ?? -1;
        final discount1I = hdr['DISCOUNT1'] ?? -1;
        final discount2I = hdr['DISCOUNT2'] ?? -1;
        final vatAmountI = hdr['VATAMOUNT'] ?? -1;  // SGST amount
        final satAmountI = hdr['SATAMOUNT'] ?? -1;  // CGST amount
        final billNoI = hdr['BILLNO'] ?? -1;
        final billDateI = hdr['BILLDATE'] ?? -1;
        final bookI = hdr['BOOK'] ?? -1;
        final vnoI = hdr['VNO'] ?? -1;
        final vatPerI = hdr['VATPER'] ?? -1;   // CGST %
        final satPerI = hdr['SATPER'] ?? -1;   // SGST %

        if (itemNameI < 0 || acNameI < 0) continue;

        for (int i = 1; i < rows.length; i++) {
          final row = rows[i];
          if (row.length <= acNameI) continue;

          final acName = _col(row, acNameI);
          final itemName = _col(row, itemNameI);
          if (acName.isEmpty || itemName.isEmpty) continue;

          final custId = nameLookup[acName.toLowerCase().trim()];

          // Build invoice number: BILLNO if present, else BOOK+VNO
          var invoiceNo = _col(row, billNoI);
          if (invoiceNo.isEmpty) {
            final book = _col(row, bookI);
            final vno = _col(row, vnoI);
            invoiceNo = '$book$vno';
          }
          if (invoiceNo.isEmpty) continue;

          // Parse date: prefer BILLDATE, fall back to DATE
          final billDateStr = _col(row, billDateI);
          final dateStr = _col(row, dateI);
          final parsedDate = _parseDate(billDateStr.isNotEmpty ? billDateStr : dateStr);

          // Extract GST rate: VATPER (CGST%) + SATPER (SGST%)
          final vatPer = double.tryParse(_col(row, vatPerI)) ?? 0;
          final satPer = double.tryParse(_col(row, satPerI)) ?? 0;
          final gstPer = vatPer + satPer;
          if (gstPer > 0) {
            itemGstRates[itemName.toLowerCase().trim()] = gstPer;
          }

          // Calculate net amount: AMOUNT - DISCOUNT1 - DISCOUNT2 + VATAMOUNT + SATAMOUNT
          final grossAmt = double.tryParse(_col(row, amountI)) ?? 0;
          final disc1 = double.tryParse(_col(row, discount1I)) ?? 0;
          final disc2 = double.tryParse(_col(row, discount2I)) ?? 0;
          final vatAmt = double.tryParse(_col(row, vatAmountI)) ?? 0;
          final satAmt = double.tryParse(_col(row, satAmountI)) ?? 0;
          final netAmt = grossAmt - disc1 - disc2 + vatAmt + satAmt;

          allItemRows.add({
            if (custId != null) 'customer_id': custId,
            'acc_name': acName,
            'bill_date': parsedDate,
            'invoice_no': invoiceNo,
            'item_name': itemName,
            'packing': _col(row, packingI),
            'company': _col(row, companyI),
            'quantity': int.tryParse(_col(row, qtyI).split('.').first) ?? 0,
            'mrp': double.tryParse(_col(row, mrpI)) ?? 0,
            'rate': double.tryParse(_col(row, rateI)) ?? 0,
            'amount': netAmt,
            'team_id': team,
            'synced_at': DateTime.now().toIso8601String(),
          });

        }
        debugPrint('📊 BilledItems: $fileName — ${rows.length - 1} rows parsed');
      }

      // De-dup and batch upsert
      final deduped = _dedup(allItemRows, ['invoice_no', 'item_name', 'bill_date', 'team_id']);
      for (int i = 0; i < deduped.length; i += 50) {
        final chunk = deduped.sublist(i, (i + 50).clamp(0, deduped.length));
        await dbClient.from('customer_billed_items').upsert(chunk, onConflict: 'invoice_no,item_name,bill_date,team_id');
        upserted += chunk.length;
      }
      debugPrint('✅ BilledItems: Done — $upserted items upserted (${allItemRows.length} raw, ${deduped.length} deduped)');

      // Auto-update product GST rates from ITTR data
      if (itemGstRates.isNotEmpty) {
        final allProducts = await _getCachedAllProducts();
        int gstUpdated = 0;
        for (final p in allProducts) {
          final key = (p.billingName ?? p.name).toLowerCase().trim();
          final csvGst = itemGstRates[key] ?? itemGstRates[p.name.toLowerCase().trim()];
          if (csvGst == null) continue;
          // DB stores as integer percent (18, 5, 12); model parses to decimal
          final currentGstInt = (p.gstRate * 100).round();
          final csvGstInt = csvGst.round();
          if (currentGstInt != csvGstInt) {
            try {
              await SupabaseService.instance.updateProduct(p.id, {'gst_rate': csvGstInt});
              gstUpdated++;
            } catch (e) {
              debugPrint('⚠️ BilledItems: GST update failed for ${p.name}: $e');
            }
          }
        }
        if (gstUpdated > 0) {
          await SupabaseService.instance.invalidateCache('products');
          debugPrint('✅ BilledItems: GST rate updated for $gstUpdated products');
        }
      }
    } catch (e) {
      debugPrint('❌ BilledItems error: $e');
    } finally {
      _isBilledItemsSyncing = false;
    }
  }

  /// Safely convert Hive-stored data to List<Map<String, dynamic>>.
  /// Hive can return List, Map, or null depending on how data was serialized.
  List<Map<String, dynamic>> _hiveToListOfMaps(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) {
      return raw.map((v) => Map<String, dynamic>.from(v as Map)).toList();
    }
    if (raw is Map) {
      return [Map<String, dynamic>.from(raw)];
    }
    return [];
  }

  /// Normalize name for comparison: lowercase, strip dots, collapse spaces/dashes.
  String _normalizeName(String name) {
    return name
        .toLowerCase()
        .replaceAll('.', '')        // P.R. → PR
        .replaceAll(RegExp(r'-\s*$'), '')  // trailing dash "SUNIL UNCLE -" → "SUNIL UNCLE"
        .replaceAll('-', ' ')       // G-MART → G MART
        .replaceAll(RegExp(r'\s+'), ' ')  // collapse multiple spaces
        .trim();
  }

  /// Levenshtein-based name similarity (0.0 to 1.0).
  /// Normalizes names first (strips dots, dashes, extra spaces).
  double _nameSimilarity(String a, String b) {
    final s1 = _normalizeName(a);
    final s2 = _normalizeName(b);
    if (s1 == s2) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    final maxLen = s1.length > s2.length ? s1.length : s2.length;
    // Levenshtein distance
    final prev = List<int>.generate(s2.length + 1, (i) => i);
    final curr = List<int>.filled(s2.length + 1, 0);
    for (int i = 1; i <= s1.length; i++) {
      curr[0] = i;
      for (int j = 1; j <= s2.length; j++) {
        final cost = s1[i - 1] == s2[j - 1] ? 0 : 1;
        curr[j] = [curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost].reduce((a, b) => a < b ? a : b);
      }
      for (int j = 0; j <= s2.length; j++) prev[j] = curr[j];
    }
    return 1.0 - (prev[s2.length] / maxLen);
  }

  /// Determine team from filename suffix: <10 (07,08,09) = JA, >=10 (11,12,13) = MA.
  /// Determine team from filename suffix.
  /// JA files: 07, 08, 09 (single-digit range, < 10)
  /// MA files: 11, 12, 13 (double-digit range, >= 10)
  String _teamFromSuffix(String filename) {
    // Extract the numeric suffix just before the file extension
    // e.g. BILLED_COLLECTED207.csv → 207 → last 2 digits → 07
    // ITMRP07.csv → 07, ITTR11.csv → 11
    final noExt = filename.split('.').first; // remove .csv
    final match = RegExp(r'(\d+)$').firstMatch(noExt);
    if (match == null) return 'JA';
    final suffix = match.group(1)!;
    // Take last 2 digits as the team suffix (07, 08, 09 = JA; 11, 12, 13 = MA)
    final teamDigits = suffix.length > 2 ? suffix.substring(suffix.length - 2) : suffix;
    final n = int.tryParse(teamDigits) ?? 7;
    return n < 10 ? 'JA' : 'MA';
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

      // 4. Process changes — auto-verify matching, skip new bills (shown in Billed tab)
      int applied = 0;
      final List<Map<String, dynamic>> discrepancies = [];

      if (changes.isNotEmpty) {
        final autoApplyable = changes.where((c) => c['type'] == 'can_auto_verify').toList();
        // new_bill = ITTR bills not in app orders — these are office-billed,
        // already visible in customer Billed tab via customer_billed_items. Skip.
        final otherChanges = changes.where((c) =>
            c['type'] != 'can_auto_verify' && c['type'] != 'new_bill').toList();

        if (autoApplyable.isNotEmpty) {
          applied = await CsvReconciliationService.instance.applyChanges(autoApplyable);
          debugPrint('✅ BillSync: Auto-verified $applied bills');
        }

        // Only store real discrepancies (item/amount mismatches)
        discrepancies.addAll(otherChanges);
        if (discrepancies.isNotEmpty) {
          await _saveDriveDiscrepancies(discrepancies);
          debugPrint('📋 BillSync: Saved ${discrepancies.length} discrepancies for review');
        } else {
          await clearDriveDiscrepancies();
        }
      }

      if (applied > 0) {
        await SupabaseService.instance.invalidateCache('recent_orders');
      }

      final newBillCount = changes.where((c) => c['type'] == 'new_bill').length;
      final result = BillSyncResult(
        totalBills: allBills.length,
        differences: changes.length,
        applied: applied,
        discrepancies: discrepancies.length,
        changes: changes,
      );
      lastBillSyncResult = result;
      debugPrint('✅ BillSync: Done — ${allBills.length} bills, $applied auto-verified, '
          '$newBillCount office-only (in Billed tab), ${discrepancies.length} need review');
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
        if (files.isNotEmpty) return files.first['id'] as String?;
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
      } else if (resp.statusCode == 401) {
        await GoogleDriveAuthService.instance.signOut();
        authError.value = 'Google Drive session expired. Please re-login to Google Drive in Settings.';
        return results;
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
      if (resp.statusCode == 401) {
        await GoogleDriveAuthService.instance.signOut();
        authError.value = 'Google Drive session expired. Please re-login to Google Drive in Settings.';
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

  /// New products found in existing categories (pending admin approval)
  final List<Map<String, dynamic>> newProducts;

  /// Price changes detected (unit_price from RATE column, pending admin verification)
  final List<Map<String, dynamic>> priceChanges;

  /// MRP changes detected (auto-applied)
  final int mrpUpdated;

  StockSyncResult({
    this.matched = 0,
    this.unmatched = 0,
    this.updated = 0,
    this.skipped = 0,
    this.unmatchedNames = const [],
    this.error,
    this.newProducts = const [],
    this.priceChanges = const [],
    this.mrpUpdated = 0,
  });

  bool get hasError => error != null;

  /// Whether there are pending changes needing admin review in Data Changes tab
  bool get hasPendingChanges => newProducts.isNotEmpty || priceChanges.isNotEmpty;
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

/// Result of a customer (ACMAST) sync operation.
class CustomerSyncResult {
  final int totalDebtors;
  final int matched;
  final List<Map<String, dynamic>> newCustomers;
  final List<Map<String, dynamic>> changedCustomers;
  final List<Map<String, dynamic>> accCodeMismatches;
  final String? error;

  CustomerSyncResult({
    this.totalDebtors = 0,
    this.matched = 0,
    this.newCustomers = const [],
    this.changedCustomers = const [],
    this.accCodeMismatches = const [],
    this.error,
  });

  bool get hasError => error != null;
  bool get hasPendingChanges => newCustomers.isNotEmpty || changedCustomers.isNotEmpty || accCodeMismatches.isNotEmpty;
}

/// Top-level callback for WorkManager background task.
@pragma('vm:entry-point')
void driveWorkManagerCallback() {
  // WorkManager callback registered in main.dart
}
