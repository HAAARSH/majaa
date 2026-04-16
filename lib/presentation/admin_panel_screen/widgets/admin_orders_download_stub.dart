import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

// Stub for non-web platforms (Android/iOS/Desktop)
Future<void> triggerCsvDownload(String csvContent, String filename) async {
  try {
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/$filename');
    await file.writeAsString(csvContent);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/vnd.ms-excel')],
        text: 'Order Export: $filename',
      ),
    );
  } catch (e) {
    debugPrint('Error sharing CSV: $e');
  }
}

void triggerPdfDownload(Uint8List pdfBytes, String filename) {
  // On mobile/desktop, PDF is shared via Printing.sharePdf — handled in admin_orders_tab.dart
}
