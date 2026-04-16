import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_service.dart';

/// Parses billing software CSV exports and reconciles against Supabase data.
/// CSV format: ITTR07.csv from DBF export — each row is a line item.
/// Rows with VOUTYPE=S are sales transactions.
/// Grouped by BOOK+VNO = bill number (e.g. INV-1, INV-2).
class CsvReconciliationService {
  static CsvReconciliationService? _instance;
  static CsvReconciliationService get instance => _instance ??= CsvReconciliationService._();
  CsvReconciliationService._();

  SupabaseClient get _client => Supabase.instance.client;

  // ─── COLUMN INDEXES (from ITTR07.csv header) ─────────────────

  // These map to the DBF field positions in the CSV
  static const int _colDate = 0;
  static const int _colSmanName = 1;
  static const int _colCompany = 3;
  static const int _colItemName = 4;
  static const int _colPacking = 5;
  static const int _colPrintName = 6;
  static const int _colItemGroup = 7;
  static const int _colItemCode = 8;
  static const int _colVatCode = 13; // HSN code
  static const int _colMrp = 16;
  static const int _colQuantity = 22;
  static const int _colRate = 27;
  static const int _colAmount = 29;
  static const int _colDiscPer1 = 32;
  static const int _colDiscount1 = 33;
  static const int _colVatPer = 44; // CGST %
  static const int _colVatAmount = 45;
  static const int _colSatPer = 46; // SGST %
  static const int _colSatAmount = 47;
  static const int _colAcName = 77; // Customer name
  static const int _colGroup = 78; // Customer area
  static const int _colVouType = 81; // S=Sale, P=Purchase, O=Opening
  static const int _colBook = 82; // INV, etc.
  static const int _colVno = 83; // Bill number
  static const int _colSlNo = 84; // Line item serial
  static const int _colUserName = 92;

  // ─── PARSE CSV ───────────────────────────────────────────────

  /// Parse CSV string into grouped bills. Returns list of bill maps.
  /// Only includes sales transactions (VOUTYPE=S).
  List<Map<String, dynamic>> parseCsv(String csvContent) {
    final lines = const LineSplitter().convert(csvContent);
    if (lines.isEmpty) return [];

    // Skip header row (line 0 has field definitions)
    final dataLines = lines.length > 1 ? lines.sublist(1) : lines;

    // Group by bill number (BOOK + VNO)
    final Map<String, Map<String, dynamic>> billMap = {};

    for (final line in dataLines) {
      if (line.trim().isEmpty) continue;

      final fields = _parseCsvLine(line);
      if (fields.length < 84) continue; // Need at least up to SLNO column

      final vouType = fields.length > _colVouType ? fields[_colVouType].trim() : '';
      if (vouType != 'S') continue; // Only sales

      final book = fields.length > _colBook ? fields[_colBook].trim() : 'INV';
      final vno = fields.length > _colVno ? fields[_colVno].trim() : '';
      if (vno.isEmpty) continue;

      final billNo = '$book-$vno'; // e.g. INV-1, INV-2
      final date = fields[_colDate].trim();
      final customerName = fields.length > _colAcName ? fields[_colAcName].trim() : '';
      final customerArea = fields.length > _colGroup ? fields[_colGroup].trim() : '';

      if (!billMap.containsKey(billNo)) {
        billMap[billNo] = {
          'bill_no': billNo,
          'date': date,
          'customer_name': customerName,
          'customer_area': customerArea,
          'items': <Map<String, dynamic>>[],
          'grand_total': 0.0,
          'total_cgst': 0.0,
          'total_sgst': 0.0,
          'salesman': fields.length > _colSmanName ? fields[_colSmanName].trim() : '',
          'username': fields.length > _colUserName ? fields[_colUserName].trim() : '',
        };
      }

      final qty = double.tryParse(fields[_colQuantity].trim()) ?? 0;
      final rate = double.tryParse(fields[_colRate].trim()) ?? 0;
      final amount = double.tryParse(fields[_colAmount].trim()) ?? 0;
      final mrp = double.tryParse(fields[_colMrp].trim()) ?? 0;
      final discPer = double.tryParse(fields[_colDiscPer1].trim()) ?? 0;
      final discAmt = double.tryParse(fields[_colDiscount1].trim()) ?? 0;
      final cgstPer = double.tryParse(fields[_colVatPer].trim()) ?? 0;
      final cgstAmt = double.tryParse(fields[_colVatAmount].trim()) ?? 0;
      final sgstPer = double.tryParse(fields[_colSatPer].trim()) ?? 0;
      final sgstAmt = double.tryParse(fields[_colSatAmount].trim()) ?? 0;

      final item = {
        'company': fields[_colCompany].trim(),
        'item_name': fields[_colItemName].trim(),
        'packing': fields[_colPacking].trim(),
        'print_name': fields.length > _colPrintName ? fields[_colPrintName].trim() : '',
        'hsn_code': fields.length > _colVatCode ? fields[_colVatCode].trim() : '',
        'mrp': mrp,
        'qty': qty,
        'rate': rate,
        'amount': amount,
        'discount_percent': discPer,
        'discount_amount': discAmt,
        'cgst_percent': cgstPer,
        'cgst_amount': cgstAmt,
        'sgst_percent': sgstPer,
        'sgst_amount': sgstAmt,
        'gst_rate': cgstPer + sgstPer, // total GST
        'sl_no': fields.length > _colSlNo ? fields[_colSlNo].trim() : '',
      };

      (billMap[billNo]!['items'] as List).add(item);

      // Accumulate totals
      billMap[billNo]!['grand_total'] = (billMap[billNo]!['grand_total'] as double) + amount + cgstAmt + sgstAmt;
      billMap[billNo]!['total_cgst'] = (billMap[billNo]!['total_cgst'] as double) + cgstAmt;
      billMap[billNo]!['total_sgst'] = (billMap[billNo]!['total_sgst'] as double) + sgstAmt;
    }

    return billMap.values.toList();
  }

