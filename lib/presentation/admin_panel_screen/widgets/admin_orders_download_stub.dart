import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart'
    if (dart.library.html) 'dart:html';
import 'package:share_plus/share_plus.dart' if (dart.library.html) 'dart:html';

// Stub for non-web platforms (Android/iOS)
Future<void> triggerCsvDownload(String csvContent, String filename) async {
  try {
    // 1. Get the temporary directory of the device
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/$filename');

    // 2. Write the CSV content to the file
    await file.writeAsString(csvContent);

    // 3. Open the native share dialog so the admin can save or send the CSV
    await Share.shareXFiles([
      XFile(file.path),
    ], text: 'Order Export: $filename');
  } catch (e) {
    print("Error sharing CSV: $e");
  }
}

void triggerPdfDownload(Uint8List pdfBytes, String filename) {
  // On mobile/desktop, PDF is shared via Printing.sharePdf — handled in admin_orders_pdf.dart
}
