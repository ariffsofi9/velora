import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';

import 'workspace_resolver.dart';

import '../models/inventory_item.dart';
import '../repositories/workspace_inventory_repository.dart';
import 'csv_download.dart';

enum InventoryCsvScope { activeOnly, includeArchived }

class InventoryCsvExportResult {
  final int itemCount;
  final String filename;
  const InventoryCsvExportResult(this.itemCount, this.filename);
}

class InventoryCsvExportService {
  final WorkspaceInventoryRepository repository;
  final CsvDownloadAdapter downloader;
  final DateTime Function() now;
  final FirebaseAuth? _auth;
  final WorkspaceResolver? _resolver;
  bool _exporting = false;

  FirebaseAuth get auth => _auth ?? FirebaseAuth.instance;

  InventoryCsvExportService({
    required this.repository,
    CsvDownloadAdapter? downloader,
    DateTime Function()? now,
    FirebaseAuth? auth,
    WorkspaceResolver? resolver,
  }) : downloader = downloader ?? createCsvDownloadAdapter(),
       now = now ?? DateTime.now,
       _auth = auth,
       _resolver = resolver;

  Future<InventoryCsvExportResult> export(
    InventoryCsvScope scope, {
    bool Function()? isSessionCurrent,
  }) async {
    if (_exporting) throw StateError('Export already in progress.');
    _exporting = true;
    StreamSubscription<User?>? subscription;
    var invalidated = false;
    final expected = repository.session;
    try {
      var lastUid = auth.currentUser?.uid;
      void check() {
        if (invalidated ||
            !expected.isActive ||
            auth.currentUser?.uid != expected.uid ||
            (isSessionCurrent != null && !isSessionCurrent())) {
          throw const InventoryCsvSessionChangedException();
        }
      }

      check();
      subscription = auth.authStateChanges().listen(
        (user) {
          if (user?.uid != lastUid) invalidated = true;
          lastUid = user?.uid;
        },
        onError: (Object _) {
          invalidated = true;
        },
      );
      Future<void> authorize() async {
        check();
        final workspace = await (_resolver ?? WorkspaceResolver(auth: auth))
            .resolve();
        check();
        if (workspace.uid != expected.uid ||
            workspace.cafeId != expected.cafeId ||
            workspace.ownerUid != expected.ownerUid ||
            workspace.membershipGeneration != expected.membershipGeneration ||
            workspace.role != expected.role) {
          throw const InventoryCsvSessionChangedException();
        }
      }

      await authorize();
      final all = await repository.getAllItems();
      check();
      final items = scope == InventoryCsvScope.activeOnly
          ? all.where((item) => !item.isArchived).toList(growable: false)
          : all;
      if (items.isEmpty) throw const InventoryCsvEmptyException();
      final csv = buildCsv(items);
      final date = now().toLocal();
      final filename =
          'velora-inventory-${date.year}-${_two(date.month)}-${_two(date.day)}.csv';
      await authorize();
      check();
      await downloader.download(
        filename: filename,
        bytes: Uint8List.fromList(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]),
      );
      return InventoryCsvExportResult(items.length, filename);
    } finally {
      unawaited(subscription?.cancel());
      _exporting = false;
    }
  }

  static String buildCsv(List<InventoryItem> source) {
    final items = [...source]
      ..sort((a, b) {
        final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
    final rows = <List<String>>[
      const [
        'Item Name',
        'Category',
        'Quantity',
        'Unit',
        'Expiry Date',
        'Lifecycle Status',
      ],
      for (final item in items)
        [
          item.name,
          item.category,
          item.quantity.toString(),
          item.unit,
          _date(item.expiryDate),
          item.lifecycleState.name,
        ],
    ];
    return rows.map((row) => row.map(_cell).join(',')).join('\r\n');
  }

  static String _cell(String value) {
    final trimmed = value.trimLeft();
    final protected =
        trimmed.isNotEmpty &&
            const {'=', '+', '-', '@', '\t', '\r', '\n'}.contains(trimmed[0])
        ? "'$value"
        : value;
    return '"${protected.replaceAll('"', '""')}"';
  }

  static String _date(DateTime value) {
    final utc = value.toUtc();
    return '${utc.year}-${_two(utc.month)}-${_two(utc.day)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

class InventoryCsvEmptyException implements Exception {
  const InventoryCsvEmptyException();
}

class InventoryCsvSessionChangedException implements Exception {
  const InventoryCsvSessionChangedException();
}
