// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:html' as html;
import 'dart:typed_data';

import 'csv_download.dart';

CsvDownloadAdapter createPlatformCsvDownloader() => const WebCsvDownloader();

class WebCsvDownloader implements CsvDownloadAdapter {
  const WebCsvDownloader();

  @override
  Future<void> download({
    required String filename,
    required Uint8List bytes,
  }) async {
    final blob = html.Blob([bytes], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    try {
      html.AnchorElement(href: url)
        ..download = filename
        ..click();
    } finally {
      html.Url.revokeObjectUrl(url);
    }
  }
}
