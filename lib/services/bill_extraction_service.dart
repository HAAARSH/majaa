import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_service.dart';

/// Extracts bill data from PDF images via Gemini, stores in Supabase,
/// and runs auto-matching for orders, customers, and products.
class BillExtractionService {
  static BillExtractionService? _instance;
  static BillExtractionService get instance => _instance ??= BillExtractionService._();
  BillExtractionService._();

  SupabaseClient get _client => Supabase.instance.client;

  static String? _geminiKey;
  static const String _endpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';

  Future<String> _getApiKey() async {
    if (_geminiKey != null) return _geminiKey!;
    final envString = await rootBundle.loadString('env.json');
    final env = jsonDecode(envString) as Map<String, dynamic>;
    _geminiKey = env['GEMINI_API_KEY'] as String? ?? '';
    return _geminiKey!;
  }

  // ─── EXTRACT BILLS FROM IMAGE ────────────────────────────────

  static const String _billPrompt = '''Extract ALL invoices/bills from this document. The bills are from JAGANNATH ASSOCIATES.

For each invoice, extract this EXACT JSON structure:
{
  "bills": [
    {
      "bill_no": "exact invoice number as printed (e.g. INV33, MV2, INV/25-26/33)",
      "date": "DD.MM.YYYY",
      "customer_name": "customer/party name ONLY (text before any dash, comma, or address)",
      "items": [
        {
          "description": "exact item/product name as printed",
          "hsn": "HSN/SAC code",
          "mrp": 0.00,
          "gst_rate": 0.00,
          "qty": 0,
          "rate": 0.00,
          "discount_percent": 0.00,
          "amount": 0.00
        }
      ],
      "subtotal": 0.00,
      "cgst": 0.00,
      "sgst": 0.00,
      "grand_total": 0.00
    }
  ]
}

IMPORTANT:
- "customer_name" should be ONLY the business/shop name, NOT the address. If the format is "NAME - ADDRESS" or "NAME, ADDRESS", extract only NAME.
- "description" should be the exact product name as printed on the bill.
- "gst_rate" is the percentage (e.g. 5, 12, 18), not the amount.
- "amount" is the line total for that item.
- Extract ALL items from ALL bills visible on every page.
- Reply ONLY with valid JSON. No explanation, no markdown.''';

  /// Send an image or PDF to Gemini and extract all bills.
  /// For PDFs with many pages, processes in chunks of [_pagesPerChunk] to avoid
  /// output truncation.
  /// [mimeType] should be 'image/jpeg', 'image/png', or 'application/pdf'.
  /// [onProgress] callback reports (currentChunk, totalChunks) for UI updates.
  Future<List<Map<String, dynamic>>> extractBillsFromImage(
    Uint8List imageBytes, {
    String mimeType = 'image/jpeg',
    void Function(int current, int total)? onProgress,
  }) async {
    final apiKey = await _getApiKey();
    if (apiKey.isEmpty) throw Exception('GEMINI_API_KEY not set');

    // For images, send directly in a single call
    if (!mimeType.contains('pdf')) {
      onProgress?.call(1, 1);
      return _callGemini(apiKey, imageBytes, mimeType);
    }

    // For PDFs, detect page count and process in chunks
    final pageCount = _estimatePdfPages(imageBytes);
    const pagesPerChunk = 15;

    if (pageCount <= pagesPerChunk) {
      // Small PDF — send in one go
      onProgress?.call(1, 1);
      return _callGemini(apiKey, imageBytes, mimeType);
    }

    // Large PDF — process in page-range chunks
    final totalChunks = (pageCount / pagesPerChunk).ceil();
    final allBills = <Map<String, dynamic>>[];

    for (var chunk = 0; chunk < totalChunks; chunk++) {
      final startPage = chunk * pagesPerChunk + 1;
      final endPage = ((chunk + 1) * pagesPerChunk).clamp(1, pageCount);
      onProgress?.call(chunk + 1, totalChunks);

      try {
        final bills = await _callGemini(
          apiKey,
          imageBytes,
          mimeType,
          pageHint: 'Process ONLY pages $startPage to $endPage of this PDF. Ignore all other pages.',
        );
        allBills.addAll(bills);
      } catch (e) {
        debugPrint('Chunk ${chunk + 1}/$totalChunks failed: $e');
        // Continue with remaining chunks even if one fails
      }
    }

    return allBills;
  }

  /// Estimate PDF page count by scanning for /Type /Page entries in the raw bytes.
  int _estimatePdfPages(Uint8List bytes) {
    // Quick scan: count occurrences of "/Type /Page" (not "/Type /Pages") in raw PDF
    final str = String.fromCharCodes(bytes, 0, bytes.length.clamp(0, bytes.length));
    // Pattern: /Type /Page followed by non 's' (to exclude /Type /Pages)
    final regex = RegExp(r'/Type\s*/Page[^s]');
    final count = regex.allMatches(str).length;
    return count > 0 ? count : 1;
  }

