import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/search_utils.dart';
import 'auth_service.dart';
import 'supabase_service.dart';

// ─────────────────────────────────────────────────────────────────────────
// Data types — draft order shapes produced by Gemini and consumed by UI.
// ─────────────────────────────────────────────────────────────────────────

/// Multi-order Gemini output — one attachment may contain 1..N orders.
class SmartImportBatch {
  final List<SmartImportDraft> orders;
  final double overallConfidence;

  const SmartImportBatch({
    required this.orders,
    required this.overallConfidence,
  });
}

/// Raw output of Gemini on a brand-software / WhatsApp / OCR input.
class SmartImportDraft {
  /// Exact customer name as written in the input.
  final String customerNameAsWritten;
  final String? customerPhoneFromInput;
  final String? deliveryDateHint; // "tomorrow", "monday", "25/04/2026", or null
  final String? notes;
  final List<SmartImportDraftLine> lines;
  /// Gemini's self-reported overall confidence (0..1).
  final double overallConfidence;

  const SmartImportDraft({
    required this.customerNameAsWritten,
    required this.customerPhoneFromInput,
    required this.deliveryDateHint,
    required this.notes,
    required this.lines,
    required this.overallConfidence,
  });
}

/// One parsed line before matching. Gemini only returns raw text + qty;
/// OUR code does the product resolution downstream.
class SmartImportDraftLine {
  final String nameAsWritten;
  final String? eanCode;
  final int quantity;
  final String? unitHint; // 'pc', 'ladi', 'box', 'kg', etc.
  final double confidence; // 0..1, per-line

  const SmartImportDraftLine({
    required this.nameAsWritten,
    required this.eanCode,
    required this.quantity,
    required this.unitHint,
    required this.confidence,
  });
}

/// Customer resolution outcome.
class ResolvedCustomer {
  final CustomerModel? match;
  final List<CustomerModel> candidates;
  /// 'phone_exact' | 'alias_exact' | 'fuzzy' | 'none'
  final String matchedBy;
  final double confidence;

  const ResolvedCustomer({
    required this.match,
    required this.candidates,
    required this.matchedBy,
    required this.confidence,
  });
}

/// Product resolution outcome.
class ResolvedProduct {
  final ProductModel? match;
  final List<ProductModel> candidates;
  /// 'ean' | 'alias_customer' | 'history' | 'alias_global' | 'fuzzy' | 'none'
  final String matchedBy;
  final double confidence;

  const ResolvedProduct({
    required this.match,
    required this.candidates,
    required this.matchedBy,
    required this.confidence,
  });
}

// ─────────────────────────────────────────────────────────────────────────
// Service.
// ─────────────────────────────────────────────────────────────────────────

class SmartImportService {
  static final SmartImportService instance = SmartImportService._();
  SmartImportService._();

  SupabaseClient get _client => Supabase.instance.client;

  // ─── INPUT NORMALIZATION + HASH ──────────────────────────────────────

