import 'dart:typed_data';

import 'csv_download_stub.dart' if (dart.library.html) 'csv_download_web.dart';

abstract interface class CsvDownloadAdapter {
  Future<void> download({required String filename, required Uint8List bytes});
}

CsvDownloadAdapter createCsvDownloadAdapter() => createPlatformCsvDownloader();
