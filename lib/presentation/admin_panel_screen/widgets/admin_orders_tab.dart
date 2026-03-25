import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';

// Conditional import for web download
import 'admin_orders_download_stub.dart'
    if (dart.library.html) 'admin_orders_download_web.dart';

class AdminOrdersTab extends StatefulWidget {
  const AdminOrdersTab({super.key});

  @override
  State<AdminOrdersTab> createState() => _AdminOrdersTabState();
}

class _AdminOrdersTabState extends State<AdminOrdersTab> {
  final _service = SupabaseService.instance;

  List<OrderModel> _orders = [];
  bool _loading = false;
  String? _error;

  DateTime? _startDate;
  DateTime? _endDate;
  bool _hasFiltered = false;
  bool _generatingPdf = false;

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  Future<void> _loadOrders() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final orders = await _service.getOrdersByDateRange(
        startDate: _startDate,
        endDate: _endDate,
      );
      setState(() {
        _orders = orders;
        _loading = false;
        _hasFiltered = true;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() => _startDate = picked);
    }
  }

  Future<void> _pickEndDate() async {
    final firstAllowedDate = _startDate ?? DateTime(2020);

    DateTime initial = _endDate ?? DateTime.now();
    if (initial.isBefore(firstAllowedDate)) {
      initial = firstAllowedDate;
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstAllowedDate,
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && mounted) {
      setState(() => _endDate = picked);
    }
  }

  void _clearFilter() {
    setState(() {
      _startDate = null;
      _endDate = null;
    });
    _loadOrders();
  }

  String _formatDate(DateTime? d) {
    if (d == null) return 'Select';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  String _csvField(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }

  Map<String, List<OrderModel>> _groupByCustomer() {
    final map = <String, List<OrderModel>>{};
    for (final o in _orders) {
      map.putIfAbsent(o.customerName, () => []).add(o);
    }
    final sorted = Map.fromEntries(
      map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return sorted;
  }

  String _buildCsv() {
    final buffer = StringBuffer();

    buffer.writeln(
      'Customer Name,Order ID,Order Date,Product Name,SKU,Qty,Unit Price,Line Total,Subtotal,Grand Total',
    );

    for (final o in _orders) {
      final orderDate =
          '${o.orderDate.day.toString().padLeft(2, '0')}/${o.orderDate.month.toString().padLeft(2, '0')}/${o.orderDate.year}';

      if (o.lineItems.isEmpty) {
        buffer.writeln(
          '${_csvField(o.customerName)},${_csvField(o.id)},${_csvField(orderDate)},"","",0,0.00,0.00,${o.subtotal.toStringAsFixed(2)},${o.grandTotal.toStringAsFixed(2)}',
        );
      } else {
        for (final item in o.lineItems) {
          buffer.writeln(
            '${_csvField(o.customerName)},${_csvField(o.id)},${_csvField(orderDate)},${_csvField(item.productName)},${_csvField(item.sku)},${item.quantity},${item.unitPrice.toStringAsFixed(2)},${item.lineTotal.toStringAsFixed(2)},${o.subtotal.toStringAsFixed(2)},${o.grandTotal.toStringAsFixed(2)}',
          );
        }
      }
    }

    return buffer.toString();
  }

  void _downloadCsv() {
    if (_orders.isEmpty) {
      Fluttertoast.showToast(msg: 'No orders to export');
      return;
    }
    final csv = _buildCsv();
    final dateLabel = _startDate != null || _endDate != null
        ? '_${_formatDate(_startDate).replaceAll('/', '-')}_to_${_formatDate(_endDate).replaceAll('/', '-')}'
        : '_all';
    final filename = 'orders_customer_wise$dateLabel.csv';

    triggerCsvDownload(csv, filename);
    Fluttertoast.showToast(msg: 'CSV downloaded: $filename');
  }

  Future<void> _downloadPdf() async {
    if (_orders.isEmpty) {
      Fluttertoast.showToast(msg: 'No orders to export');
      return;
    }

    setState(() => _generatingPdf = true);

    try {
      final pdf = pw.Document();
      final grouped = _groupByCustomer();

      // FIXED: Used standard hyphen instead of long dash
      final dateRangeLabel = (_startDate != null || _endDate != null)
          ? 'Date Range: ${_formatDate(_startDate)} - ${_formatDate(_endDate)}'
          : 'All Orders';

      final grandTotalAll = _orders.fold<double>(
        0,
        (sum, o) => sum + o.grandTotal,
      );

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(24),
          header: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Orders Report - Customer Wise',
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    'Generated: ${_formatDate(DateTime.now())}',
                    style: const pw.TextStyle(fontSize: 9),
                  ),
                ],
              ),
              pw.SizedBox(height: 4),
              pw.Text(dateRangeLabel, style: const pw.TextStyle(fontSize: 10)),
              pw.Divider(thickness: 1),
            ],
          ),
          footer: (context) => pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              // FIXED: Replaced ₹ with Rs.
              pw.Text(
                'Total Orders: ${_orders.length}  |  Grand Total: Rs. ${grandTotalAll.toStringAsFixed(2)}',
                style: const pw.TextStyle(fontSize: 9),
              ),
              pw.Text(
                'Page ${context.pageNumber} of ${context.pagesCount}',
                style: const pw.TextStyle(fontSize: 9),
              ),
            ],
          ),
          build: (context) {
            final widgets = <pw.Widget>[];

            for (final entry in grouped.entries) {
              final customerName = entry.key;
              final customerOrders = entry.value;
              final customerTotal = customerOrders.fold<double>(
                0,
                (sum, o) => sum + o.grandTotal,
              );

              widgets.add(
                pw.Container(
                  color: PdfColors.blueGrey800,
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        customerName,
                        style: pw.TextStyle(
                          fontSize: 11,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.white,
                        ),
                      ),
                      // FIXED: Replaced ₹ with Rs.
                      pw.Text(
                        '${customerOrders.length} order${customerOrders.length == 1 ? '' : 's'}  |  Rs. ${customerTotal.toStringAsFixed(2)}',
                        style: pw.TextStyle(
                          fontSize: 9,
                          color: PdfColors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              );

              for (final order in customerOrders) {
                final orderDate =
                    '${order.orderDate.day.toString().padLeft(2, '0')}/${order.orderDate.month.toString().padLeft(2, '0')}/${order.orderDate.year}';
                final deliveryDate = order.deliveryDate != null
                    ? '${order.deliveryDate!.day.toString().padLeft(2, '0')}/${order.deliveryDate!.month.toString().padLeft(2, '0')}/${order.deliveryDate!.year}'
                    : '-';

                widgets.add(
                  pw.Container(
                    color: PdfColors.grey200,
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: pw.Row(
                      children: [
                        pw.Expanded(
                          child: pw.Text(
                            'Order: ${order.id.length > 8 ? order.id.substring(0, 8) : order.id}...',
                            style: const pw.TextStyle(fontSize: 8),
                          ),
                        ),
                        pw.Text(
                          'Beat: ${order.beat}',
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                        pw.SizedBox(width: 12),
                        pw.Text(
                          'Date: $orderDate',
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                        pw.SizedBox(width: 12),
                        pw.Text(
                          'Delivery: $deliveryDate',
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                        pw.SizedBox(width: 12),
                        pw.Text(
                          'Status: ${order.status}',
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                      ],
                    ),
                  ),
                );

                if (order.lineItems.isNotEmpty) {
                  widgets.add(
                    pw.Table(
                      border: pw.TableBorder.all(
                        color: PdfColors.grey300,
                        width: 0.5,
                      ),
                      columnWidths: {
                        0: const pw.FlexColumnWidth(3),
                        1: const pw.FlexColumnWidth(2),
                        2: const pw.FixedColumnWidth(35),
                        3: const pw.FixedColumnWidth(55),
                        4: const pw.FixedColumnWidth(55),
                      },
                      children: [
                        pw.TableRow(
                          decoration: const pw.BoxDecoration(
                            color: PdfColors.grey100,
                          ),
                          children: [
                            _pdfCell('Product', isHeader: true),
                            _pdfCell('SKU', isHeader: true),
                            _pdfCell(
                              'Qty',
                              isHeader: true,
                              align: pw.Alignment.centerRight,
                            ),
                            _pdfCell(
                              'Unit Price',
                              isHeader: true,
                              align: pw.Alignment.centerRight,
                            ),
                            _pdfCell(
                              'Line Total',
                              isHeader: true,
                              align: pw.Alignment.centerRight,
                            ),
                          ],
                        ),
                        ...order.lineItems.map(
                          (item) => pw.TableRow(
                            children: [
                              _pdfCell(item.productName),
                              _pdfCell(item.sku),
                              _pdfCell(
                                '${item.quantity}',
                                align: pw.Alignment.centerRight,
                              ),
                              // FIXED: Replaced ₹ with Rs.
                              _pdfCell(
                                'Rs. ${item.unitPrice.toStringAsFixed(2)}',
                                align: pw.Alignment.centerRight,
                              ),
                              // FIXED: Replaced ₹ with Rs.
                              _pdfCell(
                                'Rs. ${item.lineTotal.toStringAsFixed(2)}',
                                align: pw.Alignment.centerRight,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }

                widgets.add(
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    alignment: pw.Alignment.centerRight,
                    // FIXED: Replaced ₹ with Rs.
                    child: pw.Text(
                      'Subtotal: Rs. ${order.subtotal.toStringAsFixed(2)}  |  VAT: Rs. ${order.vat.toStringAsFixed(2)}  |  Grand Total: Rs. ${order.grandTotal.toStringAsFixed(2)}',
                      style: pw.TextStyle(
                        fontSize: 8,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                );

                widgets.add(pw.SizedBox(height: 4));
              }

              widgets.add(
                pw.Container(
                  color: PdfColors.blueGrey50,
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  alignment: pw.Alignment.centerRight,
                  // FIXED: Replaced ₹ with Rs. and long dash with normal dash
                  child: pw.Text(
                    'Customer Total - $customerName: Rs. ${customerTotal.toStringAsFixed(2)}',
                    style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              );

              widgets.add(pw.SizedBox(height: 10));
            }

            return widgets;
          },
        ),
      );

      final bytes = await pdf.save();
      final dateLabel = _startDate != null || _endDate != null
          ? '_${_formatDate(_startDate).replaceAll('/', '-')}_to_${_formatDate(_endDate).replaceAll('/', '-')}'
          : '_all';
      final filename = 'orders_customer_wise$dateLabel.pdf';

      if (kIsWeb) {
        triggerPdfDownload(bytes, filename);
        Fluttertoast.showToast(msg: 'PDF downloaded: $filename');
      } else {
        await Printing.sharePdf(bytes: bytes, filename: filename);
        Fluttertoast.showToast(msg: 'PDF ready: $filename');
      }
    } catch (e) {
      Fluttertoast.showToast(
        msg:
            'PDF generation failed: ${e.toString().substring(0, e.toString().length > 60 ? 60 : e.toString().length)}',
      );
    } finally {
      setState(() => _generatingPdf = false);
    }
  }

  pw.Widget _pdfCell(
    String text, {
    bool isHeader = false,
    pw.Alignment align = pw.Alignment.centerLeft,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      alignment: align,
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: 8,
          fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
        overflow: pw.TextOverflow.clip,
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'delivered':
        return AppTheme.success;
      case 'pending':
        return AppTheme.warning;
      case 'cancelled':
        return AppTheme.error;
      default:
        return AppTheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Date Filter Bar ──────────────────────────────────────
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Filter by Date',
                style: GoogleFonts.manrope(
                  fontSize: 14.0,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.onSurface,
                ),
              ),
              const SizedBox(height: 8.0),
              Row(
                children: [
                  Expanded(
                    child: _DatePickerButton(
                      label: 'From',
                      value: _formatDate(_startDate),
                      onTap: _pickStartDate,
                    ),
                  ),
                  const SizedBox(width: 8.0),
                  Expanded(
                    child: _DatePickerButton(
                      label: 'To',
                      value: _formatDate(_endDate),
                      onTap: _pickEndDate,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8.0),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10.0),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10.0),
                      ),
                      onPressed: _loading ? null : _loadOrders,
                      icon: const Icon(Icons.search_rounded, size: 16),
                      label: Text(
                        'Apply Filter',
                        style: GoogleFonts.manrope(
                          fontSize: 14.0,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  if (_startDate != null || _endDate != null) ...[
                    const SizedBox(width: 8.0),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.error,
                        side: BorderSide(color: AppTheme.error),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10.0),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10.0),
                      ),
                      onPressed: _clearFilter,
                      child: Text(
                        'Clear',
                        style: GoogleFonts.manrope(fontSize: 14.0),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),

        // ── Summary + Download Bar ───────────────────────────────
        if (_hasFiltered && !_loading && _error == null)
          Container(
            color: AppTheme.surface,
            padding: const EdgeInsets.symmetric(
              horizontal: 12.0,
              vertical: 8.0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_orders.length} order${_orders.length == 1 ? '' : 's'} found  •  ${_groupByCustomer().length} customer${_groupByCustomer().length == 1 ? '' : 's'}',
                  style: GoogleFonts.manrope(
                    fontSize: 14.0,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8.0),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.success,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10.0),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                        ),
                        onPressed: _downloadCsv,
                        icon: const Icon(Icons.table_chart_rounded, size: 15),
                        label: Text(
                          'Download CSV',
                          style: GoogleFonts.manrope(
                            fontSize: 13.0,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8.0),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFD32F2F),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10.0),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                        ),
                        onPressed: (_generatingPdf || _orders.isEmpty)
                            ? null
                            : _downloadPdf,
                        icon: _generatingPdf
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.picture_as_pdf_rounded,
                                size: 15,
                              ),
                        label: Text(
                          _generatingPdf ? 'Generating...' : 'Download PDF',
                          style: GoogleFonts.manrope(
                            fontSize: 13.0,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

        // ── Orders List ──────────────────────────────────────────
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: Colors.red,
                              size: 48,
                            ),
                            const SizedBox(height: 8.0),
                            Text(
                              'Error loading orders',
                              style: GoogleFonts.manrope(
                                fontSize: 14.0,
                                fontWeight: FontWeight.w600,
                                color: Colors.red,
                              ),
                            ),
                            const SizedBox(height: 4.0),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.manrope(
                                fontSize: 12.0,
                                color: Colors.grey,
                              ),
                            ),
                            const SizedBox(height: 12.0),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: _loadOrders,
                              icon: const Icon(Icons.refresh, size: 16),
                              label:
                                  Text('Retry', style: GoogleFonts.manrope()),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _orders.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.receipt_long_rounded,
                                size: 48,
                                color: Colors.grey,
                              ),
                              const SizedBox(height: 8.0),
                              Text(
                                _hasFiltered
                                    ? 'No orders found for selected dates'
                                    : 'No orders yet',
                                style: GoogleFonts.manrope(
                                  fontSize: 16.0,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(8.0),
                          itemCount: _orders.length,
                          itemBuilder: (context, index) {
                            final order = _orders[index];
                            return _OrderAdminCard(
                              order: order,
                              statusColor: _statusColor(order.status),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}

class _DatePickerButton extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _DatePickerButton({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.outline),
          borderRadius: BorderRadius.circular(10.0),
          color: Colors.white,
        ),
        child: Row(
          children: [
            Icon(
              Icons.calendar_today_rounded,
              size: 14,
              color: AppTheme.primary,
            ),
            const SizedBox(width: 6.0),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.manrope(
                      fontSize: 10.0,
                      color: AppTheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    value,
                    style: GoogleFonts.manrope(
                      fontSize: 13.0,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderAdminCard extends StatelessWidget {
  final OrderModel order;
  final Color statusColor;

  const _OrderAdminCard({required this.order, required this.statusColor});

  @override
  Widget build(BuildContext context) {
    final orderDate =
        '${order.orderDate.day.toString().padLeft(2, '0')}/${order.orderDate.month.toString().padLeft(2, '0')}/${order.orderDate.year}';
    final deliveryDate = order.deliveryDate != null
        ? '${order.deliveryDate!.day.toString().padLeft(2, '0')}/${order.deliveryDate!.month.toString().padLeft(2, '0')}/${order.deliveryDate!.year}'
        : '-';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.0)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Order header row
            Row(
              children: [
                Expanded(
                  child: Text(
                    order.customerName,
                    style: GoogleFonts.manrope(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withAlpha(31),
                    borderRadius: BorderRadius.circular(6.0),
                  ),
                  child: Text(
                    order.status,
                    style: GoogleFonts.manrope(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Order ID: ${order.id.length > 12 ? order.id.substring(0, 12) : order.id}...',
              style: GoogleFonts.manrope(
                fontSize: 10,
                color: AppTheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  Icons.map_rounded,
                  size: 12,
                  color: AppTheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  order.beat,
                  style: GoogleFonts.manrope(
                    fontSize: 11,
                    color: AppTheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  Icons.calendar_today_rounded,
                  size: 12,
                  color: AppTheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  orderDate,
                  style: GoogleFonts.manrope(
                    fontSize: 11,
                    color: AppTheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  Icons.local_shipping_rounded,
                  size: 12,
                  color: AppTheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  deliveryDate,
                  style: GoogleFonts.manrope(
                    fontSize: 11,
                    color: AppTheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (order.lineItems.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 6),
              ...order.lineItems.map(
                (item) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(
                          item.productName,
                          style: GoogleFonts.manrope(
                            fontSize: 11,
                            color: AppTheme.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        'x${item.quantity}',
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          color: AppTheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '₹${item.lineTotal.toStringAsFixed(2)}',
                        style: GoogleFonts.manrope(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  'Subtotal: ₹${order.subtotal.toStringAsFixed(2)}  |  VAT: ₹${order.vat.toStringAsFixed(2)}  |  ',
                  style: GoogleFonts.manrope(
                    fontSize: 10,
                    color: AppTheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  'Total: ₹${order.grandTotal.toStringAsFixed(2)}',
                  style: GoogleFonts.manrope(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.onSurface,
                  ),
                ),
              ],
            ),
            if (order.notes != null && order.notes!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Note: ${order.notes}',
                style: GoogleFonts.manrope(
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  color: AppTheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
