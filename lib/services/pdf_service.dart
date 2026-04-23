import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'supabase_service.dart';
import '../models/models.dart';

class PdfService {
  // Brand Colors matching your AppTheme
  static final PdfColor primaryColor = PdfColor.fromHex('#2563EB'); // Deep Blue
  static final PdfColor secondaryColor = PdfColor.fromHex('#1E3A8A'); // Darker Blue
  static final PdfColor lightBgColor = PdfColor.fromHex('#F3F4F6'); // Light Gray

  // The Outstanding sheet is printed today but used by the rep on the next
  // working day for collection. So the header date should be that day, not
  // today. Friday/Saturday/Sunday prints all roll forward to Monday.
  static DateTime _nextWorkingDay() {
    var d = DateTime.now().add(const Duration(days: 1));
    while (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
      d = d.add(const Duration(days: 1));
    }
    return d;
  }

  // Cached fonts for Unicode support (₹ symbol etc.)
  static pw.Font? _regularFont;
  static pw.Font? _boldFont;

  static Future<pw.Font> get regularFont async =>
      _regularFont ??= await PdfGoogleFonts.notoSansRegular();
  static Future<pw.Font> get boldFont async =>
      _boldFont ??= await PdfGoogleFonts.notoSansBold();
  static final PdfColor textColor = PdfColor.fromHex('#1F2937'); // Dark Gray

  // Filter orders in-place to only line items whose product's category is in
  // `allowedBrands`. Returns the filtered orders (each with a recomputed
  // grand_total from the remaining items). Orders with zero matching items
  // are dropped. Unknown-category items are excluded (conservative).
  static Future<List<Map<String, dynamic>>> _scopeOrdersToBrands(
    List<Map<String, dynamic>> orders,
    List<String> allowedBrands,
  ) async {
    if (allowedBrands.isEmpty) return orders;
    final productIds = orders
        .expand((o) => (o['order_items'] as List?) ?? [])
        .map((it) => (it as Map)['product_id'])
        .whereType<String>()
        .toSet()
        .toList();
    final Map<String, String> categoryMap = {};
    if (productIds.isNotEmpty) {
      final rows = await SupabaseService.instance.client
          .from('products')
          .select('id, category')
          .inFilter('id', productIds);
      for (final r in rows as List) {
        final id = (r as Map)['id'] as String?;
        final cat = r['category'] as String?;
        if (id != null && cat != null) categoryMap[id] = cat;
      }
    }
    final scoped = <Map<String, dynamic>>[];
    for (final o in orders) {
      final items = (o['order_items'] as List?) ?? [];
      final keptItems = items.where((it) {
        final pid = (it as Map)['product_id'] as String?;
        if (pid == null) return false;
        final cat = categoryMap[pid];
        return cat != null && allowedBrands.contains(cat);
      }).toList();
      if (keptItems.isEmpty) continue;
      double newTotal = 0;
      for (final it in keptItems) {
        newTotal += ((it as Map)['line_total'] ?? it['total_price'] ?? 0).toDouble();
      }
      scoped.add({
        ...o,
        'order_items': keptItems,
        'grand_total': newTotal,
      });
    }
    return scoped;
  }