  /// Parse a single CSV line handling quoted fields.
  List<String> _parseCsvLine(String line) {
    final List<String> fields = [];
    bool inQuotes = false;
    final buffer = StringBuffer();

    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
      } else if (ch == ',' && !inQuotes) {
        fields.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    fields.add(buffer.toString());
    return fields;
  }

  // ─── RECONCILE AGAINST SUPABASE ──────────────────────────────

  /// Compare CSV bills against Supabase orders. Returns list of differences.
  Future<List<Map<String, dynamic>>> reconcile(List<Map<String, dynamic>> csvBills) async {
    final teamId = AuthService.currentTeam;
    final List<Map<String, dynamic>> changes = [];

    // Fetch ALL orders with items in one query, build lookup by billed_no/final_bill_no
    final allOrders = await _client.from('orders')
        .select('id, customer_name, grand_total, actual_billed_amount, billed_no, final_bill_no, status, order_items(*)')
        .eq('team_id', teamId);
    final Map<String, Map<String, dynamic>> orderByBillNo = {};
    for (final o in allOrders) {
      final billedNo = (o['billed_no'] as String?) ?? '';
      final finalBillNo = (o['final_bill_no'] as String?) ?? '';
      if (billedNo.isNotEmpty) orderByBillNo[billedNo] = o;
      if (finalBillNo.isNotEmpty) orderByBillNo[finalBillNo] = o;
    }

    for (final bill in csvBills) {
      final billNo = bill['bill_no'] as String;
      final csvTotal = bill['grand_total'] as double;
      final csvCustomer = bill['customer_name'] as String;
      final csvItems = bill['items'] as List;

      // Find matching order by billed_no or final_bill_no (in-memory lookup)
      final order = orderByBillNo[billNo];

      if (order == null) {
        // Bill exists in CSV but NOT in Supabase
        changes.add({
          'type': 'new_bill',
          'bill_no': billNo,
          'csv_customer': csvCustomer,
          'csv_total': csvTotal,
          'csv_items': csvItems,
          'message': 'Bill $billNo found in CSV but not in app orders',
        });
        continue;
      }

      final orderId = order['id'] as String;
      final dbTotal = (order['actual_billed_amount'] as num?)?.toDouble()
          ?? (order['grand_total'] as num?)?.toDouble() ?? 0;
      final dbCustomer = order['customer_name'] as String? ?? '';
      final dbStatus = order['status'] as String? ?? '';

      // Check customer name mismatch
      if (csvCustomer.isNotEmpty && dbCustomer.isNotEmpty &&
          csvCustomer.toLowerCase().trim() != dbCustomer.toLowerCase().trim()) {
        changes.add({
          'type': 'customer_mismatch',
          'bill_no': billNo,
          'order_id': orderId,
          'csv_customer': csvCustomer,
          'db_customer': dbCustomer,
          'message': 'Customer mismatch: CSV "$csvCustomer" vs App "$dbCustomer"',
        });
      }

      // Check amount difference
      if ((csvTotal - dbTotal).abs() > 2) {
        changes.add({
          'type': 'amount_mismatch',
          'bill_no': billNo,
          'order_id': orderId,
          'csv_total': csvTotal,
          'db_total': dbTotal,
          'difference': csvTotal - dbTotal,
          'csv_customer': csvCustomer,
          'db_customer': dbCustomer,
          'message': 'Amount mismatch: CSV \u20B9${csvTotal.toStringAsFixed(2)} vs App \u20B9${dbTotal.toStringAsFixed(2)}',
        });
      }

      // Check item-level differences
      final dbItems = order['order_items'] as List? ?? [];
      final itemChanges = _compareItems(csvItems, dbItems);
      if (itemChanges.isNotEmpty) {
        changes.add({
          'type': 'item_changes',
          'bill_no': billNo,
          'order_id': orderId,
          'csv_customer': csvCustomer,
          'item_changes': itemChanges,
          'message': '${itemChanges.length} item differences in bill $billNo',
        });
      }

      // If CSV confirms the bill and it's still pending → suggest auto-verify
      if (dbStatus == 'Pending Verification' && (csvTotal - dbTotal).abs() <= 2) {
        changes.add({
          'type': 'can_auto_verify',
          'bill_no': billNo,
          'order_id': orderId,
          'csv_total': csvTotal,
          'message': 'Bill $billNo can be auto-verified (amounts match)',
        });
      }
    }

    return changes;
  }

