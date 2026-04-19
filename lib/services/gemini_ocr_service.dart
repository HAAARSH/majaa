import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Extracts invoice data and UPI amounts from images using Gemini 1.5 Flash vision API.
class GeminiOcrService {
  static String? _cachedApiKey;

  static Future<String> _getApiKey() async {
    if (_cachedApiKey != null) return _cachedApiKey!;
    try {
      final envString = await rootBundle.loadString('env.json');
      final env = jsonDecode(envString) as Map<String, dynamic>;
      _cachedApiKey = env['GEMINI_API_KEY'] as String? ?? '';
    } catch (_) {
      _cachedApiKey = '';
    }
    return _cachedApiKey!;
  }

  static const String _endpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';

  // ─── 1a. FOR INVOICES from bytes (web-safe) ───
  static Future<({String? billNo, String? amount})> extractInvoiceDataFromBytes(Uint8List bytes) async {
    try {
      final result = await _callGeminiFromBytes(
        bytes: bytes,
        prompt: 'Extract the bill number and total amount from this invoice image. '
            'Reply ONLY in JSON format: {"bill_no": "value", "amount": "numeric value"}',
      );
      return (billNo: result?['bill_no'], amount: result?['amount']);
    } catch (e) {
      debugPrint('🚨 GeminiOcrService.extractInvoiceDataFromBytes error: $e');
      return (billNo: null, amount: null);
    }
  }

  // ─── 1b. FOR INVOICES from file path (reads file, then calls bytes version) ───
  static Future<({String? billNo, String? amount})> extractInvoiceData(String imagePath) async {
    try {
      // ignore: avoid_slow_async_io
      final bytes = await File(imagePath).readAsBytes();
      return extractInvoiceDataFromBytes(bytes);
    } catch (e) {
      debugPrint('🚨 GeminiOcrService.extractInvoiceData error: $e');
      return (billNo: null, amount: null);
    }
  }

  // ─── 1c. FOR CHEQUE PHOTOS ───
  /// Pulls cheque number, bank name and date off a photo of a cheque.
  /// All fields are best-effort — the rep can always override / leave blank.
  /// `date` is returned as `dd/MM/yyyy` or `yyyy-MM-dd` depending on what's
  /// printed; the caller normalises before storing.
  static Future<({String? chequeNo, String? bank, String? date, String? amount})>
      extractChequeData(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final result = await _callGeminiBase64(
        base64Image: base64Encode(bytes),
        prompt: 'This is a photo of an Indian bank cheque. Extract the '
            'cheque number (6-digit MICR number at the bottom or the '
            'number on top-right), the bank name printed on the cheque, '
            'the date written in the Date box, and the rupee amount in '
            'the Amount box. Reply ONLY in JSON format: '
            '{"cheque_no": "value", "bank": "value", "date": "value", '
            '"amount": "numeric value"}. Use null for any field not '
            'clearly visible.',
        extraKeys: const ['cheque_no', 'bank', 'date'],
      );
      return (
        chequeNo: result?['cheque_no'],
        bank: result?['bank'],
        date: result?['date'],
        amount: result?['amount'],
      );
    } catch (e) {
      debugPrint('🚨 GeminiOcrService.extractChequeData error: $e');
      return (chequeNo: null, bank: null, date: null, amount: null);
    }
  }

  // ─── 2. FOR UPI SCREENSHOTS ───
  static Future<String?> extractAmount(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final result = await _callGeminiFromBytes(
        bytes: bytes,
        prompt: 'Extract the total amount paid from this UPI payment screenshot. '
            'Reply ONLY in JSON format: {"bill_no": null, "amount": "numeric value"}',
      );
      return result?['amount'];
    } catch (e) {
      debugPrint('🚨 GeminiOcrService.extractAmount error: $e');
      return null;
    }
  }

  // ─── CORE: from bytes (web-safe) ───
  static Future<Map<String, String?>?> _callGeminiFromBytes({
    required Uint8List bytes,
    required String prompt,
    List<String> extraKeys = const [],
  }) async {
    return _callGeminiBase64(
      base64Image: base64Encode(bytes),
      prompt: prompt,
      extraKeys: extraKeys,
    );
  }

  // ─── CORE: from base64 string ───
  static Future<Map<String, String?>?> _callGeminiBase64({
    required String base64Image,
    required String prompt,
    List<String> extraKeys = const [],
  }) async {
    final apiKey = await _getApiKey();
    if (apiKey.isEmpty) {
      debugPrint('GeminiOcrService: GEMINI_API_KEY missing from env.json');
      return null;
    }
    debugPrint('Sending image to Gemini...');

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Image,
              }
            }
          ]
        }
      ]
    });

    final response = await http.post(
      Uri.parse('$_endpoint?key=$apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (response.statusCode != 200) {
      debugPrint('🚨 GeminiOcrService: API error ${response.statusCode}: ${response.body}');
      return null;
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final text = ((data['candidates'] as List?)?.firstOrNull?['content']
    ?['parts'] as List?)?.firstOrNull?['text'] as String?;

    if (text == null || text.isEmpty) {
      debugPrint('🚨 GeminiOcrService: Gemini returned empty text.');
      return null;
    }

    debugPrint('✅ Raw Gemini Response: $text');

    // Bulletproof JSON Extraction
    try {
      final startIndex = text.indexOf('{');
      final endIndex = text.lastIndexOf('}');

      if (startIndex == -1 || endIndex == -1) {
        debugPrint('🚨 GeminiOcrService: No JSON block found in response.');
        return null;
      }

      final jsonString = text.substring(startIndex, endIndex + 1);
      final parsed = jsonDecode(jsonString) as Map<String, dynamic>;

      String? clean(dynamic v) {
        final s = v?.toString().trim();
        if (s == null || s.isEmpty || s == 'null') return null;
        return s;
      }

      final out = <String, String?>{
        'bill_no': clean(parsed['bill_no']),
        'amount': clean(parsed['amount']),
      };
      for (final k in extraKeys) {
        out[k] = clean(parsed[k]);
      }
      return out;
    } catch (e) {
      debugPrint('🚨 GeminiOcrService: Failed to parse JSON: $e');
      return null;
    }
  }
}