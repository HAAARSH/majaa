import 'dart:convert';
import 'dart:typed_data';
// ignore: avoid_web_libraries_in_flutter
import 'package:universal_html/html.dart' as html;

void triggerCsvDownload(String csvContent, String filename) {
  final bytes = utf8.encode(csvContent);
  final blob = html.Blob([bytes], 'application/vnd.ms-excel');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
}

// Dual-team export — browser triggers two consecutive downloads. Most
// browsers allow multi-download from the same origin in a single click
// (Chrome prompts the first time). Returned as Future<void> to match the
// mobile signature; web work is synchronous so completes immediately.
Future<void> triggerMultiCsvDownload(List<MapEntry<String, String>> files) async {
  for (final entry in files) {
    final bytes = utf8.encode(entry.value);
    final blob = html.Blob([bytes], 'application/vnd.ms-excel');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', entry.key)
      ..click();
    html.Url.revokeObjectUrl(url);
  }
}

void triggerPdfDownload(Uint8List pdfBytes, String filename) {
  final blob = html.Blob([pdfBytes], 'application/pdf');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
}