  /// Normalize before hashing so trivial diffs (trailing whitespace, CRLF vs
  /// LF, casing) don't produce different hashes. Admin re-paste should still
  /// be caught as a duplicate.
  static String normalizeForHash(String raw) {
    return raw
        .replaceAll('\r\n', '\n')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  static String computeInputHash(String raw) {
    final normalized = normalizeForHash(raw);
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  /// SHA-256 of raw file bytes. No normalization — the binary is already
  /// canonical. Same bytes re-uploaded → same hash → dedup-guard fires.
  static String computeFileHash(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  // ─── DUPLICATE GUARD ─────────────────────────────────────────────────

  /// Returns the existing import row if this hash is already represented by
  /// an ACTIVE row in the same team. Null if not a duplicate.
  ///
  /// A row is "active" (blocks re-import) when ALL of:
  ///   * revoked_at IS NULL                      (not super_admin-revoked)
  ///   * status NOT IN ('discarded', 'failed')   (produced at least one saved order)
  ///
  /// Matches the partial unique index in migration 20260424000004.
  /// Discarded, failed, or revoked rows are silently ignored so admins can
  /// retry the same input without a manual override.
  ///
  /// The returned map always has a `resulting_order_ids: List<String>` key,
  /// backfilled from the scalar `resulting_order_id` for rows written
  /// before the multi-order migration.
  Future<Map<String, dynamic>?> findImportByHash(String hash, String teamId) async {
    try {
      final resp = await _client
          .from('smart_import_history')
          .select('id, resulting_order_id, resulting_order_ids, imported_at, '
              'status, input_preview, revoked_at')
          .eq('input_hash', hash)
          .eq('team_id', teamId)
          .filter('revoked_at', 'is', null)
          .not('status', 'in', '(discarded,failed)')
          .maybeSingle();
      if (resp == null) return null;
      final row = Map<String, dynamic>.from(resp);
      final rawIds = row['resulting_order_ids'];
      final ids = <String>[
        if (rawIds is List)
          ...rawIds.map((e) => e.toString()).where((s) => s.isNotEmpty)
      ];
      if (ids.isEmpty && row['resulting_order_id'] != null) {
        ids.add(row['resulting_order_id'].toString());
      }
      row['resulting_order_ids'] = ids;
      return row;
    } catch (e) {
      debugPrint('[SmartImport] findImportByHash failed: $e');
      return null;
    }
  }

  /// Super_admin-only: soft-delete a smart_import_history row so its hash
  /// stops blocking future imports of the same content. Does NOT touch the
  /// created orders (if any) — admin manages those via the Orders tab.
  ///
  /// Returns true on success. Caller must enforce super_admin gating in
  /// the UI; this method does not check the current role.
  Future<bool> revokeImportHistoryRow({
    required String rowId,
    required String revokedByUserId,
  }) async {
    try {
      await _client.from('smart_import_history').update({
        'revoked_at': DateTime.now().toUtc().toIso8601String(),
        'revoked_by_user_id': revokedByUserId,
      }).eq('id', rowId);
      return true;
    } catch (e) {
      debugPrint('[SmartImport] revokeImportHistoryRow failed: $e');
      return false;
    }
  }

  // ─── HISTORY WRITE ───────────────────────────────────────────────────

  /// Write an audit row after an attachment's save flow completes. Accepts a
  /// list of resulting order IDs because one attachment may produce multiple
  /// orders (handwritten slip with 3 shops). Writes BOTH columns for
  /// rollback safety during the multi-order migration window:
  ///   * `resulting_order_ids` — full list (canonical post-migration).
  ///   * `resulting_order_id`  — scalar, set to `ids.first` when non-empty.
  ///
  /// [status] is 'saved' when at least one order saved, 'discarded' when the
  /// admin skipped every card.
  Future<void> writeImportHistory({
    required String inputType,
    required String inputPreview,
    required String inputHash,
    required Map<String, dynamic> parsedResult,
    required Map<String, dynamic> adminCorrections,
    required List<String> resultingOrderIds,
    required String teamId,
    required String attributedRepUserId,
    required String importedByUserId,
    String status = 'saved',
  }) async {
    try {
      await _client.from('smart_import_history').insert({
        'imported_by_user_id': importedByUserId,
        'input_type': inputType,
        'input_preview': inputPreview.length > 500
            ? inputPreview.substring(0, 500)
            : inputPreview,
        'input_hash': inputHash,
        'parsed_result': parsedResult,
        'admin_corrections': adminCorrections,
        'resulting_order_id': resultingOrderIds.isEmpty ? null : resultingOrderIds.first,
        'resulting_order_ids': resultingOrderIds,
        'team_id': teamId,
        'status': status,
        'attributed_brand_rep_user_id': attributedRepUserId,
      });
    } catch (e) {
      // Non-fatal — the order is already saved. Log to debug only.
      debugPrint('[SmartImport] writeImportHistory failed: $e');
    }
  }

  // ─── CUSTOMER RESOLUTION ─────────────────────────────────────────────

  /// Priority: exact phone → alias lookup → client-side fuzzy token match.
  /// Returns the top candidate + a few alternatives for admin disambiguation.
  Future<ResolvedCustomer> resolveCustomer({
    required String extractedName,
    String? extractedPhone,
    required String teamId,
  }) async {
    // All customers loaded once (global table, filter client-side by team).
    final allCustomers = await SupabaseService.instance.getCustomers();
    final teamCustomers = allCustomers.where((c) => c.belongsToTeam(teamId)).toList();

    // 1. Exact phone match.
    final phone = (extractedPhone ?? '').trim();
    if (phone.isNotEmpty) {
      CustomerModel? byPhone;
      for (final c in teamCustomers) {
        if (c.phone.trim() == phone) {
          byPhone = c;
          break;
        }
      }
      if (byPhone != null) {
        return ResolvedCustomer(
          match: byPhone,
          candidates: [byPhone],
          matchedBy: 'phone_exact',
          confidence: 1.0,
        );
      }
    }

    // 2. Alias lookup (customer_alias_learning) on normalized name.
    final normalized = _normalizeAlias(extractedName);
    if (normalized.isNotEmpty) {
      try {
        final row = await _client
            .from('customer_alias_learning')
            .select('matched_customer_id')
            .eq('alias_text', normalized)
            .eq('team_id', teamId)
            .maybeSingle();
        if (row != null) {
          final cid = row['matched_customer_id'] as String?;
          CustomerModel? aliasMatch;
          for (final c in teamCustomers) {
            if (c.id == cid) {
              aliasMatch = c;
              break;
            }
          }
          if (aliasMatch != null) {
            // Bump last_used_at so most-used aliases stay warm.
            unawaited(_touchCustomerAlias(normalized, teamId));
            return ResolvedCustomer(
              match: aliasMatch,
              candidates: [aliasMatch],
              matchedBy: 'alias_exact',
              confidence: 0.95,
            );
          }
        }
      } catch (e) {
        debugPrint('[SmartImport] customer alias lookup failed: $e');
      }
    }

    // 3. Client-side fuzzy token match, top 3.
    final scored = <(CustomerModel, double)>[];
    for (final c in teamCustomers) {
      if (tokenMatch(extractedName, [c.name, c.phone])) {
        final s = _similarity(extractedName, c.name);
        if (s > 0.35) scored.add((c, s));
      }
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final top = scored.take(3).map((e) => e.$1).toList();

    if (top.isEmpty) {
      return const ResolvedCustomer(
        match: null, candidates: [], matchedBy: 'none', confidence: 0.0,
      );
    }
    final topConf = scored.first.$2;
    return ResolvedCustomer(
      match: topConf > 0.7 ? top.first : null, // leave null if ambiguous — admin picks
      candidates: top,
      matchedBy: 'fuzzy',
      confidence: topConf,
    );
  }

  Future<void> _touchCustomerAlias(String alias, String teamId) async {
    try {
      await _client.from('customer_alias_learning').update({
        'last_used_at': DateTime.now().toIso8601String(),
      }).eq('alias_text', alias).eq('team_id', teamId);
    } catch (_) {/* best-effort */}
  }

  // ─── PRODUCT RESOLUTION ──────────────────────────────────────────────

  /// Priority: EAN → customer-specific alias → global alias → client-side
  /// fuzzy. History-signal ranking deferred (see open questions in plan).
  Future<ResolvedProduct> resolveProduct({
    required String nameAsWritten,
    String? eanCode,
    String? customerId,
    required String teamId,
  }) async {
    final products = await SupabaseService.instance.getProducts(teamId: teamId);

    // 1. EAN exact match.
    final ean = (eanCode ?? '').trim();
    if (ean.isNotEmpty) {
      ProductModel? byEan;
      for (final p in products) {
        // EAN column was just added in Phase 0 migration and may not be on
        // the ProductModel class yet — read via toJson so the call is safe
        // regardless of model version.
        final productEan = (p.toJson()['ean_code'] as String? ?? '').trim();
        if (productEan == ean) {
          byEan = p;
          break;
        }
      }
      if (byEan != null) {
        return ResolvedProduct(
          match: byEan, candidates: [byEan], matchedBy: 'ean', confidence: 1.0,
        );
      }
    }

    final normalized = _normalizeAlias(nameAsWritten);

    // 2. Customer-specific alias.
    if (customerId != null && customerId.isNotEmpty && normalized.isNotEmpty) {
      final found = await _lookupProductAlias(
        normalized: normalized, customerId: customerId, teamId: teamId, products: products);
      if (found != null) {
        return ResolvedProduct(
          match: found, candidates: [found], matchedBy: 'alias_customer', confidence: 0.95,
        );
      }
    }

    // 3. Global alias.
    if (normalized.isNotEmpty) {
      final found = await _lookupProductAlias(
        normalized: normalized, customerId: null, teamId: teamId, products: products);
      if (found != null) {
        return ResolvedProduct(
          match: found, candidates: [found], matchedBy: 'alias_global', confidence: 0.75,
        );
      }
    }

    // 4. Client-side fuzzy over the catalog.
    final scored = <(ProductModel, double)>[];
    for (final p in products) {
      if (tokenMatch(nameAsWritten, [p.name, p.sku, p.category])) {
        final s = _similarity(nameAsWritten, p.name);
        if (s > 0.3) scored.add((p, s));
      }
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final top = scored.take(3).map((e) => e.$1).toList();

    if (top.isEmpty) {
      return const ResolvedProduct(
        match: null, candidates: [], matchedBy: 'none', confidence: 0.0,
      );
    }
    final topConf = scored.first.$2;
    return ResolvedProduct(
      match: topConf > 0.6 ? top.first : null,
      candidates: top,
      matchedBy: 'fuzzy',
      confidence: topConf,
    );
  }

  Future<ProductModel?> _lookupProductAlias({
    required String normalized,
    required String? customerId,
    required String teamId,
    required List<ProductModel> products,
  }) async {
    try {
      var q = _client
          .from('product_alias_learning')
          .select('matched_product_id')
          .eq('alias_text', normalized)
          .eq('team_id', teamId);
      if (customerId == null) {
        q = q.isFilter('customer_id', null);
      } else {
        q = q.eq('customer_id', customerId);
      }
      final row = await q.maybeSingle();
      if (row == null) return null;
      final pid = row['matched_product_id'] as String?;
      if (pid == null) return null;
      for (final p in products) {
        if (p.id == pid) return p;
      }
      return null;
    } catch (e) {
      debugPrint('[SmartImport] product alias lookup failed: $e');
      return null;
    }
  }

  // ─── ALIAS WRITES ────────────────────────────────────────────────────

  /// Insert or bump a product alias. If `customerId` is null → global alias
  /// (deduped by the partial unique index on (alias_text, team_id)).
  /// Returns true on success (insert or 23505 bump), false on a real
  /// failure (RLS reject, network, schema mismatch). Callers can ignore
  /// the return value for fire-and-forget behavior; the Smart Import UI
  /// aggregates false results into a post-save snackbar so admins know
  /// when learning silently failed.
  Future<bool> writeProductAlias({
    required String? customerId,
    required String aliasText,
    required String productId,
    required String teamId,
    required String createdByUserId,
  }) async {
    final normalized = _normalizeAlias(aliasText);
    if (normalized.isEmpty || productId.isEmpty) return true;
    try {
      // Try INSERT first; on unique violation, bump confidence + last_used.
      await _client.from('product_alias_learning').insert({
        'customer_id': customerId,
        'alias_text': normalized,
        'matched_product_id': productId,
        'team_id': teamId,
        'created_by_user_id': createdByUserId,
      });
      return true;
    } on PostgrestException catch (e) {
      // 23505 = unique_violation — alias already exists, bump it.
      if (e.code == '23505') {
        await _bumpProductAlias(
          customerId: customerId, alias: normalized, teamId: teamId,
        );
        return true;
      }
      debugPrint('[SmartImport] writeProductAlias failed: $e');
      return false;
    } catch (e) {
      debugPrint('[SmartImport] writeProductAlias failed: $e');
      return false;
    }
  }

  Future<void> _bumpProductAlias({
    required String? customerId,
    required String alias,
    required String teamId,
  }) async {
    try {
      // Read current score, increment, write back. Supabase doesn't offer
      // atomic column arithmetic via REST — this is an intentional trade-off
      // (admins rarely bump the same alias concurrently).
      var q = _client
          .from('product_alias_learning')
          .select('id, confidence_score')
          .eq('alias_text', alias)
          .eq('team_id', teamId);
      if (customerId == null) {
        q = q.isFilter('customer_id', null);
      } else {
        q = q.eq('customer_id', customerId);
      }
      final row = await q.maybeSingle();
      if (row == null) return;
      final id = row['id'] as String;
      final current = (row['confidence_score'] as num?)?.toInt() ?? 0;
      await _client.from('product_alias_learning').update({
        'confidence_score': current + 1,
        'last_used_at': DateTime.now().toIso8601String(),
      }).eq('id', id);
    } catch (e) {
      debugPrint('[SmartImport] _bumpProductAlias failed: $e');
    }
  }

  /// Returns true on success (insert or 23505 last_used_at bump), false
  /// on real failure. See writeProductAlias for rationale.
  Future<bool> writeCustomerAlias({
    required String aliasText,
    required String customerId,
    required String teamId,
    required String createdByUserId,
  }) async {
    final normalized = _normalizeAlias(aliasText);
    if (normalized.isEmpty || customerId.isEmpty) return true;
    try {
      await _client.from('customer_alias_learning').insert({
        'alias_text': normalized,
        'matched_customer_id': customerId,
        'team_id': teamId,
        'created_by_user_id': createdByUserId,
      });
      return true;
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        try {
          await _client.from('customer_alias_learning').update({
            'last_used_at': DateTime.now().toIso8601String(),
          }).eq('alias_text', normalized).eq('team_id', teamId);
        } catch (_) {/* best-effort */}
        return true;
      }
      debugPrint('[SmartImport] writeCustomerAlias failed: $e');
      return false;
    } catch (e) {
      debugPrint('[SmartImport] writeCustomerAlias failed: $e');
      return false;
    }
  }

  // ─── GEMINI PARSE (brand_software_text) ──────────────────────────────

  static String? _cachedKey;
  static Future<String> _getGeminiKey() async {
    if (_cachedKey != null) return _cachedKey!;
    final envString = await rootBundle.loadString('env.json');
    final env = jsonDecode(envString) as Map<String, dynamic>;
    _cachedKey = (env['GEMINI_API_KEY'] as String?) ?? '';
    return _cachedKey!;
  }

  static const String _geminiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';

  /// Heuristic classifier for text inputs.
  ///
  /// Returns 'brand_software_text' when the paste looks like structured
  /// brand-software output (GUBB/SCO etc. — many lines, explicit column
  /// labels, numeric columns). Otherwise 'whatsapp_text' (short, casual,
  /// often Hinglish).
  ///
  /// Admin can override via the UI dropdown if the guess is wrong.
  static String classifyTextInput(String raw) {
    final text = raw.toLowerCase();
    const brandMarkers = [
      'order qty',
      'order value',
      'total order value',
      'beat name',
      'beat :',
      'scheme qty',
      'scheme %',
    ];
    var hits = 0;
    for (final m in brandMarkers) {
      if (text.contains(m)) hits++;
    }
    if (hits >= 2) return 'brand_software_text';

    final lines = raw.split('\n').where((l) => l.trim().isNotEmpty).toList();
    // Long, multi-line structured pastes are almost always brand-software.
    if (lines.length >= 15) return 'brand_software_text';

    return 'whatsapp_text';
  }

  static const String _whatsappPrompt = r'''
You are a parsing assistant for a wholesale distributor's order system.
The input is a casual WhatsApp message from one or more retailers. A
SINGLE message may contain MULTIPLE independent orders (different shop
names, or clearly separated order blocks). 1-5 lines per order, mixed
English / Hindi / Hinglish. Common patterns:
  - "S.D store (9897477269) omkar road / Hakka noodles - 6pc / Origano - 2ladi"
  - "Send 10 maggi + 5 dal to apollo pharma tomorrow"
  - "Aaj 20 box kurkure bhej dena"

OUTPUT FORMAT — STRICT JSON, NO PROSE, NO MARKDOWN FENCES:
{
  "orders": [
    {
      "customer": {
        "name_as_written": "best guess from message, or empty string",
        "phone_if_present": "10-digit phone if visible, or null"
      },
      "delivery_date_hint": "today | tomorrow | aaj | kal | DD/MM/YYYY | null",
      "notes": "greetings, thank-yous, payment remarks not tied to items",
      "line_items": [
        {
          "name_as_written": "exact product nickname from message",
          "ean_code": null,
          "quantity": 6,
          "unit_hint": "pc | pcs | ladi | box | ctn | kg | ml | null",
          "confidence": 0.75
        }
      ],
      "overall_parse_confidence": 0.7
    }
  ]
}

SPLITTING INTO MULTIPLE ORDERS:
- If the message clearly lists 2+ distinct shops/customers each with
  their own item list, emit one element per shop in "orders".
- Signals of a new order: a new shop name line, a blank line followed
  by another header, "For X shop:" / "Also send to Y:" style labels.
- If it is a single order, emit a 1-element "orders" array.
- NEVER merge two different shops into one "customer" — prefer splitting.

LINE RULES (apply per order):
- Numbers right next to a product name / abbreviation are the quantity.
- "ladi" / "strip" = unit_hint 'ladi'. Do NOT multiply — our system
  resolves the strip size later.
- "box" / "ctn" = unit_hint 'box'.
- "kg", "gm", "ml", "ltr" = weight/volume hints; emit as unit_hint.
- Phone in parentheses / brackets / "ph:" prefix goes into phone_if_present.
- Emojis, "thanks", "please", "kal bhej dena" → notes, NOT a line item.
- If quantity is ambiguous (e.g. "thoda" / "some" / "kuch"), SKIP the
  line — do not invent a number.
- If the message is a question or complaint with no order, emit a
  1-element "orders" array with an empty line_items list and low
  overall_parse_confidence.
- JSON only.
''';

  static const String _handwrittenPrompt = r'''
You are a parsing assistant for a wholesale distributor's order system.
The input is a PHOTO of one or more handwritten order slips. A single
photo may contain MULTIPLE independent orders (different shop names
stacked vertically, each with its own item list). Handwriting is often
rushed, slanted, and may contain smudges or strikethroughs.

OUTPUT FORMAT — STRICT JSON, NO PROSE, NO MARKDOWN FENCES:
{
  "orders": [
    {
      "customer": {
        "name_as_written": "shop name from the header if visible, else empty",
        "phone_if_present": "10-digit phone if visible, else null"
      },
      "delivery_date_hint": "string or null",
      "notes": "anything not a line item",
      "line_items": [
        {
          "name_as_written": "exact text as written; use ? for illegible characters",
          "ean_code": null,
          "quantity": 5,
          "unit_hint": "pc | pcs | ladi | box | null",
          "confidence": 0.55
        }
      ],
      "overall_parse_confidence": 0.55
    }
  ]
}

SPLITTING INTO MULTIPLE ORDERS:
- Each distinct customer/shop header + its block of items = one order.
- Signals of a new order: a horizontal divider line, a new shop name /
  "To:" header, a phone number on its own line, a blank region between
  item blocks, a totals line closing one block.
- If the page contains a single order (one header + items), emit a
  1-element "orders" array.
- Never merge two shops into one "customer" — prefer splitting.

LINE RULES (apply per order):
- If a character is illegible, use '?' in name_as_written and DROP the
  line's confidence to 0.3-0.5.
- Rows with a strikethrough are CANCELLED — SKIP them entirely.
- If a quantity digit is ambiguous (e.g. could be 1 or 7, or 3 or 8),
  emit the most likely integer AND set confidence ≤ 0.6.
- Do NOT invent items that aren't physically on the page.
- Do NOT hallucinate quantities for lines without a clear number.
- JSON only.
''';

  static const String _brandSoftwarePrompt = r'''
You are a parsing assistant for a wholesale distributor's order system.
Your job is to extract structured order data from one or more orders
pasted from brand-software output (e.g. GUBB, SCO). A single paste MAY
contain multiple orders (different customers separated by blank lines
or a new customer header). Each order typically contains the customer /
beat / one line per product with quantity and possibly order value.

OUTPUT FORMAT — STRICT JSON, NO PROSE, NO MARKDOWN FENCES:
{
  "orders": [
    {
      "customer": {
        "name_as_written": "exact text from input",
        "phone_if_present": "string or null"
      },
      "delivery_date_hint": "tomorrow | monday | 25/04/2026 | null",
      "notes": "any freeform text not tied to a line item, or null",
      "line_items": [
        {
          "name_as_written": "exact product nickname from input",
          "ean_code": "string or null",
          "quantity": 5,
          "unit_hint": "pc | pcs | ladi | box | kg | ml | null",
          "confidence": 0.95
        }
      ],
      "overall_parse_confidence": 0.88
    }
  ]
}

SPLITTING INTO MULTIPLE ORDERS:
- If the paste clearly contains 2+ distinct customers (new header rows,
  blank-line separators, totals closing each block), emit one element
  per customer in "orders".
- If the paste is a single order, emit a 1-element "orders" array.
- Never merge two customers into one "customer" field.

LINE RULES (apply per order):
- DO NOT invent products. Only emit items present in the input.
- DO NOT do product matching — our system matches name_as_written to the catalog.
- Numbers next to items with '%' are discounts/schemes; IGNORE them as quantity.
- "Stock" columns are NOT order quantities. The column labeled "Order" or "Qty" is.
- If a number looks ambiguous, lower that line's confidence.
- "ladi" / "strip" means a strip of units; emit unit_hint='ladi' and let downstream convert.
- JSON only. No commentary.
''';

  /// Return shape for parseText / parseFromBytes. Lets the UI distinguish
  /// a timeout from a missing key from malformed JSON so the admin sees a
  /// useful message instead of a vague "parse failed".
  ///
  /// `draft == null` on every non-success outcome; `reason` is one of:
  ///   'no_key'     — GEMINI_API_KEY missing from env.json
  ///   'timeout'    — HTTP call exceeded the per-type timeout
  ///   'network'    — other transport error (DNS, offline, TLS)
  ///   'http_{n}'   — Gemini responded with a non-200 status (body logged)
  ///   'empty'      — Gemini returned no text part
  ///   'bad_json'   — Gemini response wasn't parseable as JSON
  ///   'internal'   — unexpected exception during parse
  ///   'ok'         — draft is non-null
  // (Kept as strings rather than an enum so existing callers can adopt
  // incrementally.)

  /// Parse a text paste into a structured draft. Returns the FIRST order
  /// from Gemini's response for back-compat with callers that still expect
  /// a single draft. Multi-order callers should use [parseBatchTextDetailed].
  ///
  /// [inputType] picks the prompt: 'brand_software_text' (GUBB/SCO
  /// structured) or 'whatsapp_text' (casual mixed-language). Anything
  /// else falls back to whatsapp_text.
  Future<SmartImportDraft?> parseText(String rawText, String inputType) async {
    final r = await parseTextDetailed(rawText, inputType);
    return r.draft;
  }

  Future<({SmartImportDraft? draft, String reason, String? detail})>
      parseTextDetailed(String rawText, String inputType) async {
    final r = await parseBatchTextDetailed(rawText, inputType);
    final draft = (r.batch == null || r.batch!.orders.isEmpty)
        ? null
        : r.batch!.orders.first;
    return (draft: draft, reason: r.reason, detail: r.detail);
  }

  /// Multi-order text parse. Returns a [SmartImportBatch] whose `orders`
  /// list has 1..N entries. Callers should iterate and present each as a
  /// separate draft card.
  Future<({SmartImportBatch? batch, String reason, String? detail})>
      parseBatchTextDetailed(String rawText, String inputType) async {
    final key = await _getGeminiKey();
    if (key.isEmpty) {
      debugPrint('[SmartImport] GEMINI_API_KEY missing');
      return (batch: null, reason: 'no_key', detail: null);
    }
    final prompt = switch (inputType) {
      'brand_software_text' => _brandSoftwarePrompt,
      'whatsapp_text' => _whatsappPrompt,
      _ => _whatsappPrompt,
    };

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {'text': 'INPUT:\n$rawText'},
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.1,
        // Multi-order prompts can legitimately run longer. Doubled from 16k
        // to leave headroom for 5-order handwritten slips.
        'maxOutputTokens': 32768,
      },
    });

    // Text can be long (GUBB pastes routinely run to 100+ lines). 60s gives
    // Gemini enough headroom; when we hit this, it's almost always network.
    const timeout = Duration(seconds: 60);
    return _callGeminiAndBuildBatch(body, timeout);
  }

  /// Shared HTTP + JSON + batch-construction path used by both the text and
  /// bytes parse flows. [body] is the pre-encoded Gemini request body;
  /// [timeout] is the per-request wall clock.
  Future<({SmartImportBatch? batch, String reason, String? detail})>
      _callGeminiAndBuildBatch(String body, Duration timeout) async {
    final key = await _getGeminiKey();
    http.Response resp;
    try {
      resp = await http.post(
        Uri.parse('$_geminiEndpoint?key=$key'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      ).timeout(timeout);
    } on TimeoutException {
      debugPrint('[SmartImport] Gemini timed out after ${timeout.inSeconds}s');
      return (batch: null, reason: 'timeout', detail: '${timeout.inSeconds}s');
    } catch (e) {
      debugPrint('[SmartImport] Gemini network error: $e');
      return (batch: null, reason: 'network', detail: e.toString());
    }
    if (resp.statusCode != 200) {
      debugPrint('[SmartImport] Gemini ${resp.statusCode}: ${resp.body}');
      return (
        batch: null,
        reason: 'http_${resp.statusCode}',
        detail: _truncate(resp.body, 400),
      );
    }

    try {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final text = ((data['candidates'] as List?)?.firstOrNull?['content']
              ?['parts'] as List?)?.firstOrNull?['text'] as String?;
      if (text == null || text.isEmpty) {
        return (batch: null, reason: 'empty', detail: null);
      }

      final parsed = _parseLooseJson(text);
      if (parsed == null) {
        return (batch: null, reason: 'bad_json', detail: _truncate(text, 200));
      }
      final batch = _unwrapBatch(parsed);
      if (batch.orders.isEmpty) {
        // Genuine parse but Gemini decided nothing was an order (e.g. a
        // question / thank-you message). Return an empty batch — the UI
        // surfaces "no orders detected" to the admin.
        return (batch: batch, reason: 'ok', detail: null);
      }
      return (batch: batch, reason: 'ok', detail: null);
    } catch (e) {
      debugPrint('[SmartImport] Gemini parse failed: $e');
      return (batch: null, reason: 'internal', detail: e.toString());
    }
  }

  /// Strip Markdown fences + pull the first JSON object out of Gemini's
  /// reply. Returns null on unrecoverable malformed output.
  static Map<String, dynamic>? _parseLooseJson(String raw) {
    final cleaned = raw
        .replaceAll('```json', '')
        .replaceAll('```', '')
        .trim();
    try {
      return jsonDecode(cleaned) as Map<String, dynamic>;
    } catch (_) {
      final s = cleaned.indexOf('{');
      final e = cleaned.lastIndexOf('}');
      if (s == -1 || e == -1 || e < s) return null;
      try {
        return jsonDecode(cleaned.substring(s, e + 1)) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }
  }

  /// Build a [SmartImportBatch] from Gemini's parsed JSON. Handles BOTH:
  ///   * new shape: `{"orders": [ {customer, line_items, ...}, ... ]}`
  ///   * legacy shape (single order): `{"customer": {...}, "line_items": [...], ...}`
  ///     — wrapped into a 1-element batch for back-compat during the prompt
  ///     rollout window.
  static SmartImportBatch _unwrapBatch(Map<String, dynamic> json) {
    final rawOrders = json['orders'];
    final orderMaps = <Map>[];
    if (rawOrders is List) {
      for (final o in rawOrders) {
        if (o is Map) orderMaps.add(o);
      }
    } else {
      // Legacy single-order shape — the prompt pre-rewrite contract.
      orderMaps.add(json);
    }
    final drafts = orderMaps.map(_draftFromMap).toList();
    // Batch confidence: prefer an explicit batch-level value, else average.
    final explicit = (json['overall_parse_confidence'] as num?)?.toDouble();
    final avg = drafts.isEmpty
        ? 0.0
        : drafts.map((d) => d.overallConfidence).reduce((a, b) => a + b) /
            drafts.length;
    return SmartImportBatch(
      orders: drafts,
      overallConfidence: explicit ?? avg,
    );
  }

  /// Construct a single [SmartImportDraft] from one per-order map.
  static SmartImportDraft _draftFromMap(Map order) {
    final cust = (order['customer'] as Map?) ?? {};
    final lines = (order['line_items'] as List? ?? []).map((l) {
      final m = l as Map;
      return SmartImportDraftLine(
        nameAsWritten: (m['name_as_written'] as String? ?? '').trim(),
        eanCode: m['ean_code'] as String?,
        quantity: (m['quantity'] as num?)?.toInt() ?? 0,
        unitHint: m['unit_hint'] as String?,
        confidence: (m['confidence'] as num?)?.toDouble() ?? 0.7,
      );
    }).where((l) => l.nameAsWritten.isNotEmpty && l.quantity > 0).toList();
    return SmartImportDraft(
      customerNameAsWritten: (cust['name_as_written'] as String? ?? '').trim(),
      customerPhoneFromInput: cust['phone_if_present'] as String?,
      deliveryDateHint: order['delivery_date_hint'] as String?,
      notes: order['notes'] as String?,
      lines: lines,
      overallConfidence:
          (order['overall_parse_confidence'] as num?)?.toDouble() ?? 0.7,
    );
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  // ─── GEMINI PARSE (pdf + image screenshot) ───────────────────────────

  static const String _pdfPrompt = r'''
You are a parsing assistant for a wholesale distributor's order system.
You are given a purchase-order PDF. Usually ONE order per PDF, but some
PDFs bundle 2+ POs for different stores (e.g. chain store central POs
split by outlet). Extract each order separately.

OUTPUT FORMAT — STRICT JSON, NO PROSE, NO MARKDOWN FENCES:
{
  "orders": [
    {
      "customer": {
        "name_as_written": "exact text from header",
        "phone_if_present": "string or null"
      },
      "delivery_date_hint": "string or null",
      "notes": "freeform PO notes, or null",
      "line_items": [
        {
          "name_as_written": "product name / description as printed",
          "ean_code": "13-digit EAN if a barcode or EAN column is shown, else null",
          "quantity": 10,
          "unit_hint": "pc | pcs | box | ctn | null",
          "confidence": 0.95
        }
      ],
      "overall_parse_confidence": 0.9
    }
  ]
}

SPLITTING INTO MULTIPLE ORDERS:
- If the PDF has 2+ distinct "Ship To" / "Store" sections each with
  their own line items, emit one element per store in "orders".
- Otherwise (the overwhelmingly common case) emit a 1-element array.
- Never merge two stores into one "customer".

LINE RULES (apply per order):
- EAN / barcode column is gold — always extract it when present. Our
  system does exact EAN matching before falling back to name matching.
- Do NOT invent items. Only rows present in the PO.
- If a row has both Ordered Qty and Accepted Qty, use Ordered Qty.
- Free-goods / bonus rows: emit as separate line items only if a real
  quantity is present and not obviously a scheme description.
- MRP, rate, and discount columns are NOT quantities.
- JSON only.
''';

  static const String _screenshotPrompt = r'''
You are a parsing assistant for a wholesale distributor's order system.
You are given a screenshot of a spreadsheet or brand-software table
exported by the customer. A single screenshot may cover ONE order or
MULTIPLE orders (e.g. multi-store rollup with customer rows separated
by subtotal lines). Extract each order separately.

OUTPUT FORMAT — STRICT JSON, NO PROSE, NO MARKDOWN FENCES:
{
  "orders": [
    {
      "customer": {
        "name_as_written": "best guess from header/visible context, or empty string",
        "phone_if_present": "string or null"
      },
      "delivery_date_hint": "string or null",
      "notes": "any freeform context seen (scheme %, due date, etc.), or null",
      "line_items": [
        {
          "name_as_written": "exact product nickname / description",
          "ean_code": "string or null",
          "quantity": 5,
          "unit_hint": "pc | pcs | ladi | box | null",
          "confidence": 0.85
        }
      ],
      "overall_parse_confidence": 0.8
    }
  ]
}

SPLITTING INTO MULTIPLE ORDERS:
- If the screenshot shows 2+ distinct customer rows each with its own
  set of lines (or a pivot-style multi-customer rollup), emit one
  element per customer in "orders".
- Otherwise emit a 1-element "orders" array.

LINE RULES (apply per order):
- Identify the ORDER quantity column. Common headers: Order / Qty /
  Ordered / To Ship. IGNORE "Stock", "Balance", "On Hand" columns —
  those are NOT order quantities.
- Scheme/discount % columns (e.g. "Scheme%", "Disc%") are NOT
  quantities. If relevant, mention in notes instead.
- If the order quantity is blank or 0 for a row, SKIP that row entirely.
- Lower confidence on any row where the column alignment is ambiguous.
- JSON only.
''';

  /// Parse an image screenshot OR a PDF. Returns the FIRST order for
  /// back-compat; multi-order callers should use [parseBatchFromBytesDetailed].
  Future<SmartImportDraft?> parseFromBytes({
    required Uint8List bytes,
    required String mimeType,
    required String inputType,
  }) async {
    final r = await parseFromBytesDetailed(
      bytes: bytes, mimeType: mimeType, inputType: inputType);
    return r.draft;
  }

  Future<({SmartImportDraft? draft, String reason, String? detail})>
      parseFromBytesDetailed({
    required Uint8List bytes,
    required String mimeType,
    required String inputType,
  }) async {
    final r = await parseBatchFromBytesDetailed(
      bytes: bytes, mimeType: mimeType, inputType: inputType);
    final draft = (r.batch == null || r.batch!.orders.isEmpty)
        ? null
        : r.batch!.orders.first;
    return (draft: draft, reason: r.reason, detail: r.detail);
  }

  /// Multi-order parse from image/PDF bytes. Returns a [SmartImportBatch]
  /// whose `orders` list has 1..N entries. A handwritten slip with 3
  /// distinct customers → 3 orders here.
  Future<({SmartImportBatch? batch, String reason, String? detail})>
      parseBatchFromBytesDetailed({
    required Uint8List bytes,
    required String mimeType,
    required String inputType,
  }) async {
    final key = await _getGeminiKey();
    if (key.isEmpty) {
      debugPrint('[SmartImport] GEMINI_API_KEY missing');
      return (batch: null, reason: 'no_key', detail: null);
    }
    final prompt = switch (inputType) {
      'pdf' => _pdfPrompt,
      'image_screenshot' => _screenshotPrompt,
      'image_handwritten' => _handwrittenPrompt,
      _ => _screenshotPrompt,
    };

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': mimeType,
                'data': base64Encode(bytes),
              },
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.1,
        // PDFs and image OCR tend to produce longer output; generous cap.
        'maxOutputTokens': 32768,
      },
    });

    // PDFs + high-res images legitimately take longer than text. 120s
    // so a 30-page PO has time to return.
    const timeout = Duration(seconds: 120);
    return _callGeminiAndBuildBatch(body, timeout);
  }

