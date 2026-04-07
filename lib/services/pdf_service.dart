import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';
import 'supabase_service.dart';

class PdfService {
  // Brand Colors matching your AppTheme
  static final PdfColor primaryColor = PdfColor.fromHex('#2563EB'); // Deep Blue
  static final PdfColor secondaryColor = PdfColor.fromHex('#1E3A8A'); // Darker Blue
  static final PdfColor lightBgColor = PdfColor.fromHex('#F3F4F6'); // Light Gray
  static final PdfColor textColor = PdfColor.fromHex('#1F2937'); // Dark Gray

  // ─── DAILY REPORT GENERATOR ──────────────────────────────────────────────
  static Future<void> generateAndShareOrderReport(DateTime date) async {
    final pdf = pw.Document();
    final String formattedDate = DateFormat('dd-MM-yyyy').format(date);
    final String dateString = DateFormat('yyyy-MM-dd').format(date);

    final List<Map<String, dynamic>> orders = await SupabaseService.instance
        .getOrdersByDate(dateString);

    if (orders.isEmpty) throw 'No orders found for $formattedDate';

    double grandTotal = 0;

    pdf.addPage(
      pw.MultiPage(
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
                    headers: ['Product', 'Qty', 'Price', 'Total'],
                    data: items.map((item) {
                      final product = item['products'] ?? {};
                      final price = item['unit_price'] ?? item['price_per_unit'] ?? 0.0;
                      final total = item['line_total'] ?? item['total_price'] ?? 0.0;
                      return [
                        item['product_name'] ?? product['name'] ?? 'Unknown Product',
                        item['quantity'].toString(),
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

  // ─── SINGLE INVOICE GENERATOR ────────────────────────────────────────────
  static Future<void> generateCustomerInvoice(Map<String, dynamic> order) async {
    final pdf = pw.Document();

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
                  headers: ['Item Description', 'Qty', 'Unit Price', 'Total'],
                  cellAlignments: {
                    0: pw.Alignment.centerLeft,
                    1: pw.Alignment.center,
                    2: pw.Alignment.centerRight,
                    3: pw.Alignment.centerRight,
                  },
                  data: items.map((item) {
                    final product = item['products'] ?? {};
                    final price = item['unit_price'] ?? item['price_per_unit'] ?? 0.0;
                    final total = item['line_total'] ?? item['total_price'] ?? 0.0;
                    return [
                      product['name'] ?? 'Unknown Item',
                      item['quantity'].toString(),
                      'Rs. ${price.toStringAsFixed(2)}',
                      'Rs. ${total.toStringAsFixed(2)}',
                    ];
                  }).toList(),
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
}