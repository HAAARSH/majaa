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

// Dual-team export: bundles both team CSVs into ONE share sheet so admin
// picks a save destination once. Writing individual files then calling
// triggerCsvDownload twice opens the share sheet twice and confuses reps.
Future<void> triggerMultiCsvDownload(List<MapEntry<String, String>> files) async {
  try {
    final directory = await getTemporaryDirectory();
    final xFiles = <XFile>[];
    for (final entry in files) {
      final file = File('${directory.path}/${entry.key}');
      await file.writeAsString(entry.value);
      xFiles.add(XFile(file.path, mimeType: 'application/vnd.ms-excel'));
    }
    await SharePlus.instance.share(
      ShareParams(
        files: xFiles,
        text: 'Order Export: ${files.map((e) => e.key).join(', ')}',
      ),
    );
  } catch (e) {
    debugPrint('Error sharing CSVs: $e');
  }
}

void triggerPdfDownload(Uint8List pdfBytes, String filename) {
  // On mobile/desktop, PDF is shared via Printing.sharePdf — handled in admin_orders_tab.dart
}