  // ─── DAILY REPORT GENERATOR ──────────────────────────────────────────────
  static Future<void> generateAndShareOrderReport(
    DateTime date, {
    List<String>? teamIds,
    List<String>? allowedBrands,
  }) async {
    final pdf = pw.Document();
    final String formattedDate = DateFormat('dd-MM-yyyy').format(date);
    final String dateString = DateFormat('yyyy-MM-dd').format(date);

    // Force resync orders before exporting to get latest data
    await SupabaseService.instance.invalidateCache('recent_orders');

    List<Map<String, dynamic>> orders = await SupabaseService.instance
        .getOrdersByDate(dateString, teamIds: teamIds);

    final bool brandScoped = allowedBrands != null && allowedBrands.isNotEmpty;
    if (brandScoped) {
      orders = await _scopeOrdersToBrands(orders, allowedBrands);
    }

    if (orders.isEmpty) throw 'No orders found for $formattedDate';

    final regular = await regularFont;
    final bold = await boldFont;
    double grandTotal = 0;

    pdf.addPage(
      pw.MultiPage(
        theme: pw.ThemeData.withFont(base: regular, bold: bold),
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) {
          List<pw.Widget> content = [
            pw.Header(
              level: 0,
              decoration: pw.BoxDecoration(
                border: pw.Border(bottom: pw.BorderSide(color: primaryColor, width: 2)),
              ),
              child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Daily Order Report', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 24, color: primaryColor)),
                    pw.Text(formattedDate, style: const pw.TextStyle(fontSize: 16)),
                  ]
              ),
            ),
            if (brandScoped)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 6),
                child: pw.Text(
                  'Brand-scoped: ${allowedBrands.join(", ")}',
                  style: pw.TextStyle(fontSize: 10, color: secondaryColor, fontStyle: pw.FontStyle.italic),
                ),
              ),
            pw.SizedBox(height: 20),
          ];

          for (var order in orders) {
            grandTotal += (order['grand_total'] ?? 0).toDouble();
            final items = order['order_items'] as List<dynamic>? ?? [];

            content.add(
                pw.Container(
                  color: lightBgColor,
                  padding: const pw.EdgeInsets.all(8),
                  child: pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Order #${order['id'].toString().substring(0, 8).toUpperCase()} - ${order['customer_name']}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: secondaryColor)),
                        pw.Text('Status: ${order['status']}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      ]
                  ),
                )
            );

            if (items.isNotEmpty) {
              content.add(
                  pw.TableHelper.fromTextArray(
                    cellPadding: const pw.EdgeInsets.all(6),
                    headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10, color: PdfColors.white),
                    headerDecoration: pw.BoxDecoration(color: primaryColor),
                    cellStyle: const pw.TextStyle(fontSize: 10),
                    headers: ['Product', 'Qty', 'MRP', 'Price', 'Total'],
                    data: items.map((item) {
                      final product = item['products'] ?? {};
                      final price = item['unit_price'] ?? item['price_per_unit'] ?? 0.0;
                      final mrp = item['mrp'] ?? product['mrp'] ?? 0.0;
                      final total = item['line_total'] ?? item['total_price'] ?? 0.0;
                      return [
                        item['product_name'] ?? product['name'] ?? 'Unknown Product',
                        item['quantity'].toString(),
                        mrp > 0 ? 'Rs. ${mrp.toStringAsFixed(2)}' : '-',
                        'Rs. ${price.toStringAsFixed(2)}',
                        'Rs. ${total.toStringAsFixed(2)}',
                      ];
                    }).toList(),
                  )
              );
            }

            content.add(
                pw.Container(
                  alignment: pw.Alignment.centerRight,
                  padding: const pw.EdgeInsets.only(top: 8, bottom: 20),
                  child: pw.Text('Order Total: Rs. ${order['grand_total']}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
                )
            );
          }

          content.add(pw.Divider(color: primaryColor, thickness: 1.5));
          content.add(pw.SizedBox(height: 10));
          content.add(
              pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Total Orders: ${orders.length}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16)),
                    pw.Text('Grand Total: Rs. ${grandTotal.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16, color: primaryColor)),
                  ]
              )
          );

          return content;
        },
      ),
    );

    await Printing.sharePdf(bytes: await pdf.save(), filename: 'MAJAA_Orders_$formattedDate.pdf');
  }

  /// Generate today's order report and return the temp file path for WhatsApp sharing.
  static Future<String> generateOrderReportFile(
    DateTime date, {
    List<String>? teamIds,
    List<String>? allowedBrands,
  }) async {
    // Force resync
    await SupabaseService.instance.invalidateCache('recent_orders');

    final String formattedDate = DateFormat('dd-MM-yyyy').format(date);
    final String dateString = DateFormat('yyyy-MM-dd').format(date);
    var orders = await SupabaseService.instance.getOrdersByDate(dateString, teamIds: teamIds);
    final bool brandScoped = allowedBrands != null && allowedBrands.isNotEmpty;
    if (brandScoped) {
      orders = await _scopeOrdersToBrands(orders, allowedBrands);
    }
    if (orders.isEmpty) throw 'No orders found for $formattedDate';

    double grandTotal = 0;
    final regular = await regularFont;
    final bold = await boldFont;
    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        theme: pw.ThemeData.withFont(base: regular, bold: bold),
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) {
          List<pw.Widget> content = [
            pw.Header(
              level: 0,
              decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: primaryColor, width: 2))),
              child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                pw.Text('Daily Order Report', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 24, color: primaryColor)),
                pw.Text(formattedDate, style: const pw.TextStyle(fontSize: 16)),
              ]),
            ),
            if (brandScoped)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 6),
                child: pw.Text(
                  'Brand-scoped: ${allowedBrands.join(", ")}',
                  style: pw.TextStyle(fontSize: 10, color: secondaryColor, fontStyle: pw.FontStyle.italic),
                ),
              ),
            pw.SizedBox(height: 20),
          ];
          for (var order in orders) {
            grandTotal += (order['grand_total'] ?? 0).toDouble();
            final items = order['order_items'] as List<dynamic>? ?? [];
            content.add(pw.Container(
              color: lightBgColor, padding: const pw.EdgeInsets.all(8),
              child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                pw.Text('${order['customer_name']}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: secondaryColor)),
                pw.Text('Rs. ${order['grand_total']}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              ]),
            ));
            if (items.isNotEmpty) {
              content.add(pw.TableHelper.fromTextArray(
                cellPadding: const pw.EdgeInsets.all(6),
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10, color: PdfColors.white),
                headerDecoration: pw.BoxDecoration(color: primaryColor),
                cellStyle: const pw.TextStyle(fontSize: 10),
                headers: ['Product', 'Qty', 'MRP', 'Price', 'Total'],
                data: items.map((item) {
                  final product = item['products'] ?? {};
                  final price = item['unit_price'] ?? item['price_per_unit'] ?? 0.0;
                  final mrp = item['mrp'] ?? product['mrp'] ?? 0.0;
                  final total = item['line_total'] ?? item['total_price'] ?? 0.0;
                  return [
                    item['product_name'] ?? product['name'] ?? 'Unknown',
                    item['quantity'].toString(),
                    mrp > 0 ? 'Rs. ${mrp.toStringAsFixed(2)}' : '-',
                    'Rs. ${price.toStringAsFixed(2)}',
                    'Rs. ${total.toStringAsFixed(2)}',
                  ];
                }).toList(),
              ));
            }
            content.add(pw.SizedBox(height: 12));
          }
          content.add(pw.Divider(color: primaryColor, thickness: 1.5));
          content.add(pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('Total Orders: ${orders.length}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16)),
            pw.Text('Grand Total: Rs. ${grandTotal.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16, color: primaryColor)),
          ]));
          return content;
        },
      ),
    );

    final pdfBytes = await pdf.save();
    if (kIsWeb) {
      await Printing.sharePdf(bytes: pdfBytes, filename: 'MAJAA_Orders_$formattedDate.pdf');
      return 'MAJAA_Orders_$formattedDate.pdf';
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/MAJAA_Orders_$formattedDate.pdf');
    await file.writeAsBytes(pdfBytes);
    return file.path;
  }

  // ─── SINGLE INVOICE GENERATOR ────────────────────────────────────────────
  static Future<void> generateCustomerInvoice(Map<String, dynamic> order) async {
    final regular = await regularFont;
    final bold = await boldFont;
    final pdf = pw.Document(theme: pw.ThemeData.withFont(base: regular, bold: bold));

    final String orderId = order['id'].toString().substring(0, 8).toUpperCase();
    final String customerName = order['customer_name'] ?? 'Valued Customer';
    final items = order['order_items'] as List<dynamic>? ?? [];
    final String currentDate = DateFormat('dd MMM yyyy').format(DateTime.now());

    // Auto-calculate subtotal to separate tax cleanly on the invoice
    double subtotal = 0.0;
    for (var item in items) {
      subtotal += (item['line_total'] ?? item['total_price'] ?? 0.0).toDouble();
    }
    final double grandTotal = (order['grand_total'] ?? subtotal).toDouble();
    final double estTax = grandTotal - subtotal;

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [

              // ─── HEADER ROW ───
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('M.A.J.A.A.', style: pw.TextStyle(fontSize: 32, fontWeight: pw.FontWeight.bold, color: primaryColor, letterSpacing: 2)),
                      pw.SizedBox(height: 4),
                      pw.Text('Madhav & Jagannath Associates', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: textColor)),
                      pw.Text('123 Distribution Hub, Market Yard', style: pw.TextStyle(fontSize: 10, color: textColor)),
                      pw.Text('GSTIN: 05XXXXX1234X1Z5', style: pw.TextStyle(fontSize: 10, color: textColor)),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text('TAX INVOICE', style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold, color: secondaryColor, letterSpacing: 1)),
                      pw.SizedBox(height: 8),
                      pw.Text('Date: $currentDate', style: const pw.TextStyle(fontSize: 11)),
                      pw.Text('Invoice #: INV-$orderId', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
                    ],
                  ),
                ],
              ),

              pw.SizedBox(height: 30),
              pw.Divider(color: lightBgColor, thickness: 2),
              pw.SizedBox(height: 20),

              // ─── BILLED TO SECTION ───
              pw.Container(
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  color: lightBgColor,
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Row(
                  children: [
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text('BILLED TO:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10, color: secondaryColor)),
                          pw.SizedBox(height: 4),
                          pw.Text(customerName, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: textColor)),
                          if (order['beat_name'] != null && order['beat_name'].toString().isNotEmpty)
                            pw.Text('Route: ${order['beat_name']}', style: pw.TextStyle(fontSize: 11, color: textColor)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              pw.SizedBox(height: 30),

              // ─── ITEMS TABLE ───
              if (items.isNotEmpty)
                pw.TableHelper.fromTextArray(
                  headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 11),
                  headerDecoration: pw.BoxDecoration(color: primaryColor),
                  cellPadding: const pw.EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  cellStyle: pw.TextStyle(fontSize: 10, color: textColor),
                  rowDecoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: lightBgColor))),
                  headers: ['Item Description', 'Qty', 'MRP', 'Unit Price', 'Total'],
                  cellAlignments: {
                    0: pw.Alignment.centerLeft,
                    1: pw.Alignment.center,
                    2: pw.Alignment.centerRight,
                    3: pw.Alignment.centerRight,
                    4: pw.Alignment.centerRight,
                  },
                  data: _invoiceRows(items),
                )
              else
                pw.Text('No items found in this order.', style: const pw.TextStyle(color: PdfColors.red)),

              pw.SizedBox(height: 20),

              // ─── FINANCIAL TOTALS ───
              pw.Container(
                alignment: pw.Alignment.centerRight,
                child: pw.Container(
                  width: 200,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('Subtotal:', style: pw.TextStyle(fontSize: 11, color: textColor)),
                          pw.Text('Rs. ${subtotal.toStringAsFixed(2)}', style: pw.TextStyle(fontSize: 11, color: textColor)),
                        ],
                      ),
                      pw.SizedBox(height: 6),
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('Estimated GST:', style: pw.TextStyle(fontSize: 11, color: textColor)),
                          pw.Text('Rs. ${estTax.toStringAsFixed(2)}', style: pw.TextStyle(fontSize: 11, color: textColor)),
                        ],
                      ),
                      pw.SizedBox(height: 8),
                      pw.Divider(color: primaryColor),
                      pw.SizedBox(height: 4),
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('GRAND TOTAL', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: secondaryColor)),
                          pw.Text('Rs. ${grandTotal.toStringAsFixed(2)}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: secondaryColor)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              pw.Spacer(),

              // ─── FOOTER ───
              pw.Divider(color: lightBgColor, thickness: 2),
              pw.SizedBox(height: 10),
              pw.Center(
                  child: pw.Column(
                      children: [
                        pw.Text('Thank you for your business!', style: pw.TextStyle(fontStyle: pw.FontStyle.italic, fontSize: 12, color: primaryColor, fontWeight: pw.FontWeight.bold)),
                        pw.SizedBox(height: 4),
                        pw.Text('For any queries regarding this invoice, please contact support.', style: pw.TextStyle(fontSize: 9, color: textColor)),
                      ]
                  )
              ),
            ],
          );
        },
      ),
    );

    await Printing.sharePdf(
      bytes: await pdf.save(),
      filename: 'MAJAA_Invoice_$orderId.pdf',
    );
  }

  /// Flattens order_items into table rows. A line with `free_qty > 0`
  /// expands to two rows: the paid line + a "FREE: N × item (SCHEME)"
  /// zero-rate line, matching DUA's printed invoice layout.
  static List<List<String>> _invoiceRows(List<dynamic> items) {
    final rows = <List<String>>[];
    for (final item in items) {
      final product = item['products'] ?? {};
      final name = product['name'] ?? item['product_name'] ?? 'Unknown Item';
      final price = item['unit_price'] ?? item['price_per_unit'] ?? 0.0;
      final mrp = item['mrp'] ?? product['mrp'] ?? 0.0;
      final total = item['line_total'] ?? item['total_price'] ?? 0.0;
      rows.add([
        name.toString(),
        item['quantity'].toString(),
        mrp > 0 ? 'Rs. ${mrp.toStringAsFixed(2)}' : '-',
        'Rs. ${price.toStringAsFixed(2)}',
        'Rs. ${total.toStringAsFixed(2)}',
      ]);
      final freeQty = (item['free_qty'] as num?)?.toInt() ?? 0;
      if (freeQty > 0) {
        rows.add([
          '   ↳ FREE: $name (SCHEME)',
          freeQty.toString(),
          '-',
          'Rs. 0.00',
          'Rs. 0.00',
        ]);
      }
    }
    return rows;
  }

  // ─── OUTSTANDING REPORT (Areawise — exact billing software format) ──────────

  static Future<List<int>> generateOutstandingReportBytes({
    required List<CustomerModel> customers,
    required List<Map<String, dynamic>> allBills,
    required String teamId,
    List<String>? beatNames,
    // Unallocated CN/receipt balances. Optional for backward compat — if
    // omitted, the PDF renders without the advance lines (same behavior as
    // before the Phase B changes).
    List<Map<String, dynamic>>? advances,
    List<Map<String, dynamic>>? creditNotes,
    // Cross-team: optional second team report on a new page
    String? crossTeamId,
    List<Map<String, dynamic>>? crossTeamBills,
    List<String>? crossTeamBeatNames,
    List<Map<String, dynamic>>? crossTeamAdvances,
    List<Map<String, dynamic>>? crossTeamCreditNotes,
  }) async {
    final pdf = pw.Document();
    final regular = await regularFont;
    final bold = await boldFont;
    final baseTheme = pw.ThemeData.withFont(base: regular, bold: bold);

    // Add primary team pages
    final primaryAdded =
        _addOutstandingPages(pdf, baseTheme, customers, allBills, teamId, beatNames,
            advances: advances, creditNotes: creditNotes);

    // Add cross-team pages on new page if provided
    bool crossAdded = false;
    if (crossTeamId != null && crossTeamBills != null) {
      crossAdded = _addOutstandingPages(pdf, baseTheme, customers, crossTeamBills, crossTeamId, crossTeamBeatNames,
          advances: crossTeamAdvances, creditNotes: crossTeamCreditNotes);
    }

    // If no team produced any pages, a 0-page PDF is corrupt on every reader
    // (share preview, WhatsApp, Drive) — users see "can't open". Render a
    // visible fallback so the file is always valid.
    if (!primaryAdded && !crossAdded) {
      final printedFor = DateFormat('dd.MM.yyyy').format(_nextWorkingDay());
      final teamName = teamId == 'JA' ? 'JAGANNATH ASSOCIATES' : 'MADHAV ASSOCIATES';
      pdf.addPage(pw.Page(
        theme: baseTheme,
        pageFormat: PdfPageFormat.a4,
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(teamName,
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13, color: primaryColor)),
            pw.Text('CUSTOMER OUTSTANDING  FOR $printedFor',
                style: const pw.TextStyle(fontSize: 9)),
            if (beatNames != null && beatNames.isNotEmpty)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 2),
                child: pw.Text('BEATS: ${beatNames.join(' | ')}',
                    style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: primaryColor)),
              ),
            pw.Divider(color: primaryColor, thickness: 1.5),
            pw.SizedBox(height: 40),
            pw.Center(
              child: pw.Text('No outstanding bills for the selected beats.',
                  style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
            ),
          ],
        ),
      ));
    }

    return await pdf.save();
  }

  /// Helper: adds one team's outstanding report as MultiPage(s) to the document.
  /// Returns true if at least one page was added (i.e. byBeat wasn't empty),
  /// false if no data was found for this team. The caller uses the return
  /// value to decide whether to render a fallback page so the final PDF is
  /// never 0-page (which readers treat as corrupt).
  static bool _addOutstandingPages(
    pw.Document pdf,
    pw.ThemeData baseTheme,
    List<CustomerModel> customers,
    List<Map<String, dynamic>> allBills,
    String teamId,
    List<String>? beatNames, {
    List<Map<String, dynamic>>? advances,
    List<Map<String, dynamic>>? creditNotes,
  }) {
    final printedFor = DateFormat('dd.MM.yyyy').format(_nextWorkingDay());
    final teamName = teamId == 'JA' ? 'JAGANNATH ASSOCIATES' : 'MADHAV ASSOCIATES';
    final fs = pw.TextStyle(fontSize: 8);
    final fsBold = pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold);

    // Build bill lookup first — need it to check who has pending bills
    final Map<String, List<Map<String, dynamic>>> billsByCustomer = {};
    for (final bill in allBills) {
      final custId = bill['customer_id'] as String? ?? '';
      if (custId.isEmpty) continue;
      final pending = (bill['pending_amount'] as num?)?.toDouble() ?? 0;
      if (pending <= 0) continue;
      billsByCustomer.putIfAbsent(custId, () => []);
      billsByCustomer[custId]!.add(bill);
    }

    // Advances per customer, and CN metadata lookup by rectvno so we can
    // label CN-origin advances with "CR NOTE-{cn_number}" and their CN date.
    // Receipt-origin advances (no matching CN) fall back to plain "ADVANCE".
    final Map<String, List<Map<String, dynamic>>> advancesByCustomer = {};
    if (advances != null) {
      for (final a in advances) {
        final custId = a['customer_id'] as String? ?? '';
        final amt = (a['amount'] as num?)?.toDouble() ?? 0;
        if (custId.isEmpty || amt == 0) continue;
        advancesByCustomer.putIfAbsent(custId, () => []).add(a);
      }
    }
    final Map<int, Map<String, dynamic>> cnByRectvno = {};
    if (creditNotes != null) {
      for (final cn in creditNotes) {
        final vno = cn['rectvno'];
        if (vno is int) cnByRectvno[vno] = cn;
      }
    }

    // Include a customer only when they have an actual pending bill or
    // an unallocated advance. DUA's native AREAWISE OUTSTANDING print is a
    // pure OPNBIL scan — a customer whose closing balance is carried by
    // pure ledger entries (opening balance offset by bank-reconciliation
    // JVs, etc.) doesn't appear there and shouldn't appear here either.
    //
    // Historical behaviour also included `outstanding > 0` from the
    // BILLED_COLLECTED snapshot. Removed 2026-04-21 after confirming this
    // was the source of "phantom" customers (BANWARI / DEHRA / REKHI /
    // VARDAAN on HANUMAN CHOWK summed to 129,320 of inflated total — all
    // cleared by 04-30 JVs the snapshot pre-dated).
    final Map<String, List<CustomerModel>> byBeat = {};
    for (final c in customers) {
      final beat = c.beatNameForTeam(teamId);
      if (beat.isEmpty) continue;
      if (beatNames != null && !beatNames.contains(beat)) continue;
      final hasPendingBills = billsByCustomer.containsKey(c.id);
      final hasAdvances = advancesByCustomer.containsKey(c.id);
      if (!hasPendingBills && !hasAdvances) continue;
      byBeat.putIfAbsent(beat, () => []);
      byBeat[beat]!.add(c);
    }

    if (byBeat.isEmpty) return false; // Skip if no data for this team

    final sortedBeats = byBeat.keys.toList()..sort();
    for (final beat in sortedBeats) {
      byBeat[beat]!.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }

    pdf.addPage(
      pw.MultiPage(
        theme: baseTheme,
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(18, 16, 18, 60),
        header: (context) => pw.Column(children: [
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text(teamName, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13, color: primaryColor)),
            pw.Text('Page ${context.pageNumber}', style: const pw.TextStyle(fontSize: 8)),
          ]),
          pw.Text('CUSTOMER OUTSTANDING  FOR $printedFor', style: const pw.TextStyle(fontSize: 9)),
          // Beat names below title
          if (beatNames != null && beatNames.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 2),
              child: pw.Text('BEATS: ${beatNames.join(' | ')}',
                  style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: primaryColor)),
            ),
          pw.Divider(color: primaryColor, thickness: 1.5),
          pw.SizedBox(height: 1),
          // Column headers
          pw.Row(children: [
            pw.SizedBox(width: 120, child: pw.Text('CUSTOMER NAME', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7.5))),
            pw.SizedBox(width: 52, child: pw.Text('BILL NO.', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7.5))),
            pw.SizedBox(width: 44, child: pw.Text('BILL\nDATE', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7))),
            pw.SizedBox(width: 22, child: pw.Text('BILL\nDAYS', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7), textAlign: pw.TextAlign.right)),
            pw.SizedBox(width: 44, child: pw.Text('BILL\nAMOUNT', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7), textAlign: pw.TextAlign.right)),
            pw.SizedBox(width: 38, child: pw.Text('RECD\nAMOUNT', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7), textAlign: pw.TextAlign.right)),
            pw.SizedBox(width: 44, child: pw.Text('BALANCE\nAMOUNT', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7), textAlign: pw.TextAlign.right)),
            pw.Expanded(child: pw.Text('UPI', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7), textAlign: pw.TextAlign.center)),
            pw.Expanded(child: pw.Text('CHQ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7), textAlign: pw.TextAlign.center)),
            pw.Expanded(child: pw.Text('CASH', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7), textAlign: pw.TextAlign.center)),
          ]),
          pw.Divider(thickness: 1),
        ]),
        build: (context) {
          final List<pw.Widget> content = [];
          double grandBillTotal = 0, grandRecdTotal = 0, grandBalanceTotal = 0;

          for (final beat in sortedBeats) {
            final beatCustomers = byBeat[beat]!;
            double areaBill = 0, areaRecd = 0, areaBalance = 0;

            // Beat header
            content.add(pw.SizedBox(height: 3));
            content.add(pw.Text('****** ${beat.toUpperCase()} ******',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: primaryColor)));
            content.add(pw.SizedBox(height: 1));

            for (final customer in beatCustomers) {
              final bills = billsByCustomer[customer.id] ?? [];
              double custBill = 0, custRecd = 0, custBalance = 0;
              final phone = customer.phone.isNotEmpty && customer.phone != 'No Phone' ? ', PH.${customer.phone}' : '';

              // Customer name line
              content.add(pw.Text('**** ${customer.name}$phone',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8)));

              if (bills.isNotEmpty) {
                // Sort bills oldest first (ascending by date)
                bills.sort((a, b) {
                  final da = a['bill_date'] as String? ?? '';
                  final db = b['bill_date'] as String? ?? '';
                  return da.compareTo(db);
                });
                for (final bill in bills) {
                  final inv = bill['invoice_no'] as String? ?? '';
                  final book = bill['book'] as String? ?? '';
                  final sman = bill['sman_name'] as String? ?? '';
                  final billNo = book.isNotEmpty ? '$book-$inv' : inv;
                  final billDate = bill['bill_date'] as String? ?? '';
                  final billAmt = (bill['bill_amount'] as num?)?.toDouble() ?? 0;
                  final recdAmt = (bill['received_amount'] as num?)?.toDouble() ?? 0;
                  final balance = (bill['pending_amount'] as num?)?.toDouble() ?? 0;
                  final dateStr = billDate.isNotEmpty ? DateFormat('dd.MM.yy').format(DateTime.parse(billDate)) : '';
                  final days = billDate.isNotEmpty ? DateTime.now().difference(DateTime.parse(billDate)).inDays : 0;

                  custBill += billAmt;
                  custRecd += recdAmt;
                  custBalance += balance;

                  content.add(pw.Padding(
                    padding: const pw.EdgeInsets.only(left: 8),
                    child: pw.Row(children: [
                      pw.SizedBox(width: 120, child: pw.Text(sman.isNotEmpty ? sman : '', style: fs)),
                      pw.SizedBox(width: 52, child: pw.Text(billNo, style: fs)),
                      pw.SizedBox(width: 44, child: pw.Text(dateStr, style: fs)),
                      pw.SizedBox(width: 22, child: pw.Text('$days', style: fs, textAlign: pw.TextAlign.right)),
                      pw.SizedBox(width: 44, child: pw.Text('${billAmt.toStringAsFixed(0)}', style: fs, textAlign: pw.TextAlign.right)),
                      pw.SizedBox(width: 38, child: pw.Text('${recdAmt.toStringAsFixed(0)}', style: fs, textAlign: pw.TextAlign.right)),
                      pw.SizedBox(width: 44, child: pw.Text('${balance.toStringAsFixed(0)}', style: fs, textAlign: pw.TextAlign.right)),
                      pw.Expanded(child: pw.Text('', style: fs)),
                      pw.Expanded(child: pw.Text('', style: fs)),
                      pw.Expanded(child: pw.Text('', style: fs)),
                    ]),
                  ));
                }
              }
              // No "(no bill details)" placeholder — the new inclusion rule
              // (line ~620) guarantees this customer has at least pending
              // bills OR advances. If bills is empty here, it means the
              // customer reached inclusion via advances alone; those are
              // rendered by the advance loop below with negative balance,
              // which is the correct presentation.

              // Render unallocated advances (CN-origin or receipt-origin) under
              // this customer's bills. Each row reduces custBalance by its
              // amount and adds to custRecd, so the TOTAL row naturally lands
              // on DUA's printed ledger balance. Label is "CR NOTE-N" when we
              // can cross-reference a credit note by rectvno; otherwise plain
              // "ADVANCE" (receipt-origin overpayment). Date + sman come from
              // the CN when matched — receipt-origin advances show blank.
              for (final adv in (advancesByCustomer[customer.id] ?? const [])) {
                final rectvno = adv['rectvno'] is int ? adv['rectvno'] as int : null;
                final amount = (adv['amount'] as num?)?.toDouble() ?? 0.0;
                if (amount == 0) continue;
                final matchedCn = rectvno != null ? cnByRectvno[rectvno] : null;

                String label = 'ADVANCE';
                String dateStr = '';
                String smanStr = '';
                if (matchedCn != null) {
                  final cnNum = matchedCn['cn_number'];
                  label = cnNum != null ? 'CR NOTE-$cnNum' : 'CR NOTE';
                  final cnDate = matchedCn['cn_date'] as String? ?? '';
                  if (cnDate.isNotEmpty) {
                    try {
                      dateStr = DateFormat('dd.MM.yy').format(DateTime.parse(cnDate));
                    } catch (_) {}
                  }
                  smanStr = (matchedCn['sman_name'] as String? ?? '').trim();
                }

                custRecd += amount;
                custBalance -= amount;

                content.add(pw.Padding(
                  padding: const pw.EdgeInsets.only(left: 8),
                  child: pw.Row(children: [
                    pw.SizedBox(width: 120, child: pw.Text(smanStr, style: fs)),
                    pw.SizedBox(width: 52, child: pw.Text(label, style: fs)),
                    pw.SizedBox(width: 44, child: pw.Text(dateStr, style: fs)),
                    pw.SizedBox(width: 22, child: pw.Text('', style: fs)),
                    pw.SizedBox(width: 44, child: pw.Text('', style: fs)),
                    pw.SizedBox(width: 38, child: pw.Text(amount.toStringAsFixed(0), style: fs, textAlign: pw.TextAlign.right)),
                    pw.SizedBox(width: 44, child: pw.Text('-${amount.toStringAsFixed(0)}', style: fs, textAlign: pw.TextAlign.right)),
                    pw.Expanded(child: pw.Text('', style: fs)),
                    pw.Expanded(child: pw.Text('', style: fs)),
                    pw.Expanded(child: pw.Text('', style: fs)),
                  ]),
                ));
              }

              // Check if ledger balance differs from sum of bill pending amounts
              // Adjusted formula: custBalance - ledger + currentYearBilled - creditNotes
              // If this is ~0, the diff is explained by new invoices / credit notes (not a real discrepancy)
              if (bills.isNotEmpty) {
                final ledgerBalance = customer.outstandingForTeam(teamId);
                if (ledgerBalance > 0) {
                  final creditNotes = customer.creditNotesForTeam(teamId);
                  final currentYearBilled = customer.currentYearBilledForTeam(teamId);
                  final adjustedDiff = (custBalance - ledgerBalance + currentYearBilled - creditNotes).abs();
                  if (adjustedDiff > 0.50) {
                    content.add(pw.Padding(
                      padding: const pw.EdgeInsets.only(left: 8, top: 1, bottom: 1),
                      child: pw.Text(
                        'THERE IS DIFFERENCE IN LEDGER A/C BALANCE (${ledgerBalance.toStringAsFixed(0)}) AND CUSTOMER OUTSTANDING BALANCE (${custBalance.toStringAsFixed(0)})',
                        style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: PdfColors.red),
                      ),
                    ));
                  }
                }
              }

              // Customer total
              content.add(pw.Padding(
                padding: const pw.EdgeInsets.only(left: 8),
                child: pw.Row(children: [
                  pw.SizedBox(width: 120, child: pw.Text('------TOTAL --->', style: fsBold)),
                  pw.SizedBox(width: 52, child: pw.Text('', style: fs)),
                  pw.SizedBox(width: 44, child: pw.Text('', style: fs)),
                  pw.SizedBox(width: 22, child: pw.Text('', style: fs)),
                  pw.SizedBox(width: 44, child: pw.Text('${custBill.toStringAsFixed(0)}', style: fsBold, textAlign: pw.TextAlign.right)),
                  pw.SizedBox(width: 38, child: pw.Text('${custRecd.toStringAsFixed(0)}', style: fsBold, textAlign: pw.TextAlign.right)),
                  pw.SizedBox(width: 44, child: pw.Text('${custBalance.toStringAsFixed(0)}', style: fsBold, textAlign: pw.TextAlign.right)),
                ]),
              ));
              content.add(pw.Container(
                margin: const pw.EdgeInsets.symmetric(vertical: 1),
                child: pw.Divider(color: PdfColors.black, thickness: 1.2, borderStyle: pw.BorderStyle.dashed, height: 0),
              ));

              areaBill += custBill;
              areaRecd += custRecd;
              areaBalance += custBalance;
            }

            // Area total
            content.add(pw.Divider(thickness: 1, color: primaryColor));
            content.add(pw.Row(children: [
              pw.SizedBox(width: 120, child: pw.Text('AREA TOTAL --->', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8.5, color: primaryColor))),
              pw.SizedBox(width: 52, child: pw.Text('')),
              pw.SizedBox(width: 44, child: pw.Text('')),
              pw.SizedBox(width: 22, child: pw.Text('')),
              pw.SizedBox(width: 44, child: pw.Text('${areaBill.toStringAsFixed(0)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8.5), textAlign: pw.TextAlign.right)),
              pw.SizedBox(width: 38, child: pw.Text('${areaRecd.toStringAsFixed(0)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8.5), textAlign: pw.TextAlign.right)),
              pw.SizedBox(width: 44, child: pw.Text('${areaBalance.toStringAsFixed(0)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8.5, color: PdfColors.red), textAlign: pw.TextAlign.right)),
            ]));
            content.add(pw.Divider(thickness: 1, color: primaryColor));

            grandBillTotal += areaBill;
            grandRecdTotal += areaRecd;
            grandBalanceTotal += areaBalance;
          }

          // Grand total
          content.add(pw.SizedBox(height: 4));
          content.add(pw.Container(
            color: PdfColor.fromHex('#1E3A8A'),
            padding: const pw.EdgeInsets.all(6),
            child: pw.Row(children: [
              pw.SizedBox(width: 120, child: pw.Text('GRAND TOTAL', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10, color: PdfColors.white))),
              pw.SizedBox(width: 52, child: pw.Text('')),
              pw.SizedBox(width: 44, child: pw.Text('')),
              pw.SizedBox(width: 22, child: pw.Text('')),
              pw.SizedBox(width: 44, child: pw.Text('${grandBillTotal.toStringAsFixed(0)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: PdfColors.white), textAlign: pw.TextAlign.right)),
              pw.SizedBox(width: 38, child: pw.Text('${grandRecdTotal.toStringAsFixed(0)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: PdfColors.white), textAlign: pw.TextAlign.right)),
              pw.SizedBox(width: 44, child: pw.Text('${grandBalanceTotal.toStringAsFixed(0)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: PdfColors.white), textAlign: pw.TextAlign.right)),
            ]),
          ));

          return content;
        },
      ),
    );
    return true;
  }

  /// Generate outstanding PDF file and return path.
  static Future<String> generateOutstandingReportFile({
    required List<CustomerModel> customers,
    required List<Map<String, dynamic>> allBills,
    required String teamId,
    List<String>? beatNames,
    List<Map<String, dynamic>>? advances,
    List<Map<String, dynamic>>? creditNotes,
    String? crossTeamId,
    List<Map<String, dynamic>>? crossTeamBills,
    List<String>? crossTeamBeatNames,
    List<Map<String, dynamic>>? crossTeamAdvances,
    List<Map<String, dynamic>>? crossTeamCreditNotes,
  }) async {
    final bytes = await generateOutstandingReportBytes(
      customers: customers, allBills: allBills, teamId: teamId, beatNames: beatNames,
      advances: advances, creditNotes: creditNotes,
      crossTeamId: crossTeamId, crossTeamBills: crossTeamBills, crossTeamBeatNames: crossTeamBeatNames,
      crossTeamAdvances: crossTeamAdvances, crossTeamCreditNotes: crossTeamCreditNotes,
    );
    final filename = 'MAJAA_Outstanding_${DateFormat('dd-MM-yyyy').format(DateTime.now())}.pdf';
    if (kIsWeb) {
      await Printing.sharePdf(bytes: Uint8List.fromList(bytes), filename: filename);
      return filename;
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// Print outstanding report directly to WiFi/network printer.
  static Future<void> printOutstandingReport({
    required List<CustomerModel> customers,
    required List<Map<String, dynamic>> allBills,
    required String teamId,
    List<String>? beatNames,
    List<Map<String, dynamic>>? advances,
    List<Map<String, dynamic>>? creditNotes,
    String? crossTeamId,
    List<Map<String, dynamic>>? crossTeamBills,
    List<String>? crossTeamBeatNames,
    List<Map<String, dynamic>>? crossTeamAdvances,
    List<Map<String, dynamic>>? crossTeamCreditNotes,
  }) async {
    final bytes = await generateOutstandingReportBytes(
      customers: customers, allBills: allBills, teamId: teamId, beatNames: beatNames,
      advances: advances, creditNotes: creditNotes,
      crossTeamId: crossTeamId, crossTeamBills: crossTeamBills, crossTeamBeatNames: crossTeamBeatNames,
      crossTeamAdvances: crossTeamAdvances, crossTeamCreditNotes: crossTeamCreditNotes,
    );
    await Printing.layoutPdf(onLayout: (_) async => Uint8List.fromList(bytes));
  }

  /// Generate overlay PDF that prints ONLY collection amounts in UPI/CHQ/CASH columns.
  /// Same layout as the outstanding report — invisible rows, only payment columns filled.
  /// For re-feeding the printed outstanding sheet through the printer.
  static Future<List<int>> generateCollectionOverlayBytes({
    required List<CustomerModel> customers,
    required List<Map<String, dynamic>> allBills,
    required List<CollectionModel> collections,
    required String teamId,
    List<String>? beatNames,
  }) async {
    final pdf = pw.Document();
    final printedFor = DateFormat('dd.MM.yyyy').format(_nextWorkingDay());
    final teamName = teamId == 'JA' ? 'JAGANNATH ASSOCIATES' : 'MADHAV ASSOCIATES';
    final regular = await regularFont;
    final bold = await boldFont;
    final baseTheme = pw.ThemeData.withFont(base: regular, bold: bold);
    // Invisible text — same size but white (takes same space, no ink)
    final invisible = pw.TextStyle(fontSize: 8, color: PdfColors.white);
    final invisibleBold = pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white);
    // Visible — for the collection amounts
    final printStyle = pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold);

    // Build collection lookup: customer_id → {upi: amount, cash: amount, cheque: amount}
    final Map<String, Map<String, double>> collectionMap = {};
    double upiGrand = 0, chequeGrand = 0, cashGrand = 0;
    debugPrint('🧾 Overlay: ${collections.length} collections to map');
    for (final c in collections) {
      debugPrint('🧾 Collection: ${c.customerName} (${c.customerId}) = ${c.amountCollected} ${c.paymentMode}');
      collectionMap.putIfAbsent(c.customerId, () => {'UPI': 0, 'CASH': 0, 'Cheque': 0});
      final mode = c.paymentMode;
      if (mode == 'UPI') {
        collectionMap[c.customerId]!['UPI'] = (collectionMap[c.customerId]!['UPI'] ?? 0) + c.amountCollected;
        upiGrand += c.amountCollected;
      } else if (mode == 'Cheque' || mode == 'CHEQUE') {
        collectionMap[c.customerId]!['Cheque'] = (collectionMap[c.customerId]!['Cheque'] ?? 0) + c.amountCollected;
        chequeGrand += c.amountCollected;
      } else {
        collectionMap[c.customerId]!['CASH'] = (collectionMap[c.customerId]!['CASH'] ?? 0) + c.amountCollected;
        cashGrand += c.amountCollected;
      }
    }

    // Same customer/bill grouping as the outstanding report
    final Map<String, List<Map<String, dynamic>>> billsByCustomer = {};
    for (final bill in allBills) {
      final custId = bill['customer_id'] as String? ?? '';
      if (custId.isEmpty) continue;
      final pending = (bill['pending_amount'] as num?)?.toDouble() ?? 0;
      if (pending <= 0) continue;
      billsByCustomer.putIfAbsent(custId, () => []);
      billsByCustomer[custId]!.add(bill);
    }

    final Map<String, List<CustomerModel>> byBeat = {};
    for (final c in customers) {
      final beat = c.beatNameForTeam(teamId);
      if (beat.isEmpty) continue;
      if (beatNames != null && !beatNames.contains(beat)) continue;
      final hasPendingBills = billsByCustomer.containsKey(c.id);
      if (!hasPendingBills) continue;
      byBeat.putIfAbsent(beat, () => []);
      byBeat[beat]!.add(c);
    }
    final sortedBeats = byBeat.keys.toList()..sort();
    for (final beat in sortedBeats) {
      byBeat[beat]!.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }

    pdf.addPage(
      pw.MultiPage(
        theme: baseTheme,
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(18, 16, 18, 60),
        // EXACT same header as outstanding — same text, white where needed
        header: (context) => pw.Column(children: [
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text(teamName, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13, color: PdfColors.white)),
            pw.Text('Page ${context.pageNumber}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.white)),
          ]),
          pw.Text('CUSTOMER OUTSTANDING  FOR $printedFor', style: const pw.TextStyle(fontSize: 9, color: PdfColors.white)),
          if (beatNames != null && beatNames.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 2),
              child: pw.Text('BEATS: ${beatNames.join(' | ')}',
                  style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
            ),
          pw.Divider(color: PdfColors.white, thickness: 1.5),
          pw.SizedBox(height: 1),
          pw.Row(children: [
            pw.SizedBox(width: 120, child: pw.Text('CUSTOMER NAME', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7.5, color: PdfColors.white))),
            pw.SizedBox(width: 52, child: pw.Text('BILL NO.', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7.5, color: PdfColors.white))),
            pw.SizedBox(width: 44, child: pw.Text('BILL\nDATE', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7, color: PdfColors.white))),
            pw.SizedBox(width: 22, child: pw.Text('BILL\nDAYS', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7, color: PdfColors.white), textAlign: pw.TextAlign.right)),
            pw.SizedBox(width: 44, child: pw.Text('BILL\nAMOUNT', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7, color: PdfColors.white), textAlign: pw.TextAlign.right)),
            pw.SizedBox(width: 38, child: pw.Text('RECD\nAMOUNT', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7, color: PdfColors.white), textAlign: pw.TextAlign.right)),
            pw.SizedBox(width: 44, child: pw.Text('BALANCE\nAMOUNT', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7, color: PdfColors.white), textAlign: pw.TextAlign.right)),
            pw.Expanded(child: pw.Text('UPI', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7, color: PdfColors.white), textAlign: pw.TextAlign.center)),
            pw.Expanded(child: pw.Text('CHQ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7, color: PdfColors.white), textAlign: pw.TextAlign.center)),
            pw.Expanded(child: pw.Text('CASH', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7, color: PdfColors.white), textAlign: pw.TextAlign.center)),
          ]),
          pw.Divider(color: PdfColors.white, thickness: 1),
        ]),
        build: (context) {
          final List<pw.Widget> content = [];

          for (final beat in sortedBeats) {
            final beatCustomers = byBeat[beat]!;

            // Same beat header as outstanding — white
            content.add(pw.SizedBox(height: 3));
            content.add(pw.Text('****** ${beat.toUpperCase()} ******',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: PdfColors.white)));
            content.add(pw.SizedBox(height: 1));

            for (final customer in beatCustomers) {
              final bills = billsByCustomer[customer.id] ?? [];
              final coll = collectionMap[customer.id];
              final upiAmt = coll?['UPI'] ?? 0;
              final chequeAmt = coll?['Cheque'] ?? 0;
              final cashAmt = coll?['CASH'] ?? 0;
              if (upiAmt > 0 || chequeAmt > 0 || cashAmt > 0) {
                debugPrint('🧾 MATCH: ${customer.name} (${customer.id}) → UPI=$upiAmt CHQ=$chequeAmt CASH=$cashAmt');
              }
              final phone = customer.phone.isNotEmpty && customer.phone != 'No Phone' ? ', PH.${customer.phone}' : '';

              // Same customer name text (white) — same height as outstanding
              content.add(pw.Text('**** ${customer.name}$phone', style: invisibleBold));

              if (bills.isNotEmpty) {
                bills.sort((a, b) => ((a['bill_date'] as String?) ?? '').compareTo((b['bill_date'] as String?) ?? ''));
                for (int bi = 0; bi < bills.length; bi++) {
                  final bill = bills[bi];
                  final sman = bill['sman_name'] as String? ?? '';
                  final inv = bill['invoice_no'] as String? ?? '';
                  final book = bill['book'] as String? ?? '';
                  final billNo = book.isNotEmpty ? '$book-$inv' : inv;
                  final billDate = bill['bill_date'] as String? ?? '';
                  final dateStr = billDate.isNotEmpty ? DateFormat('dd.MM.yy').format(DateTime.parse(billDate)) : '';
                  final days = billDate.isNotEmpty ? DateTime.now().difference(DateTime.parse(billDate)).inDays : 0;
                  final billAmt = (bill['bill_amount'] as num?)?.toDouble() ?? 0;
                  final recdAmt = (bill['received_amount'] as num?)?.toDouble() ?? 0;
                  final balance = (bill['pending_amount'] as num?)?.toDouble() ?? 0;

                  final isFirst = bi == 0;
                  // Same row layout as outstanding — same text, white color, same widths
                  content.add(pw.Padding(
                    padding: const pw.EdgeInsets.only(left: 8),
                    child: pw.Row(children: [
                      pw.SizedBox(width: 120, child: pw.Text(sman.isNotEmpty ? sman : '', style: invisible)),
                      pw.SizedBox(width: 52, child: pw.Text(billNo, style: invisible)),
                      pw.SizedBox(width: 44, child: pw.Text(dateStr, style: invisible)),
                      pw.SizedBox(width: 22, child: pw.Text('$days', style: invisible, textAlign: pw.TextAlign.right)),
                      pw.SizedBox(width: 44, child: pw.Text('${billAmt.toStringAsFixed(0)}', style: invisible, textAlign: pw.TextAlign.right)),
                      pw.SizedBox(width: 38, child: pw.Text('${recdAmt.toStringAsFixed(0)}', style: invisible, textAlign: pw.TextAlign.right)),
                      pw.SizedBox(width: 44, child: pw.Text('${balance.toStringAsFixed(0)}', style: invisible, textAlign: pw.TextAlign.right)),
                      pw.Expanded(child: pw.Text(isFirst && upiAmt > 0 ? '${upiAmt.toStringAsFixed(0)}' : '', style: printStyle, textAlign: pw.TextAlign.center)),
                      pw.Expanded(child: pw.Text(isFirst && chequeAmt > 0 ? '${chequeAmt.toStringAsFixed(0)}' : '', style: printStyle, textAlign: pw.TextAlign.center)),
                      pw.Expanded(child: pw.Text(isFirst && cashAmt > 0 ? '${cashAmt.toStringAsFixed(0)}' : '', style: printStyle, textAlign: pw.TextAlign.center)),
                    ]),
                  ));
                }
              } else {
                final balance = customer.outstandingForTeam(teamId);
                content.add(pw.Padding(
                  padding: const pw.EdgeInsets.only(left: 8),
                  child: pw.Row(children: [
                    pw.SizedBox(width: 120, child: pw.Text('(no bill details)', style: invisible)),
                    pw.SizedBox(width: 52, child: pw.Text('', style: invisible)),
                    pw.SizedBox(width: 44, child: pw.Text('', style: invisible)),
                    pw.SizedBox(width: 22, child: pw.Text('', style: invisible)),
                    pw.SizedBox(width: 44, child: pw.Text('${balance.toStringAsFixed(0)}', style: invisible, textAlign: pw.TextAlign.right)),
                    pw.SizedBox(width: 38, child: pw.Text('0', style: invisible, textAlign: pw.TextAlign.right)),
                    pw.SizedBox(width: 44, child: pw.Text('${balance.toStringAsFixed(0)}', style: invisible, textAlign: pw.TextAlign.right)),
                    pw.Expanded(child: pw.Text(upiAmt > 0 ? '${upiAmt.toStringAsFixed(0)}' : '', style: printStyle, textAlign: pw.TextAlign.center)),
                    pw.Expanded(child: pw.Text(chequeAmt > 0 ? '${chequeAmt.toStringAsFixed(0)}' : '', style: printStyle, textAlign: pw.TextAlign.center)),
                    pw.Expanded(child: pw.Text(cashAmt > 0 ? '${cashAmt.toStringAsFixed(0)}' : '', style: printStyle, textAlign: pw.TextAlign.center)),
                  ]),
                ));
              }

              // Same total row (white)
              content.add(pw.Padding(
                padding: const pw.EdgeInsets.only(left: 8),
                child: pw.Row(children: [
                  pw.SizedBox(width: 120, child: pw.Text('------TOTAL --->', style: invisibleBold)),
                  pw.SizedBox(width: 52, child: pw.Text('', style: invisible)),
                  pw.SizedBox(width: 44, child: pw.Text('', style: invisible)),
                  pw.SizedBox(width: 22, child: pw.Text('', style: invisible)),
                  pw.SizedBox(width: 44, child: pw.Text('0', style: invisible, textAlign: pw.TextAlign.right)),
                  pw.SizedBox(width: 38, child: pw.Text('0', style: invisible, textAlign: pw.TextAlign.right)),
                  pw.SizedBox(width: 44, child: pw.Text('0', style: invisible, textAlign: pw.TextAlign.right)),
                ]),
              ));
              // Same dashed divider (white)
              content.add(pw.Container(
                margin: const pw.EdgeInsets.symmetric(vertical: 0),
                child: pw.Divider(color: PdfColors.white, thickness: 0.3, height: 0),
              ));
            }

            // Same area total (white)
            content.add(pw.Divider(color: PdfColors.white, thickness: 1));
            content.add(pw.Row(children: [
              pw.SizedBox(width: 120, child: pw.Text('AREA TOTAL --->', style: invisible)),
              pw.SizedBox(width: 52, child: pw.Text('', style: invisible)),
              pw.SizedBox(width: 44, child: pw.Text('', style: invisible)),
              pw.SizedBox(width: 22, child: pw.Text('', style: invisible)),
              pw.SizedBox(width: 44, child: pw.Text('0', style: invisible, textAlign: pw.TextAlign.right)),
              pw.SizedBox(width: 38, child: pw.Text('0', style: invisible, textAlign: pw.TextAlign.right)),
              pw.SizedBox(width: 44, child: pw.Text('0', style: invisible, textAlign: pw.TextAlign.right)),
            ]));
            content.add(pw.Divider(color: PdfColors.white, thickness: 1));
          }

          // Grand total overlay — aligns with the outstanding sheet's GRAND TOTAL bar.
          // Invisible cells preserve the layout; only UPI / CHQ / CASH totals print
          // visibly, and those columns are empty on the outstanding's Grand Total row.
          final totalStyle = pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold);
          content.add(pw.SizedBox(height: 4));
          content.add(pw.Container(
            padding: const pw.EdgeInsets.all(6),
            child: pw.Row(children: [
              pw.SizedBox(width: 120, child: pw.Text('GRAND TOTAL', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10, color: PdfColors.white))),
              pw.SizedBox(width: 52, child: pw.Text('', style: invisible)),
              pw.SizedBox(width: 44, child: pw.Text('', style: invisible)),
              pw.SizedBox(width: 22, child: pw.Text('', style: invisible)),
              pw.SizedBox(width: 44, child: pw.Text('0', style: pw.TextStyle(fontSize: 9, color: PdfColors.white), textAlign: pw.TextAlign.right)),
              pw.SizedBox(width: 38, child: pw.Text('0', style: pw.TextStyle(fontSize: 9, color: PdfColors.white), textAlign: pw.TextAlign.right)),
              pw.SizedBox(width: 44, child: pw.Text('0', style: pw.TextStyle(fontSize: 9, color: PdfColors.white), textAlign: pw.TextAlign.right)),
              pw.Expanded(child: pw.Text(upiGrand > 0 ? upiGrand.toStringAsFixed(0) : '', style: totalStyle, textAlign: pw.TextAlign.center)),
              pw.Expanded(child: pw.Text(chequeGrand > 0 ? chequeGrand.toStringAsFixed(0) : '', style: totalStyle, textAlign: pw.TextAlign.center)),
              pw.Expanded(child: pw.Text(cashGrand > 0 ? cashGrand.toStringAsFixed(0) : '', style: totalStyle, textAlign: pw.TextAlign.center)),
            ]),
          ));

          return content;
        },
      ),
    );

    return await pdf.save();
  }

  /// Generate collection overlay file for sharing/testing.
  static Future<String> generateCollectionOverlayFile({
    required List<CustomerModel> customers,
    required List<Map<String, dynamic>> allBills,
    required List<CollectionModel> collections,
    required String teamId,
    List<String>? beatNames,
  }) async {
    final bytes = await generateCollectionOverlayBytes(
      customers: customers, allBills: allBills, collections: collections,
      teamId: teamId, beatNames: beatNames,
    );
    final filename = 'MAJAA_Collection_Overlay_${DateFormat('dd-MM-yyyy').format(DateTime.now())}.pdf';
    if (kIsWeb) {
      await Printing.sharePdf(bytes: Uint8List.fromList(bytes), filename: filename);
      return filename;
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes);
    return file.path;
  }
}