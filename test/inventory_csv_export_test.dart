import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:velora/services/workspace_resolver.dart';
import 'package:velora/services/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/inventory_item.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/inventory/inventory_page.dart';
import 'package:velora/services/csv_download.dart';
import 'package:velora/services/inventory_csv_export_service.dart';
import 'package:velora/services/workspace_session.dart';

WorkspaceSession session(String cafeId) => WorkspaceSession.fromVerified(
  CafeWorkspace(
    cafeId: cafeId,
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  ),
);

Map<String, dynamic> itemData({
  required String name,
  String lifecycle = 'active',
}) => {
  'name': name,
  'category': 'Dairy',
  'quantity': 4,
  'unit': 'L',
  'expiryDate': DateTime.utc(2030, 1, 2),
  'imageUrl': '',
  'createdAt': DateTime.utc(2026, 1, 1),
  'version': 1,
  'lifecycleState': lifecycle,
  if (lifecycle == 'archived') ...{
    'archivedAt': DateTime.utc(2026, 2, 1),
    'archivedBy': 'staff-a',
  },
};

class TestSnapshot extends Fake
    implements firestore.QuerySnapshot<Map<String, dynamic>> {
  @override
  List<firestore.QueryDocumentSnapshot<Map<String, dynamic>>> get docs => [];
}

// Test-only SDK boundary fake records GetOptions without connecting to Firebase.
// ignore: subtype_of_sealed_class
class TestCollection extends Fake
    implements firestore.CollectionReference<Map<String, dynamic>> {
  final options = <firestore.GetOptions?>[];
  @override
  Future<firestore.QuerySnapshot<Map<String, dynamic>>> get([
    firestore.GetOptions? option,
  ]) async {
    options.add(option);
    return TestSnapshot();
  }
}

class TestFirestore extends Fake implements firestore.FirebaseFirestore {
  final target = TestCollection();
  final paths = <String>[];
  @override
  firestore.CollectionReference<Map<String, dynamic>> collection(String path) {
    paths.add(path);
    return target;
  }
}

class TestUser extends Fake implements User {
  @override
  final String uid;
  TestUser(this.uid);
}

class TestAuth extends Fake implements FirebaseAuth {
  User? user = TestUser('staff-a');
  final changes = StreamController<User?>.broadcast(sync: true);
  @override
  User? get currentUser => user;
  @override
  Stream<User?> authStateChanges() => changes.stream;
  void change(String? uid) {
    user = uid == null ? null : TestUser(uid);
    changes.add(user);
  }
}

class TestStore implements WorkspaceStore, WorkspaceReader {
  bool revoked = false;
  bool offline = false;
  int transactions = 0;
  @override
  Future<T> readTransaction<T>(Future<T> Function(WorkspaceReader) read) async {
    transactions++;
    if (offline) throw StateError('offline');
    return read(this);
  }

  @override
  Future<Map<String, dynamic>?> readDocument(String path) async {
    if (path == 'cafes/cafe-a') {
      return {'ownerUid': 'owner-a', 'status': 'active', 'schemaVersion': 1};
    }
    final uid = path.split('/').last;
    return {
      'uid': uid,
      'cafeId': 'cafe-a',
      'status': revoked && uid == 'staff-a' ? 'revoked' : 'active',
      'schemaVersion': 1,
      if (path.contains('/members/'))
        'role': uid == 'owner-a' ? 'owner' : 'staff',
    };
  }
}

class Source
    implements
        WorkspaceInventoryDataSource,
        WorkspaceInventoryExportDataSource {
  final List<WorkspaceInventoryDocument> documents;
  final Object? readError;
  Completer<void>? pendingRead;
  void Function()? afterRead;
  int serverReads = 0;
  String? readPath;
  String? watchPath;
  Source(this.documents, {this.readError});

  @override
  Future<List<WorkspaceInventoryDocument>> readCollection(String path) async {
    readPath = path;
    if (readError != null) throw readError!;
    return documents;
  }

  @override
  Future<List<WorkspaceInventoryDocument>> readServerCollection(
    String path,
  ) async {
    serverReads++;
    await pendingRead?.future;
    final result = await readCollection(path);
    afterRead?.call();
    return result;
  }

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) {
    watchPath = path;
    return Stream.value(documents);
  }
}

class Downloader implements CsvDownloadAdapter {
  final Completer<void>? pending;
  String? filename;
  Uint8List? bytes;
  Downloader({this.pending});

  @override
  Future<void> download({
    required String filename,
    required Uint8List bytes,
  }) async {
    this.filename = filename;
    this.bytes = bytes;
    await pending?.future;
  }
}

InventoryItem unsafeItem(String name) => InventoryItem(
  id: 'unsafe',
  name: name,
  category: 'Milk, "fresh"\nDairy',
  quantity: 1,
  unit: 'L',
  expiryDate: DateTime.utc(2030, 1, 2),
  imageUrl: '',
  createdAt: DateTime.utc(2026, 1, 1),
);