  /// Compare CSV items vs DB order items. Returns list of differences.
  List<Map<String, dynamic>> _compareItems(List csvItems, List dbItems) {
    final List<Map<String, dynamic>> diffs = [];

    // Build DB item map by name (lowercase)
    final dbItemMap = <String, Map<String, dynamic>>{};
    for (final item in dbItems) {
      final name = ((item as Map)['product_name'] as String? ?? '').toLowerCase().trim();
      if (name.isNotEmpty) dbItemMap[name] = Map<String, dynamic>.from(item);
    }

    for (final csvItem in csvItems) {
      final csvName = (csvItem['item_name'] as String).toLowerCase().trim();
      final csvQty = (csvItem['qty'] as num?)?.toDouble() ?? 0;
      final csvAmount = (csvItem['amount'] as num?)?.toDouble() ?? 0;

      if (dbItemMap.containsKey(csvName)) {
        final dbItem = dbItemMap[csvName]!;
        final dbQty = (dbItem['quantity'] as num?)?.toDouble() ?? 0;

        if (csvQty < dbQty) {
          diffs.add({
            'change': 'qty_reduced',
            'item_name': csvItem['item_name'],
            'csv_qty': csvQty,
            'db_qty': dbQty,
            'returned_qty': dbQty - csvQty,
            'message': '${(dbQty - csvQty).toInt()} pcs returned by customer',
          });
        } else if (csvQty > dbQty) {
          diffs.add({
            'change': 'qty_increased',
            'item_name': csvItem['item_name'],
            'csv_qty': csvQty,
            'db_qty': dbQty,
            'message': 'Qty increased from ${dbQty.toInt()} to ${csvQty.toInt()}',
          });
        }
        dbItemMap.remove(csvName);
      } else {
        // Item in CSV but not in order
        diffs.add({
          'change': 'new_item',
          'item_name': csvItem['item_name'],
          'csv_qty': csvQty,
          'csv_amount': csvAmount,
          'message': 'Item not in original order',
        });
      }
    }

    // Items in order but not in CSV → returned
    for (final entry in dbItemMap.entries) {
      diffs.add({
        'change': 'item_removed',
        'item_name': entry.value['product_name'],
        'db_qty': (entry.value['quantity'] as num?)?.toDouble() ?? 0,
        'message': 'Returned by customer',
      });
    }

    return diffs;
  }

  // ─── BULK UPDATE ─────────────────────────────────────────────

  /// Apply a list of changes to Supabase. Returns count of applied changes.
  Future<int> applyChanges(List<Map<String, dynamic>> changes) async {
    int applied = 0;

    for (final change in changes) {
      try {
        final type = change['type'] as String;
        final orderId = change['order_id'] as String?;

        switch (type) {
          case 'amount_mismatch':
            if (orderId != null) {
              await _client.from('orders').update({
                'actual_billed_amount': change['csv_total'],
                'invoice_amount': change['csv_total'],
                'updated_at': DateTime.now().toIso8601String(),
              }).eq('id', orderId);
              applied++;
            }
            break;

          case 'can_auto_verify':
            if (orderId != null) {
              await _client.from('orders').update({
                'final_bill_no': change['bill_no'],
                'billed_no': change['bill_no'],
                'actual_billed_amount': change['csv_total'],
                'invoice_amount': change['csv_total'],
                'verified_by_office': true,
                'status': 'Verified',
                'updated_at': DateTime.now().toIso8601String(),
              }).eq('id', orderId);
              applied++;
            }
            break;
        }
      } catch (e) {
        debugPrint('Failed to apply change: $e');
      }
    }

    return applied;
  }
}
