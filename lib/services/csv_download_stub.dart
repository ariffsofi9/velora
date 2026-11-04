import 'dart:typed_data';

import 'csv_download.dart';

CsvDownloadAdapter createPlatformCsvDownloader() =>
    const UnsupportedCsvDownloader();

class UnsupportedCsvDownloader implements CsvDownloadAdapter {
  const UnsupportedCsvDownloader();

  @override
  Future<void> download({required String filename, required Uint8List bytes}) =>
      Future.error(
        UnsupportedError('CSV download is available in Flutter Web only.'),
      );
}
