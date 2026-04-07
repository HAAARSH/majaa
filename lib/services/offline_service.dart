import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import './supabase_service.dart';

class OfflineService {
  static final OfflineService instance = OfflineService._internal();

  OfflineService._internal();

  static const String _queueKey = 'offline_orders_queue';
  static const String _retryKey = 'offline_orders_retry_counts';
  static const int _maxRetries = 5;

  // 1. Save an order to the local device when internet fails
  Future<void> queueOrder(Map<String, dynamic> orderData) async {
    final prefs = await SharedPreferences.getInstance();
    final queue = prefs.getStringList(_queueKey) ?? [];

    // Limit queue size to prevent SharedPreferences overflow
    if (queue.length >= 500) {
      debugPrint('Offline queue full (500). Cannot add more orders.');
      return;
    }

    queue.add(jsonEncode(orderData));
    await prefs.setStringList(_queueKey, queue);

    debugPrint('Order saved offline. Total in queue: ${queue.length}');
  }

  // 2. Check how many orders are waiting to be synced
  Future<int> getPendingCount() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_queueKey) ?? []).length;
  }

  // 3. THE SYNC ENGINE: Push all saved orders to Supabase
  Future<bool> syncOfflineOrders() async {
    final prefs = await SharedPreferences.getInstance();
    final queue = prefs.getStringList(_queueKey) ?? [];
    final retryCounts = Map<String, int>.from(
        jsonDecode(prefs.getString(_retryKey) ?? '{}') as Map);

    if (queue.isEmpty) {
      debugPrint('Offline Queue is empty. Nothing to sync.');
      return true;
    }

    debugPrint('Starting sync for ${queue.length} offline orders...');

    List<String> failedQueue = [];
    bool allSuccess = true;

    for (String orderJson in queue) {
      try {
        final orderData = jsonDecode(orderJson) as Map<String, dynamic>;
        final orderId = orderData['orderId'] as String? ?? '';

        // Skip orders that exceeded max retries
        final retries = retryCounts[orderId] ?? 0;
        if (retries >= _maxRetries) {
          debugPrint('Order $orderId exceeded max retries ($_maxRetries). Skipping.');
          continue; // Drop from queue permanently
        }

        final items = List<Map<String, dynamic>>.from(orderData['items']);

        await SupabaseService.instance.createOrder(
          orderId: orderId,
          customerId: orderData['customerId'],
          customerName: orderData['customerName'],
          beat: orderData['beat'],
          deliveryDate: DateTime.parse(orderData['deliveryDate']),
          subtotal: orderData['subtotal'],
          vat: orderData['vat'],
          grandTotal: orderData['grandTotal'],
          itemCount: orderData['itemCount'],
          totalUnits: orderData['totalUnits'],
          notes: orderData['notes'] ?? '',
          items: items,
        );

        debugPrint('Successfully synced offline order: $orderId');
        retryCounts.remove(orderId);
      } catch (e) {
        debugPrint('Failed to sync offline order: $e');
        final orderData = jsonDecode(orderJson) as Map<String, dynamic>;
        final orderId = orderData['orderId'] as String? ?? '';
        retryCounts[orderId] = (retryCounts[orderId] ?? 0) + 1;
        failedQueue.add(orderJson);
        allSuccess = false;
      }
    }

    await prefs.setStringList(_queueKey, failedQueue);
    await prefs.setString(_retryKey, jsonEncode(retryCounts));

    if (allSuccess) {
      debugPrint('All offline orders synced successfully!');
    } else {
      debugPrint('Sync partial: ${failedQueue.length} orders still pending.');
    }

    return allSuccess;
  }
}
