import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'google_drive_auth_service.dart';
import 'auth_service.dart';

/// Uploads bill photos to Google Drive using a shared service account.
/// No per-device Google Sign-In needed — all devices use the same credential.
class GoogleDriveService {
  static GoogleDriveService? _instance;
  static GoogleDriveService get instance => _instance ??= GoogleDriveService._();
  GoogleDriveService._();

  Future<Map<String, String>> _authHeaders() async {
    return GoogleDriveAuthService.instance.authHeaders();
  }

  Future<String?> uploadPhoto(XFile photo, {required String fileNamePrefix}) async {
    try {
      final headers = await _authHeaders();
      final file = File(photo.path);
      final bytes = await file.readAsBytes();
      final fileName = '${fileNamePrefix}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final boundary = 'MAJAABoundary${DateTime.now().millisecondsSinceEpoch}';
      final metaMap = <String, dynamic>{'name': fileName, 'mimeType': 'image/jpeg'};
      final metadata = jsonEncode(metaMap);
      final body = utf8.encode(
            '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n--$boundary\r\nContent-Type: image/jpeg\r\n\r\n',
          ) +
          bytes +
          utf8.encode('\r\n--$boundary--');
      final response = await http.post(
        Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true'),
        headers: {
          ...headers,
          'Content-Type': 'multipart/related; boundary=$boundary',
          'Content-Length': body.length.toString(),
        },
        body: body,
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return json['id'] as String?;
      }
      debugPrint('Drive upload failed: ${response.statusCode} ${response.body}');
      return null;
    } catch (e) {
      debugPrint('Upload failed: $e');
      return null;
    }
  }

  Future<String?> uploadHeroAvatar(XFile photo, {required String userId}) async {
    try {
      final headers = await _authHeaders();
      final file = File(photo.path);
      final bytes = await file.readAsBytes();
      
      // Determine team folder based on current workspace
      final teamFolder = AuthService.currentTeam == 'JA' ? 'JA/Avatars' : 'MA/Avatars';
      final fileName = '${userId}_hero_${DateTime.now().millisecondsSinceEpoch}.jpg';
      
      final boundary = 'MAJAABoundary${DateTime.now().millisecondsSinceEpoch}';
      final metaMap = <String, dynamic>{
        'name': fileName,
        'mimeType': 'image/jpeg',
        'parents': [await _getOrCreateFolderId(teamFolder)],
      };
      final metadata = jsonEncode(metaMap);
      final body = utf8.encode(
            '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n--$boundary\r\nContent-Type: image/jpeg\r\n\r\n',
          ) +
          bytes +
          utf8.encode('\r\n--$boundary--');
      final response = await http.post(
        Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true'),
        headers: {
          ...headers,
          'Content-Type': 'multipart/related; boundary=$boundary',
          'Content-Length': body.length.toString(),
        },
        body: body,
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final fileId = json['id'] as String?;
        
        // Make file publicly viewable
        if (fileId != null) {
          await _makeFilePublic(fileId, headers);
          // Return viewable link
          return 'https://drive.google.com/uc?export=view&id=$fileId';
        }
      }
      debugPrint('Hero avatar upload failed: ${response.statusCode} ${response.body}');
      return null;
    } catch (e) {
      debugPrint('Hero avatar upload failed: $e');
      return null;
    }
  }

  Future<String?> _getOrCreateFolderId(String folderPath) async {
    try {
      final headers = await _authHeaders();
      final parts = folderPath.split('/');
      
      // First, get or create root folder (JA or MA)
      final rootFolderName = parts[0];
      final rootQueryStr = 'name="$rootFolderName" and mimeType="application/vnd.google-apps.folder"';
      final rootQuery = await http.get(
        Uri.parse('https://www.googleapis.com/drive/v3/files?supportsAllDrives=true&includeItemsFromAllDrives=true&q=${Uri.encodeQueryComponent(rootQueryStr)}'),
        headers: headers,
      );
      
      String? rootFolderId;
      if (rootQuery.statusCode == 200) {
        final data = jsonDecode(rootQuery.body) as Map<String, dynamic>;
        final files = data['files'] as List?;
        if (files != null && files.isNotEmpty) {
          rootFolderId = files.first is Map ? files.first['id'] as String? : null;
        }
      }
      
      // Create root folder if it doesn't exist
      if (rootFolderId == null) {
        final createRoot = await http.post(
          Uri.parse('https://www.googleapis.com/drive/v3/files?supportsAllDrives=true'),
          headers: headers,
          body: jsonEncode({
            'name': rootFolderName,
            'mimeType': 'application/vnd.google-apps.folder',
          }),
        );
        if (createRoot.statusCode == 200) {
          rootFolderId = jsonDecode(createRoot.body)['id'] as String?;
        }
      }
      
      if (rootFolderId == null) return null;
      
      // Now get or create Avatars subfolder
      final subFolderName = parts.length > 1 ? parts[1] : 'Avatars';
      final subQueryStr = 'name="$subFolderName" and mimeType="application/vnd.google-apps.folder" and "$rootFolderId" in parents';
      final subQuery = await http.get(
        Uri.parse('https://www.googleapis.com/drive/v3/files?supportsAllDrives=true&includeItemsFromAllDrives=true&q=${Uri.encodeQueryComponent(subQueryStr)}'),
        headers: headers,
      );
      
      String? subFolderId;
      if (subQuery.statusCode == 200) {
        final data = jsonDecode(subQuery.body) as Map<String, dynamic>;
        final files = data['files'] as List?;
        if (files != null && files.isNotEmpty) {
          subFolderId = files.first is Map ? files.first['id'] as String? : null;
        }
      }
      
      // Create subfolder if it doesn't exist
      if (subFolderId == null) {
        final createSub = await http.post(
          Uri.parse('https://www.googleapis.com/drive/v3/files?supportsAllDrives=true'),
          headers: headers,
          body: jsonEncode({
            'name': subFolderName,
            'mimeType': 'application/vnd.google-apps.folder',
            'parents': [rootFolderId],
          }),
        );
        if (createSub.statusCode == 200) {
          subFolderId = jsonDecode(createSub.body)['id'] as String?;
        }
      }
      
      return subFolderId;
    } catch (e) {
      debugPrint('Folder creation failed: $e');
      return null;
    }
  }

  Future<void> _makeFilePublic(String fileId, Map<String, String> headers) async {
    try {
      await http.post(
        Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId/permissions?supportsAllDrives=true'),
        headers: headers,
        body: jsonEncode({
          'role': 'reader',
          'type': 'anyone',
        }),
      );
    } catch (e) {
      debugPrint('Failed to make file public: $e');
    }
  }
}
