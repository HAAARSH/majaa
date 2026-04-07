import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

/// Service for caching hero avatar images using Hive
/// Key: Google Drive Image URL, Value: Image bytes (Uint8List)
class HeroCacheService {
  static HeroCacheService? _instance;
  static HeroCacheService get instance => _instance ??= HeroCacheService._();
  HeroCacheService._();

  static const _boxName = 'hero_image_cache';

  Future<Box> get _box async =>
      Hive.isBoxOpen(_boxName) ? Hive.box(_boxName) : await Hive.openBox(_boxName);

  /// Get cached image bytes for a given URL
  Future<Uint8List?> getCachedImage(String imageUrl) async {
    try {
      final box = await _box;
      final cachedBytes = box.get(imageUrl) as Uint8List?;
      if (cachedBytes != null) {
        debugPrint('🎯 Loading hero image from cache: $imageUrl');
        return cachedBytes;
      }
      return null;
    } catch (e) {
      debugPrint('❌ Error getting cached hero image: $e');
      return null;
    }
  }

  /// Cache image bytes for a given URL
  Future<void> cacheImage(String imageUrl, Uint8List bytes) async {
    try {
      final box = await _box;
      await box.put(imageUrl, bytes);
      debugPrint('💾 Cached hero image: $imageUrl');
    } catch (e) {
      debugPrint('❌ Error caching hero image: $e');
    }
  }

  /// Download and cache image from URL
  Future<Uint8List?> downloadAndCacheImage(String imageUrl) async {
    try {
      debugPrint('🌐 Downloading hero image: $imageUrl');
      final response = await http.get(Uri.parse(imageUrl));
      
      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;
        await cacheImage(imageUrl, bytes);
        return bytes;
      } else {
        debugPrint('❌ Failed to download hero image: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Error downloading hero image: $e');
      return null;
    }
  }

  /// Get image bytes - either from cache or download if not cached
  Future<Uint8List?> getImage(String imageUrl) async {
    // Try cache first
    final cachedBytes = await getCachedImage(imageUrl);
    if (cachedBytes != null) {
      return cachedBytes;
    }

    // Download and cache if not in cache
    return await downloadAndCacheImage(imageUrl);
  }

  /// Clear cache for a specific URL (useful when URL changes)
  Future<void> clearCacheForUrl(String imageUrl) async {
    try {
      final box = await _box;
      await box.delete(imageUrl);
      debugPrint('🗑️ Cleared cache for: $imageUrl');
    } catch (e) {
      debugPrint('❌ Error clearing cache: $e');
    }
  }

  /// Clear all cached hero images
  Future<void> clearAllCache() async {
    try {
      final box = await _box;
      await box.clear();
      debugPrint('🗑️ Cleared all hero image cache');
    } catch (e) {
      debugPrint('❌ Error clearing all cache: $e');
    }
  }

  /// Get cache size information
  Future<Map<String, dynamic>> getCacheInfo() async {
    try {
      final box = await _box;
      return {
        'count': box.keys.length,
        'keys': box.keys.toList(),
      };
    } catch (e) {
      debugPrint('❌ Error getting cache info: $e');
      return {'count': 0, 'keys': []};
    }
  }
}