  // ─── ALIAS ADMIN (list + delete) ─────────────────────────────────────

  /// List product aliases for the team. Joined with products for display of
  /// the matched product name; admin UI shows one row per alias.
  /// [search] filters by alias_text substring (case-insensitive).
  Future<List<Map<String, dynamic>>> listProductAliases({
    required String teamId,
    String? search,
  }) async {
    try {
      var q = _client
          .from('product_alias_learning')
          .select('id, customer_id, alias_text, matched_product_id, '
              'confidence_score, last_used_at, created_at, '
              'products(name, sku), customers(name)')
          .eq('team_id', teamId);
      if (search != null && search.trim().isNotEmpty) {
        q = q.ilike('alias_text', '%${search.trim().toLowerCase()}%');
      }
      final resp = await q.order('last_used_at', ascending: false).limit(200);
      return (resp as List).map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (e) {
      debugPrint('[SmartImport] listProductAliases failed: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> listCustomerAliases({
    required String teamId,
    String? search,
  }) async {
    try {
      var q = _client
          .from('customer_alias_learning')
          .select('id, alias_text, matched_customer_id, confidence_score, '
              'last_used_at, created_at, customers(name, phone)')
          .eq('team_id', teamId);
      if (search != null && search.trim().isNotEmpty) {
        q = q.ilike('alias_text', '%${search.trim().toLowerCase()}%');
      }
      final resp = await q.order('last_used_at', ascending: false).limit(200);
      return (resp as List).map((r) => Map<String, dynamic>.from(r)).toList();
    } catch (e) {
      debugPrint('[SmartImport] listCustomerAliases failed: $e');
      return [];
    }
  }

  Future<void> deleteProductAlias(String id) async {
    await _client.from('product_alias_learning').delete().eq('id', id);
  }

  Future<void> deleteCustomerAlias(String id) async {
    await _client.from('customer_alias_learning').delete().eq('id', id);
  }

  // ─── CSV EXPORT / IMPORT (Phase 6) ───────────────────────────────────

  /// Returns CSV rows (header first) for the product-alias table in [teamId].
  /// Ready to hand to csv.ListToCsvConverter().convert(rows).
  Future<List<List<String>>> exportProductAliasRows(String teamId) async {
    final resp = await _client
        .from('product_alias_learning')
        .select('alias_text, customer_id, matched_product_id, '
            'confidence_score, last_used_at, '
            'products(name, sku), customers(name)')
        .eq('team_id', teamId);
    final rows = <List<String>>[
      ['alias_text', 'customer_id', 'customer_name',
       'matched_product_id', 'matched_product_name', 'matched_product_sku',
       'confidence_score', 'last_used_at'],
    ];
    for (final r in resp as List) {
      final m = Map<String, dynamic>.from(r);
      final prod = (m['products'] as Map?) ?? {};
      final cust = (m['customers'] as Map?);
      rows.add([
        (m['alias_text'] ?? '').toString(),
        (m['customer_id'] ?? '').toString(),
        (cust?['name'] ?? '').toString(),
        (m['matched_product_id'] ?? '').toString(),
        (prod['name'] ?? '').toString(),
        (prod['sku'] ?? '').toString(),
        (m['confidence_score'] ?? 1).toString(),
        (m['last_used_at'] ?? '').toString(),
      ]);
    }
    return rows;
  }

  Future<List<List<String>>> exportCustomerAliasRows(String teamId) async {
    final resp = await _client
        .from('customer_alias_learning')
        .select('alias_text, matched_customer_id, confidence_score, '
            'last_used_at, customers(name, phone)')
        .eq('team_id', teamId);
    final rows = <List<String>>[
      ['alias_text', 'matched_customer_id', 'matched_customer_name',
       'matched_customer_phone', 'confidence_score', 'last_used_at'],
    ];
    for (final r in resp as List) {
      final m = Map<String, dynamic>.from(r);
      final cust = (m['customers'] as Map?) ?? {};
      rows.add([
        (m['alias_text'] ?? '').toString(),
        (m['matched_customer_id'] ?? '').toString(),
        (cust['name'] ?? '').toString(),
        (cust['phone'] ?? '').toString(),
        (m['confidence_score'] ?? 1).toString(),
        (m['last_used_at'] ?? '').toString(),
      ]);
    }
    return rows;
  }

  /// Import rows into product_alias_learning. Uses writeProductAlias under
  /// the hood so the 23505-bump behavior is consistent with online writes.
  /// Returns (inserted, skipped, errorMessages).
  Future<({int inserted, int skipped, List<String> errors})>
      importProductAliasRows({
    required List<List<dynamic>> rows,
    required String teamId,
    required String adminUserId,
  }) async {
    if (rows.isEmpty) return (inserted: 0, skipped: 0, errors: <String>[]);
    // Accept rows whose first row is the header — drop it.
    var body = rows;
    final header = rows.first.map((c) => c.toString().trim().toLowerCase()).toList();
    if (header.contains('alias_text')) body = rows.sublist(1);

    int inserted = 0;
    int skipped = 0;
    final errors = <String>[];

    for (var i = 0; i < body.length; i++) {
      final r = body[i];
      if (r.length < 4) {
        skipped++;
        errors.add('row ${i + 2}: expected ≥4 columns, got ${r.length}');
        continue;
      }
      final alias = r[0].toString().trim();
      final rawCustId = r[1].toString().trim();
      final customerId = rawCustId.isEmpty ? null : rawCustId;
      final productId = r[3].toString().trim();
      if (alias.isEmpty || productId.isEmpty) {
        skipped++;
        errors.add('row ${i + 2}: alias_text and matched_product_id required');
        continue;
      }
      try {
        await writeProductAlias(
          customerId: customerId,
          aliasText: alias,
          productId: productId,
          teamId: teamId,
          createdByUserId: adminUserId,
        );
        inserted++;
      } catch (e) {
        skipped++;
        errors.add('row ${i + 2}: $e');
      }
    }
    return (inserted: inserted, skipped: skipped, errors: errors);
  }

  Future<({int inserted, int skipped, List<String> errors})>
      importCustomerAliasRows({
    required List<List<dynamic>> rows,
    required String teamId,
    required String adminUserId,
  }) async {
    if (rows.isEmpty) return (inserted: 0, skipped: 0, errors: <String>[]);
    var body = rows;
    final header = rows.first.map((c) => c.toString().trim().toLowerCase()).toList();
    if (header.contains('alias_text')) body = rows.sublist(1);

    int inserted = 0;
    int skipped = 0;
    final errors = <String>[];

    for (var i = 0; i < body.length; i++) {
      final r = body[i];
      if (r.length < 2) {
        skipped++;
        errors.add('row ${i + 2}: expected ≥2 columns, got ${r.length}');
        continue;
      }
      final alias = r[0].toString().trim();
      final customerId = r[1].toString().trim();
      if (alias.isEmpty || customerId.isEmpty) {
        skipped++;
        errors.add('row ${i + 2}: alias_text and matched_customer_id required');
        continue;
      }
      try {
        await writeCustomerAlias(
          aliasText: alias,
          customerId: customerId,
          teamId: teamId,
          createdByUserId: adminUserId,
        );
        inserted++;
      } catch (e) {
        skipped++;
        errors.add('row ${i + 2}: $e');
      }
    }
    return (inserted: inserted, skipped: skipped, errors: errors);
  }

  // ─── HELPERS ─────────────────────────────────────────────────────────

  String _normalizeAlias(String raw) {
    return raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Simple token-overlap similarity, 0..1. Good enough for the first cut;
  /// can be replaced with trigram-pg_trgm via RPC later.
  double _similarity(String a, String b) {
    final aTokens = searchTokens(a).toSet();
    final bTokens = searchTokens(b).toSet();
    if (aTokens.isEmpty || bTokens.isEmpty) return 0.0;
    final inter = aTokens.intersection(bTokens);
    final union = aTokens.union(bTokens);
    return inter.length / union.length;
  }

  String? get currentAdminUserId => _client.auth.currentUser?.id;
  String get currentTeam => AuthService.currentTeam;
}