void main() {
  late TestAuth auth;
  late TestStore store;
  late WorkspaceResolver resolver;
  setUp(() {
    auth = TestAuth();
    store = TestStore();
    resolver = WorkspaceResolver(auth: auth, store: store);
  });
  tearDown(() async {
    await auth.changes.close();
  });
  test(
    'CSV uses deterministic columns, ordering, escaping and formula defense',
    () {
      final csv = InventoryCsvExportService.buildCsv([
        unsafeItem('  =HYPERLINK("bad")'),
        InventoryItem(
          id: 'a',
          name: 'Apple',
          category: 'Fruit',
          quantity: 2,
          unit: 'pcs',
          expiryDate: DateTime.utc(2029, 12, 1),
          imageUrl: '',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      ]);
      final lines = csv.split('\r\n');
      expect(
        lines.first,
        '"Item Name","Category","Quantity","Unit","Expiry Date","Lifecycle Status"',
      );
      expect(lines[1], contains('"\'  =HYPERLINK(""bad"")"'));
      expect(lines[1], contains('"Milk, ""fresh""\nDairy"'));
      expect(lines[2], startsWith('"Apple"'));
    },
  );

  test(
    'active-only and include-archived exports stay on verified cafe path',
    () async {
      final source = Source([
        WorkspaceInventoryDocument(
          id: 'active',
          data: itemData(name: 'Milk'),
        ),
        WorkspaceInventoryDocument(
          id: 'archived',
          data: itemData(name: 'Cream', lifecycle: 'archived'),
        ),
      ]);
      final repository = WorkspaceInventoryRepository(
        session: session('cafe-a'),
        dataSource: source,
      );
      final downloader = Downloader();
      final service = InventoryCsvExportService(
        repository: repository,
        auth: auth,
        resolver: resolver,
        downloader: downloader,
        now: () => DateTime(2026, 11, 4),
      );

      final active = await service.export(InventoryCsvScope.activeOnly);
      expect(active.itemCount, 1);
      expect(source.readPath, 'cafes/cafe-a/inventory');
      expect(downloader.bytes, isA<Uint8List>());
      expect(downloader.bytes!.take(3), [0xEF, 0xBB, 0xBF]);
      var csv = utf8.decode(downloader.bytes!.skip(3).toList());
      expect(csv, contains('"Milk"'));
      expect(csv, isNot(contains('"Cream"')));

      final all = await service.export(InventoryCsvScope.includeArchived);
      expect(all.itemCount, 2);
      csv = utf8.decode(downloader.bytes!.skip(3).toList());
      expect(csv, contains('"active"'));
      expect(csv, contains('"archived"'));
      expect(downloader.filename, 'velora-inventory-2026-11-04.csv');
    },
  );

  test(
    'empty, malformed and permission/read failures never download',
    () async {
      final emptyDownloader = Downloader();
      final empty = InventoryCsvExportService(
        repository: WorkspaceInventoryRepository(
          session: session('cafe-a'),
          dataSource: Source([]),
        ),
        auth: auth,
        resolver: resolver,
        downloader: emptyDownloader,
      );
      await expectLater(
        empty.export(InventoryCsvScope.activeOnly),
        throwsA(isA<InventoryCsvEmptyException>()),
      );
      expect(emptyDownloader.bytes, isNull);

      for (final source in [
        Source([
          WorkspaceInventoryDocument(
            id: 'bad',
            data: itemData(name: 'Milk')..['quantity'] = -1,
          ),
        ]),
        Source([], readError: StateError('permission-denied')),
      ]) {
        final downloader = Downloader();
        final service = InventoryCsvExportService(
          repository: WorkspaceInventoryRepository(
            session: session('cafe-a'),
            dataSource: source,
          ),
          auth: auth,
          resolver: resolver,
          downloader: downloader,
        );
        await expectLater(
          service.export(InventoryCsvScope.includeArchived),
          throwsA(anything),
        );
        expect(downloader.bytes, isNull);
      }
    },
  );

  test('session change before download discards stale cafe export', () async {
    final source = Source([
      WorkspaceInventoryDocument(
        id: 'active',
        data: itemData(name: 'Milk'),
      ),
    ]);
    final downloader = Downloader();
    final service = InventoryCsvExportService(
      repository: WorkspaceInventoryRepository(
        session: session('cafe-a'),
        dataSource: source,
      ),
      auth: auth,
      resolver: resolver,
      downloader: downloader,
    );
    var currentCafe = 'cafe-a';
    final future = service.export(
      InventoryCsvScope.activeOnly,
      isSessionCurrent: () => currentCafe == 'cafe-a',
    );
    currentCafe = 'cafe-b';
    await expectLater(
      future,
      throwsA(isA<InventoryCsvSessionChangedException>()),
    );
    expect(downloader.bytes, isNull);
  });

  testWidgets(
    'Inventory export prevents duplicate requests while downloading',
    (tester) async {
      final source = Source([
        WorkspaceInventoryDocument(
          id: 'active',
          data: itemData(name: 'Milk'),
        ),
      ]);
      final repository = WorkspaceInventoryRepository(
        session: session('cafe-a'),
        dataSource: source,
      );
      final pending = Completer<void>();
      final downloader = Downloader(pending: pending);
      await tester.pumpWidget(
        MaterialApp(
          home: InventoryPage(
            workspaceSession: session('cafe-a'),
            repository: repository,
            csvExportService: InventoryCsvExportService(
              repository: repository,
              auth: auth,
              resolver: resolver,
              downloader: downloader,
            ),
          ),
        ),
      );
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byKey(const ValueKey('export-inventory-csv')));
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byKey(const ValueKey('export-active-only')));
      await tester.pump();
      expect(downloader.bytes, isNotNull);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('export-inventory-csv')),
            )
            .onPressed,
        isNull,
      );
      pending.complete();
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Exported 1 inventory items.'), findsOneWidget);
    },
  );
  test(
    'export requires server source while normal reads keep default source',
    () async {
      final db = TestFirestore();
      final repository = WorkspaceInventoryRepository(
        session: session('cafe-a'),
        dataSource: FirestoreWorkspaceInventoryDataSource(firestore: db),
      );
      await repository.getItems();
      await repository.getAllItems();
      expect(db.target.options.first, isNull);
      expect(db.target.options.last!.source, firestore.Source.server);
      expect(db.paths, ['cafes/cafe-a/inventory', 'cafes/cafe-a/inventory']);
    },
  );

  for (final change in [
    'sign-out',
    'same-cafe user',
    'revoked',
    'offline',
    'auth away-back',
  ]) {
    test('pending read fails closed: $change', () async {
      final source = Source([
        WorkspaceInventoryDocument(
          id: 'a',
          data: itemData(name: 'Milk'),
        ),
      ]);
      source.afterRead = () {
        switch (change) {
          case 'sign-out':
            auth.change(null);
          case 'same-cafe user':
            auth.change('staff-b');
          case 'revoked':
            store.revoked = true;
          case 'offline':
            store.offline = true;
          case 'auth away-back':
            auth.change(null);
            auth.change('staff-a');
        }
      };
      final downloader = Downloader();
      final service = InventoryCsvExportService(
        repository: WorkspaceInventoryRepository(
          session: session('cafe-a'),
          dataSource: source,
        ),
        auth: auth,
        resolver: resolver,
        downloader: downloader,
      );
      await expectLater(
        service.export(InventoryCsvScope.activeOnly),
        throwsA(anything),
      );
      expect(source.serverReads, 1);
      expect(downloader.bytes, isNull);
    });
  }

  for (final transition in ['cafe-switch', 'cafe-away-back', 'dispose']) {
    testWidgets('pending widget export rejected: $transition', (tester) async {
      final source = Source([
        WorkspaceInventoryDocument(
          id: 'a',
          data: itemData(name: 'Milk'),
        ),
      ]);
      final pending = Completer<void>();
      source.pendingRead = pending;
      final repository = WorkspaceInventoryRepository(
        session: session('cafe-a'),
        dataSource: source,
      );
      final downloader = Downloader();
      final service = InventoryCsvExportService(
        repository: repository,
        auth: auth,
        resolver: resolver,
        downloader: downloader,
      );
      Widget host(String cafe) => MaterialApp(
        home: InventoryPage(
          workspaceSession: session(cafe),
          repository: repository,
          csvExportService: service,
        ),
      );
      await tester.pumpWidget(host('cafe-a'));
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byKey(const ValueKey('export-inventory-csv')));
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byKey(const ValueKey('export-active-only')));
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(source.serverReads, 1);
      if (transition == 'dispose') {
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      } else {
        await tester.pumpWidget(host('cafe-b'));
        if (transition == 'cafe-away-back') {
          await tester.pumpWidget(host('cafe-a'));
        }
      }
      pending.complete();
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(downloader.bytes, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('chooser locks immediately against overlapping requests', (
    tester,
  ) async {
    final source = Source([
      WorkspaceInventoryDocument(
        id: 'a',
        data: itemData(name: 'Milk'),
      ),
    ]);
    final repository = WorkspaceInventoryRepository(
      session: session('cafe-a'),
      dataSource: source,
    );
    final downloader = Downloader();
    await tester.pumpWidget(
      MaterialApp(
        home: InventoryPage(
          workspaceSession: session('cafe-a'),
          repository: repository,
          csvExportService: InventoryCsvExportService(
            repository: repository,
            auth: auth,
            resolver: resolver,
            downloader: downloader,
          ),
        ),
      ),
    );
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final button = find.byKey(const ValueKey('export-inventory-csv'));
    final start = tester.widget<OutlinedButton>(button).onPressed!;
    start();
    start();
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Export inventory'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    await tester.tap(find.text('Cancel'));
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    expect(source.serverReads, 0);
    expect(downloader.bytes, isNull);
  });
}