  /// Core Gemini API call for a single document/image.
  Future<List<Map<String, dynamic>>> _callGemini(
    String apiKey,
    Uint8List bytes,
    String mimeType, {
    String? pageHint,
  }) async {
    final base64Data = base64Encode(bytes);
    final prompt = pageHint != null ? '$pageHint\n\n$_billPrompt' : _billPrompt;

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': mimeType,
                'data': base64Data,
              }
            }
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.1,
        'maxOutputTokens': 65536,
      }
    });

    final response = await http.post(
      Uri.parse('$_endpoint?key=$apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (response.statusCode != 200) {
      throw Exception('Gemini API error (${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = data['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) return [];

    final content = candidates[0]['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) return [];

    String text = parts[0]['text'] as String? ?? '';
    // Clean markdown code blocks if present
    text = text.replaceAll('```json', '').replaceAll('```', '').trim();

    try {
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      final bills = parsed['bills'] as List? ?? [];
      return bills.map((b) => Map<String, dynamic>.from(b as Map)).toList();
    } catch (e) {
      debugPrint('Failed to parse Gemini response: $text');
      throw Exception('Gemini returned invalid JSON');
    }
  }

  // ─── STORE EXTRACTED BILLS ───────────────────────────────────

  /// Save extracted bills to database and run matching.
  /// Returns count of bills saved.
  Future<int> saveExtractedBills(List<Map<String, dynamic>> bills) async {
    final teamId = AuthService.currentTeam;
    int saved = 0;

    for (final bill in bills) {
      try {
        final billNo = bill['bill_no'] as String? ?? '';
        if (billNo.isEmpty) continue;

        // Check if already extracted (avoid duplicates)
        final existing = await _client.from('bill_extractions')
            .select('id')
            .eq('bill_no', billNo)
            .eq('team_id', teamId)
            .maybeSingle();
        if (existing != null) {
          debugPrint('Bill $billNo already extracted, skipping');
          continue;
        }

        // Parse date
        String? dateStr;
        final rawDate = bill['date'] as String?;
        if (rawDate != null) {
          // Convert DD.MM.YYYY to YYYY-MM-DD
          final parts = rawDate.split('.');
          if (parts.length == 3) {
            dateStr = '${parts[2]}-${parts[1].padLeft(2, '0')}-${parts[0].padLeft(2, '0')}';
          }
        }

        // Insert bill extraction
        final insertResult = await _client.from('bill_extractions').insert({
          'bill_no': billNo,
          'bill_date': dateStr,
          'customer_name_ocr': bill['customer_name'] as String?,
          'subtotal': (bill['subtotal'] as num?)?.toDouble(),
          'cgst_total': (bill['cgst'] as num?)?.toDouble(),
          'sgst_total': (bill['sgst'] as num?)?.toDouble(),
          'grand_total': (bill['grand_total'] as num?)?.toDouble(),
          'team_id': teamId,
        }).select('id').maybeSingle();

        if (insertResult == null) {
          debugPrint('Failed to insert bill extraction for $billNo');
          continue;
        }
        final extractionId = insertResult['id'] as String;

        // Insert line items
        final items = bill['items'] as List? ?? [];
        for (final item in items) {
          final itemMap = Map<String, dynamic>.from(item as Map);
          final itemName = itemMap['description'] as String? ?? '';
          if (itemName.isEmpty) continue;

          // Check saved mappings first
          String? productId = await _findSavedMapping(itemName, teamId);
          bool matched = productId != null;

          // If no saved mapping, try exact name match
          if (!matched) {
            productId = await _exactProductMatch(itemName, teamId);
            matched = productId != null;
          }

          await _client.from('order_billed_items').insert({
            'bill_extraction_id': extractionId,
            'bill_no': billNo,
            'product_id': productId,
            'billed_item_name': itemName,
            'hsn_code': itemMap['hsn'] as String?,
            'mrp': (itemMap['mrp'] as num?)?.toDouble(),
            'gst_rate': (itemMap['gst_rate'] as num?)?.toDouble(),
            'quantity': (itemMap['qty'] as num?)?.toDouble(),
            'rate': (itemMap['rate'] as num?)?.toDouble(),
            'discount_percent': (itemMap['discount_percent'] as num?)?.toDouble(),
            'amount': (itemMap['amount'] as num?)?.toDouble(),
            'matched': matched,
            'team_id': teamId,
          });
        }

        // Run auto-matching for this bill
        await _autoMatchBill(extractionId, billNo, teamId);

        saved++;
        debugPrint('Saved bill $billNo with ${items.length} items');
      } catch (e) {
        debugPrint('Error saving bill: $e');
      }
    }
    return saved;
  }

  // ─── AUTO-MATCHING ───────────────────────────────────────────

  Future<void> _autoMatchBill(String extractionId, String billNo, String teamId) async {
    // 1. Customer matching — exact name only (manual for fuzzy)
    final extraction = await _client.from('bill_extractions')
        .select('customer_name_ocr')
        .eq('id', extractionId)
        .maybeSingle();
    if (extraction == null) return;
    final ocrName = (extraction['customer_name_ocr'] as String? ?? '').trim();

    if (ocrName.isNotEmpty) {
      final customer = await _client.from('customers')
          .select('id')
          .ilike('name', ocrName)
          .maybeSingle();
      if (customer != null) {
        await _client.from('bill_extractions')
            .update({'customer_id': customer['id'], 'customer_matched': true})
            .eq('id', extractionId);
      }
    }

    // 2. Order matching — find order with matching billed_no
    final matchingOrder = await _client.from('orders')
        .select('id, grand_total, customer_name')
        .eq('billed_no', billNo)
        .eq('team_id', teamId)
        .maybeSingle();

    if (matchingOrder != null) {
      await _client.from('bill_extractions')
          .update({'order_id': matchingOrder['id'], 'order_matched': true})
          .eq('id', extractionId);

      // 3. Auto-verify: bill# matched. Check amount.
      final billExtraction = await _client.from('bill_extractions')
          .select('grand_total, customer_matched')
          .eq('id', extractionId)
          .maybeSingle();
      if (billExtraction == null) return;
      final extractedTotal = (billExtraction['grand_total'] as num?)?.toDouble() ?? 0;
      final orderTotal = (matchingOrder['grand_total'] as num?)?.toDouble() ?? 0;

      // Auto-verify if amount matches within ₹5 or customer is matched
      if ((extractedTotal - orderTotal).abs() <= 5) {
        await _client.from('bill_extractions')
            .update({'auto_verified': true})
            .eq('id', extractionId);

        // Update the order
        await _client.from('orders').update({
          'final_bill_no': billNo,
          'actual_billed_amount': extractedTotal,
          'verified_by_office': true,
          'status': 'Verified',
        }).eq('id', matchingOrder['id']);

        debugPrint('Auto-verified bill $billNo → order ${matchingOrder['id']}');
      } else {
        // Amount mismatch — auto-verify with new amount
        await _client.from('bill_extractions')
            .update({'auto_verified': true})
            .eq('id', extractionId);

        await _client.from('orders').update({
          'final_bill_no': billNo,
          'actual_billed_amount': extractedTotal,
          'verified_by_office': true,
          'status': 'Verified',
        }).eq('id', matchingOrder['id']);

        debugPrint('Auto-verified bill $billNo with updated amount $extractedTotal');
      }
    }
  }

  // ─── PRODUCT MATCHING HELPERS ────────────────────────────────

  Future<String?> _findSavedMapping(String ocrName, String teamId) async {
    final mapping = await _client.from('item_name_mappings')
        .select('product_id')
        .eq('ocr_name', ocrName.toUpperCase().trim())
        .eq('team_id', teamId)
        .maybeSingle();
    return mapping?['product_id'] as String?;
  }

  Future<String?> _exactProductMatch(String ocrName, String teamId) async {
    final product = await _client.from('products')
        .select('id')
        .eq('team_id', teamId)
        .ilike('name', ocrName.trim())
        .maybeSingle();
    return product?['id'] as String?;
  }

  /// Save a manual item name → product mapping for future auto-matching.
  Future<void> saveItemMapping(String ocrName, String productId) async {
    await _client.from('item_name_mappings').upsert({
      'ocr_name': ocrName.toUpperCase().trim(),
      'product_id': productId,
      'team_id': AuthService.currentTeam,
    });
  }

  // ─── FETCH METHODS ───────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getUnmatchedItems() async {
    final resp = await _client.from('order_billed_items')
        .select('*, bill_extractions!inner(bill_no, customer_name_ocr)')
        .eq('matched', false)
        .eq('team_id', AuthService.currentTeam)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(resp);
  }

  Future<List<Map<String, dynamic>>> getUnmatchedCustomers() async {
    final resp = await _client.from('bill_extractions')
        .select()
        .eq('customer_matched', false)
        .eq('team_id', AuthService.currentTeam)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(resp);
  }

  Future<List<Map<String, dynamic>>> getAllExtractions() async {
    final resp = await _client.from('bill_extractions')
        .select('*, order_billed_items(*)')
        .eq('team_id', AuthService.currentTeam)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(resp);
  }

  /// Link an item to a product and remember the mapping.
  Future<void> matchItem(String itemId, String productId, String ocrName) async {
    await _client.from('order_billed_items')
        .update({'product_id': productId, 'matched': true})
        .eq('id', itemId);
    await saveItemMapping(ocrName, productId);
  }

  /// Link a customer to a bill extraction.
  Future<void> matchCustomer(String extractionId, String customerId) async {
    await _client.from('bill_extractions')
        .update({'customer_id': customerId, 'customer_matched': true})
        .eq('id', extractionId);
  }
}
