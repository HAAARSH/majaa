import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import './supabase_service.dart';

class OfflineService {
  static final OfflineService instance = OfflineService._internal();

  OfflineService._internal();

  static const String _queueKey = 'offline_orders_queue';

  // 1. Save an order to the local device when internet fails
  Future<void> queueOrder(Map<String, dynamic> orderData) async {
    final prefs = await SharedPreferences.getInstance();
    final queue = prefs.getStringList(_queueKey) ?? [];

    queue.add(jsonEncode(orderData));
    await prefs.setStringList(_queueKey, queue);

    print('Order saved offline. Total in queue: ${queue.length}');
  }

  // 2. Check how many orders are waiting to be synced
  Future<int> getPendingCount() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_queueKey) ?? []).length;
  }

  // 3. THE SYNC ENGINE: Push all saved orders to Supabase
  // Renamed to syncOfflineOrders as requested
  Future<bool> syncOfflineOrders() async {
    final prefs = await SharedPreferences.getInstance();
    final queue = prefs.getStringList(_queueKey) ?? [];

    if (queue.isEmpty) {
      print('Offline Queue is empty. Nothing to sync.');
      return true;
    }

    print('Starting sync for ${queue.length} offline orders...');

    List<String> failedQueue = [];
    bool allSuccess = true;

    for (String orderJson in queue) {
      try {
        final orderData = jsonDecode(orderJson) as Map<String, dynamic>;
        final items = List<Map<String, dynamic>>.from(orderData['items']);

        // Attempt to upload to Supabase
        await SupabaseService.instance.createOrder(
          orderId: orderData['orderId'],
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

        print('Successfully synced offline order: ${orderData['orderId']}');
      } catch (e) {
        print('Failed to sync offline order: $e');
        // Keep failed orders in the list to try again next time
        failedQueue.add(orderJson);
        allSuccess = false;
      }
    }

    // 4. Update the local storage:
    // Only the orders that failed to upload stay in the phone's memory
    await prefs.setStringList(_queueKey, failedQueue);

    if (allSuccess) {
      print('All offline orders synced successfully!');
    } else {
      print('Sync partial: ${failedQueue.length} orders still pending.');
    }

    return allSuccess;
  }
}
