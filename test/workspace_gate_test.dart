import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:velora/screens/auth/owner_email_verification_page.dart';
import 'package:velora/screens/business_setup/business_setup_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/repositories/workspace_inventory_repository.dart';
import 'package:velora/screens/auth/login_page.dart';
import 'package:velora/screens/auth/splash_page.dart';
import 'package:velora/screens/auth/workspace_gate.dart';
import 'package:velora/screens/inventory/inventory_page.dart';
import 'package:velora/screens/inventory/stock/stock_adjustment_page.dart';
import 'package:velora/services/auth_service.dart';
import 'package:velora/services/android_pilot_policy.dart';
import 'package:velora/services/offline_verified_workspace_inventory.dart';
import 'package:velora/services/mutation_recovery_service.dart';
import 'package:velora/services/platform_journal_store.dart';
import 'package:velora/services/workspace_inventory_https_transport.dart';
import 'package:velora/services/workspace_resolver.dart';
import 'package:velora/services/workspace_session.dart';

import 'workspace_inventory_https_transport_test.dart'
    show acknowledgement, create;
import 'inventory_lifecycle_test.dart' show Source, data;
import 'mutation_recovery_service_test.dart'
    show FakeMutationPersistence, syntheticSha256;
import 'platform_journal_store_test.dart' show FakeTransactionalJournalEngine;

class _Resolver extends WorkspaceResolver {
  Future<CafeWorkspace> Function() result;
  int calls = 0;

  _Resolver(this.result);

  @override
  Future<CafeWorkspace> resolve() {
    calls++;
    return result();
  }
}

class _Auth extends Fake implements AuthService {
  @override
  final _FirebaseAuth firebaseAuth;
  int calls = 0;

  _Auth([_FirebaseAuth? auth]) : firebaseAuth = auth ?? _FirebaseAuth(_User());

  @override
  Future<void> signIn({required String email, required String password}) async {
    calls++;
  }

  @override
  Future<bool> canRestoreSession() async => firebaseAuth.currentUser != null;
}

class _User extends Fake implements User {
  @override
  final String uid;
  bool verified;
  bool tokenVerified = true;
  Object? reloadError;
  int reloads = 0;
  _User({this.uid = 'owner-a', this.verified = true});

  @override
  bool get emailVerified => verified;

  @override
  Future<void> reload() async {
    reloads++;
    if (reloadError case final error?) throw error;
  }

  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) async {
    expect(forceRefresh, isTrue);
    return _Token(tokenVerified);
  }

  @override
  String get email => 'synthetic@example.invalid';

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    String encode(Object data) =>
        base64Url.encode(utf8.encode(jsonEncode(data))).replaceAll('=', '');
    final now = _offlineNow.millisecondsSinceEpoch ~/ 1000;
    final header = encode({'alg': 'RS256', 'kid': 'fake'});
    final claims = encode({
      'sub': uid,
      'aud': _offlineProject,
      'iss': 'https://securetoken.google.com/$_offlineProject',
      'email': email,
      'email_verified': verified,
      'iat': now - 1,
      'auth_time': now - 2,
      'exp': now + 100,
    });
    return '$header.$claims.c3ludGhldGlj';
  }
}

class _Token extends Fake implements IdTokenResult {
  final bool verified;
  _Token(this.verified);
  @override
  Map<String, dynamic> get claims => {'email_verified': verified};
}

class _FirebaseAuth extends Fake implements FirebaseAuth {
  final _events = StreamController<User?>.broadcast(sync: true);
  _FirebaseAuth(this.currentUser);

  @override
  final FirebaseApp app = _OfflineApp();

  @override
  _User? currentUser;

  void replace(_User? user) {
    currentUser = user;
    _events.add(user);
  }

  @override
  Stream<User?> authStateChanges() => Stream<User?>.multi((events) {
    final subscription = _events.stream.listen(events.addSync);
    events.onCancel = subscription.cancel;
    events.addSync(currentUser);
  });

  @override
  Future<void> signOut() async => replace(null);
}

const _offlineProject = 'velora-spark-test';
final _offlineNow = DateTime.utc(2026, 11, 21);

class _OfflineApp extends Fake implements FirebaseApp {
  @override
  FirebaseOptions get options => const FirebaseOptions(
    apiKey: 'synthetic',
    appId: 'synthetic',
    messagingSenderId: 'synthetic',
    projectId: _offlineProject,
  );
}

class _OfflineHandoff {
  final _FirebaseAuth auth;
  final authority = StreamController<bool>.broadcast(sync: true);
  final requests = <http.Request>[];
  late final OfflineVerifiedWorkspaceInventory inventory;
  HttpsWorkspaceInventory? transport;
  Future<http.Response> Function(http.Request)? respond;
  final bool showInventory;
  final WorkspaceInventoryDataSource? inventorySource;

  _OfflineHandoff(
    String uid, {
    this.showInventory = false,
    this.inventorySource,
    MutationRecoveryJournal? journal,
    PlatformJournalStore? guardedStore,
  }) : auth = _FirebaseAuth(_User(uid: uid)) {
    inventory = OfflineVerifiedWorkspaceInventory(
      auth: auth,
      projectId: _offlineProject,
      policy: AndroidPilotPolicy.parse(
        const {},
        isWeb: false,
        platform: TargetPlatform.android,
      ),
      now: () => _offlineNow,
      journal: journal,
      guardedStore: guardedStore,
      respond: (request) async {
        requests.add(request);
        if (respond case final handler?) return handler(request);
        return http.Response(
          jsonEncode({...acknowledgement('create'), 'cafeId': 'cafe-a'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
  }

  Widget app(_Resolver resolver) => MaterialApp(
    theme: AppTheme.light,
    home: WorkspaceGate(
      authService: _Auth(auth),
      resolver: resolver,
      offlineInventory: inventory,
      offlineAuthority: authority.stream,
      offlineHomeBuilder: (_, session, transport) {
        this.transport = transport;
        if (showInventory) {
          return InventoryPage.offlineRest(
            workspaceSession: session,
            repository: WorkspaceInventoryRepository(
              session: session,
              dataSource:
                  inventorySource ??
                  Source([
                    WorkspaceInventoryDocument(id: 'item', data: data()),
                    WorkspaceInventoryDocument(
                      id: 'archived',
                      data: {
                        ...data(lifecycle: 'archived'),
                        'name': 'Archived flour',
                      },
                    ),
                  ]),
            ),
            transport: transport,
          );
        }
        return Scaffold(body: Text('Offline ${session.role.name}'));
      },
    ),
  );

  Future<void> close() async {
    await inventory.close();
    await authority.close();
    await auth._events.close();
  }
}

const owner = CafeWorkspace(
  cafeId: 'cafe-a',
  uid: 'owner-a',
  ownerUid: 'owner-a',
  role: CafeRole.owner,
);

const staff = CafeWorkspace(
  cafeId: 'cafe-a',
  uid: 'staff-a',
  ownerUid: 'owner-a',
  role: CafeRole.staff,
);

Widget _app(_Resolver resolver, {_Auth? auth}) => MaterialApp(
  theme: AppTheme.light,
  home: WorkspaceGate(
    resolver: resolver,
    authService: auth ?? _Auth(),
    homeBuilder: (_, session) => Scaffold(
      body: Text('Verified Home ${session.cafeId} ${session.role.name}'),
    ),
    setupBuilder: (_) => const Scaffold(body: Text('Setup Preview')),
  ),
);

Future<void> _expectNoDispatch(
  WidgetTester tester,
  HttpsWorkspaceInventory transport,
) async {
  await tester.runAsync(
    () => expectLater(transport.createItem(create()), throwsException),
  );
}

http.Response _jsonResponse(Map<String, Object?> body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

Future<_OfflineHandoff> _openInventory(
  WidgetTester tester, {
  MutationRecoveryJournal? journal,
  PlatformJournalStore? guardedStore,
  WorkspaceInventoryDataSource? inventorySource,
  _Resolver? resolver,
}) async {
  final handoff = _OfflineHandoff(
    staff.uid,
    showInventory: true,
    journal: journal,
    guardedStore: guardedStore,
    inventorySource: inventorySource,
  );
  addTearDown(handoff.close);
  tester.view.physicalSize = const Size(900, 1300);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    handoff.app(resolver ?? _Resolver(() async => staff)),
  );
  await tester.pump(const Duration(milliseconds: 500));
  handoff.authority.add(true);
  await tester.pumpAndSettle();
  expect(find.byType(InventoryPage), findsOneWidget);
  return handoff;
}

Future<void> _openAdd(WidgetTester tester) async {
  await tester.tap(find.byType(FloatingActionButton));
  await tester.pumpAndSettle();
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), 'Fresh flour');
  await tester.enterText(fields.at(1), '4');
  await tester.ensureVisible(find.text('Select date'));
  await tester.tap(find.text('Select date'));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.chevron_right).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('15').last);
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

Future<void> _openItem(WidgetTester tester, {bool archived = false}) async {
  if (archived) {
    await tester.tap(find.byKey(const ValueKey('open-archived-items')));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(archived ? 'Archived flour' : 'Milk'));
  await tester.pumpAndSettle();
}

Future<void> _openStock(WidgetTester tester, String label) async {
  await _openItem(tester);
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('stock-quantity-field')),
    '2',
  );
}

Future<void> _submitInventory(WidgetTester tester, Finder button) async {
  await tester.ensureVisible(button);
  await tester.runAsync(() async {
    await tester.tap(button);
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pumpAndSettle();
}

class _ObservedInventorySource extends Source {
  int watches = 0;

  _ObservedInventorySource(int version, int quantity)
    : super([
        WorkspaceInventoryDocument(
          id: 'item',
          data: {...data(), 'version': version, 'quantity': quantity},
        ),
      ]);

  @override
  Stream<List<WorkspaceInventoryDocument>> watchCollection(String path) {
    watches++;
    return super.watchCollection(path);
  }
}

const _stockConfirm = ValueKey('stock-confirm-button');
const _openInventoryRecovery = ValueKey('inventory-recovery-open');

void _inventoryUiCases() {
  for (final action in [
    'Add',
    'Edit Item',
    'Stock In',
    'Stock Out',
    'Archive',
    'Restore',
  ]) {
    testWidgets(
      'offline inventory UI submits $action through its pinned REST port',
      (tester) async {
        final handoff = await _openInventory(tester);
        final endpoint = switch (action) {
          'Add' => 'create',
          'Edit Item' => 'update',
          'Stock In' || 'Stock Out' => 'adjust-stock',
          _ => 'lifecycle',
        };
        handoff.respond = (request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return _jsonResponse({
            ...acknowledgement(endpoint),
            'cafeId': 'cafe-a',
            if (endpoint != 'create') ...{
              'itemId': body['itemId'],
              'version': (body['expectedVersion'] as int) + 1,
            },
            if (endpoint == 'adjust-stock') ...{
              'direction': body['direction'],
              'resultingQuantity': action == 'Stock In' ? 6 : 2,
            },
            if (endpoint == 'lifecycle')
              'lifecycleState': action == 'Restore' ? 'active' : 'archived',
          });
        };

        final Finder button;
        switch (action) {
          case 'Add':
            await _openAdd(tester);
            button = find.text('Save Item');
          case 'Edit Item':
            await _openItem(tester);
            await tester.tap(find.text(action));
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextField).first, 'Fresh Milk');
            button = find.text('Save Changes');
          case 'Stock In':
          case 'Stock Out':
            await _openStock(tester, action);
            button = find.byKey(const ValueKey('stock-confirm-button'));
          default:
            await _openItem(tester, archived: action == 'Restore');
            final trigger = find.text('$action Item');
            await tester.ensureVisible(trigger);
            await tester.tap(trigger);
            await tester.pumpAndSettle();
            button = find.byKey(const ValueKey('lifecycle-confirm'));
        }
        await _submitInventory(tester, button);
        final request = handoff.requests.single;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(request.url.path, '/inventory/$endpoint');
        expect(request.headers['authorization'], startsWith('Bearer '));
        expect(body['expectedCafeId'], 'cafe-a');
        expect(body['idempotencyKey'], isNotEmpty);
        if (endpoint == 'update') expect(body['name'], 'Fresh Milk');
        if (endpoint == 'lifecycle') {
          expect(body['action'], action.toLowerCase());
        }
        if (endpoint == 'adjust-stock') {
          expect(body['direction'], action == 'Stock In' ? 'in' : 'out');
          expect(body['quantity'], 2);
        }
        expect(button, findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final (label, status, code, message) in [
    (
      'authorization denial',
      403,
      'permission-denied',
      'Your workspace access could not be verified.',
    ),
    ('validation error', 400, 'invalid-argument', 'Check the item details'),
    ('network failure', 0, '', 'Check your connection'),
    ('server deadline', 408, 'deadline-exceeded', 'Check your connection'),
  ]) {
    testWidgets('offline inventory UI handles $label without replay', (
      tester,
    ) async {
      final handoff = await _openInventory(tester);
      handoff.respond = (_) async {
        if (status == 0) {
          throw http.ClientException('synthetic network failure');
        }
        return _jsonResponse({'error': code}, status);
      };
      await _openAdd(tester);
      await _submitInventory(tester, find.text('Save Item'));
      expect(find.textContaining(message), findsOneWidget);
      expect(find.text('Save Item'), findsOneWidget);
      expect(handoff.requests, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final transition in ['logout', 'same UID', 'workspace', 'disposal']) {
    testWidgets('pending inventory UI response is fenced after $transition', (
      tester,
    ) async {
      final journal = MutationRecoveryJournal(
        FakeMutationPersistence(),
        sha256: syntheticSha256,
      );
      final resolver = _Resolver(() async => staff);
      final handoff = await _openInventory(
        tester,
        journal: journal,
        resolver: resolver,
      );
      late Completer<http.Response> reply;
      await _openStock(tester, 'Stock Out');
      final confirm = find.byKey(const ValueKey('stock-confirm-button'));
      await tester.ensureVisible(confirm);
      await tester.pump();
      await tester.runAsync(() async {
        final started = Completer<void>();
        reply = Completer<http.Response>();
        handoff.respond = (_) {
          started.complete();
          return reply.future;
        };
        await tester.tap(confirm);
        await started.future.timeout(const Duration(seconds: 3));
      });
      switch (transition) {
        case 'logout':
          handoff.auth.replace(null);
        case 'same UID':
          handoff.auth.replace(_User(uid: staff.uid));
        case 'workspace':
          resolver.result = () async => const CafeWorkspace(
            cafeId: 'other-cafe',
            uid: 'staff-a',
            ownerUid: 'owner-a',
            role: CafeRole.staff,
          );
          handoff.authority.add(true);
        case 'disposal':
          await tester.pumpWidget(const SizedBox());
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stock-confirm-button')), findsNothing);
      final submitted =
          jsonDecode(handoff.requests.single.body) as Map<String, dynamic>;
      await tester.runAsync(() async {
        reply.complete(
          _jsonResponse({
            ...acknowledgement('adjust-stock'),
            'cafeId': 'cafe-a',
            'version': 3,
            'resultingQuantity': 2,
          }),
        );
        await Future<void>.delayed(Duration.zero);
        final pending = await journal.load(
          _offlineProject,
          staff.uid,
          'adjust-stock',
          submitted['idempotencyKey'] as String,
        );
        expect(pending?.unresolved, isTrue);
        await expectLater(
          handoff.transport!.reconcile(pending!),
          throwsA(isA<InventoryHttpsFailure>()),
        );
      });
      expect(handoff.requests, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'uncertain UI stock change reconciles without repeating stock movement',
    (tester) async {
      final journal = MutationRecoveryJournal(
        FakeMutationPersistence(),
        sha256: syntheticSha256,
      );
      final handoff = await _openInventory(tester, journal: journal);
      var movements = 0;
      Map<String, Object?>? receipt;
      handoff.respond = (request) async {
        if (request.url.path == '/inventory/reconcile') {
          return _jsonResponse({'state': 'committed', 'result': receipt});
        }
        movements++;
        receipt = {
          ...acknowledgement('adjust-stock'),
          'cafeId': 'cafe-a',
          'version': 3,
          'resultingQuantity': 2,
        };
        return _jsonResponse({'error': 'unavailable'}, 503);
      };
      await _openStock(tester, 'Stock Out');
      await _submitInventory(
        tester,
        find.byKey(const ValueKey('stock-confirm-button')),
      );
      expect(
        find.textContaining('Could not confirm the result'),
        findsOneWidget,
      );
      final mutation = handoff.requests.single;
      final submitted = jsonDecode(mutation.body) as Map<String, dynamic>;
      final stableKey = submitted['idempotencyKey'] as String;
      await tester.runAsync(() async {
        final pending = (await journal.load(
          _offlineProject,
          staff.uid,
          'adjust-stock',
          stableKey,
        ))!;
        expect(pending.unresolved, isTrue);
        expect(pending.stableKey, stableKey);
        expect((await handoff.transport!.reconcile(pending)).committed, isTrue);
        final observation =
            jsonDecode(handoff.requests.last.body) as Map<String, dynamic>;
        expect(observation, pending.observationEnvelope);
        expect(
          (await journal.load(
            _offlineProject,
            staff.uid,
            'adjust-stock',
            stableKey,
          ))!.unresolved,
          isFalse,
        );
        expect(movements, 1);
      });
      final stale = handoff.transport!;
      handoff.auth.replace(_User(uid: staff.uid));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final pending = (await journal.load(
          _offlineProject,
          staff.uid,
          'adjust-stock',
          stableKey,
        ))!;
        await expectLater(
          stale.reconcile(pending),
          throwsA(isA<InventoryHttpsFailure>()),
        );
        expect(handoff.requests.map((request) => request.url.path), [
          '/inventory/adjust-stock',
          '/inventory/reconcile',
        ]);
        expect(movements, 1);
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'guarded Staff Stock Out blocks a new key after reopening until explicit recovery',
    (tester) async {
      final engine = (await tester.runAsync(
        () async => FakeTransactionalJournalEngine(),
      ))!;
      final store = PlatformJournalStore(
        engine: engine,
        sha256: syntheticSha256,
      );
      final original = await _openInventory(tester, guardedStore: store);
      final movements = <Map<String, Object?>>[];
      var version = 2;
      var quantity = 4;
      var receiptVisible = false;
      late Map<String, Object?> historicalReceipt;

      Future<http.Response> respond(http.Request request) async {
        final payload = jsonDecode(request.body) as Map<String, Object?>;
        if (request.url.path == '/inventory/reconcile') {
          return _jsonResponse(
            receiptVisible
                ? {'state': 'committed', 'result': historicalReceipt}
                : {'state': 'unknown'},
          );
        }
        expect(request.url.path, '/inventory/adjust-stock');
        expect(payload['expectedVersion'], version);
        expect(payload['direction'], 'out');
        quantity -= payload['quantity'] as int;
        version++;
        final movement = {
          ...acknowledgement('adjust-stock'),
          'cafeId': 'cafe-a',
          'version': version,
          'resultingQuantity': quantity,
        };
        movements.add(movement);
        if (movements.length == 1) {
          historicalReceipt = movement;
          throw http.ClientException('Committed response lost');
        }
        return _jsonResponse(movement);
      }

      original.respond = respond;
      expect(original.transport!.isGuarded, isTrue);
      await _openStock(tester, 'Stock Out');
      await _submitInventory(tester, find.byKey(_stockConfirm));
      expect(original.requests, hasLength(1));
      expect(movements, hasLength(1));
      expect(quantity, 2);
      expect(version, 3);
      final firstPayload = jsonDecode(original.requests.single.body);
      final pending = (await tester.runAsync(
        original.transport!.pendingInventory,
      ))!.single;
      expect(pending.state, 'unknown');
      expect(pending.request, firstPayload);
      final before = Map.of(engine.values);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final refreshedSource = _ObservedInventorySource(version, quantity);
      final reopened = await _openInventory(
        tester,
        guardedStore: store,
        inventorySource: refreshedSource,
      );
      reopened.respond = respond;
      expect(reopened.requests, isEmpty);
      await _openStock(tester, 'Stock Out');
      expect(
        tester.widget<StockOutPage>(find.byType(StockOutPage)).item.version,
        3,
      );
      await _submitInventory(tester, find.byKey(_stockConfirm));
      expect(
        find.textContaining('Review the original stock adjustment'),
        findsOneWidget,
      );
      expect(reopened.requests, isEmpty);
      expect(movements, hasLength(1));
      expect(engine.values, before);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      final watchesBeforeObservation = refreshedSource.watches;
      await _submitInventory(tester, find.byKey(_openInventoryRecovery));
      expect(
        find.text('Pending inventory changes are unresolved.'),
        findsOneWidget,
      );
      expect(reopened.requests, isEmpty);

      await _submitInventory(tester, find.text('Check outcome'));
      expect(
        find.text('The original inventory change is still unresolved.'),
        findsOneWidget,
      );
      expect(engine.values, before);
      expect(refreshedSource.watches, watchesBeforeObservation);
      expect(movements, hasLength(1));

      receiptVisible = true;
      await _submitInventory(tester, find.text('Check outcome'));
      expect(
        find.text('The original inventory change was confirmed.'),
        findsOneWidget,
      );
      expect(refreshedSource.watches, greaterThan(watchesBeforeObservation));
      expect(reopened.requests, hasLength(2));
      for (final request in reopened.requests) {
        expect(request.url.path, '/inventory/reconcile');
        expect(jsonDecode(request.body), pending.observationEnvelope);
      }
      expect(movements, hasLength(1));
      final settled = await tester.runAsync(
        () => reopened.transport!.journal!.load(
          _offlineProject,
          staff.uid,
          pending.operation,
          pending.stableKey,
        ),
      );
      expect(settled!.state, 'acknowledged');
      expect(settled.request, pending.request);
      expect(settled.payloadDigest, pending.payloadDigest);

      await tester.tap(find.byKey(const ValueKey('inventory-recovery-close')));
      await tester.pumpAndSettle();
      await _openStock(tester, 'Stock Out');
      await _submitInventory(tester, find.byKey(_stockConfirm));
      expect(reopened.requests, hasLength(3));
      final next = reopened.requests.last;
      final nextPayload = jsonDecode(next.body) as Map<String, Object?>;
      expect(next.url.path, '/inventory/adjust-stock');
      expect(nextPayload['expectedVersion'], 3);
      expect(nextPayload['idempotencyKey'], isNot(pending.stableKey));
      expect(movements, hasLength(2));
      expect(quantity, 0);
      expect(version, 4);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'same-UID replacement hides recovery and fences a late committed observation',
    (tester) async {
      final engine = (await tester.runAsync(
        () async => FakeTransactionalJournalEngine(),
      ))!;
      final store = PlatformJournalStore(
        engine: engine,
        sha256: syntheticSha256,
      );
      final handoff = await _openInventory(tester, guardedStore: store);
      late Completer<void> started;
      late Completer<http.Response> reply;
      handoff.respond = (request) async {
        if (request.url.path == '/inventory/reconcile') {
          started.complete();
          return reply.future;
        }
        throw http.ClientException('Synthetic acknowledgement lost');
      };
      await _openStock(tester, 'Stock Out');
      await _submitInventory(tester, find.byKey(_stockConfirm));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await _submitInventory(tester, find.byKey(_openInventoryRecovery));
      expect(find.text('Check outcome'), findsOneWidget);
      expect(handoff.requests, hasLength(1));
      final before = Map.of(engine.values);
      await tester.runAsync(() async {
        started = Completer<void>();
        reply = Completer<http.Response>();
        await tester.tap(find.text('Check outcome'));
        await started.future.timeout(const Duration(seconds: 3));
      });

      handoff.auth.replace(_User(uid: staff.uid));
      await tester.pumpAndSettle();
      expect(find.text('Check outcome'), findsNothing);
      expect(
        find.text('Pending inventory changes are unresolved.'),
        findsNothing,
      );
      await tester.runAsync(() async {
        reply.complete(
          _jsonResponse({
            'state': 'committed',
            'result': {
              ...acknowledgement('adjust-stock'),
              'cafeId': 'cafe-a',
              'version': 3,
              'resultingQuantity': 2,
            },
          }),
        );
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(
        find.text('The original inventory change was confirmed.'),
        findsNothing,
      );
      expect(engine.values, before);
      expect(handoff.requests.map((request) => request.url.path), [
        '/inventory/adjust-stock',
        '/inventory/reconcile',
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

void main() {
  _inventoryUiCases();
  for (final workspace in [owner, staff]) {
    testWidgets('offline gate hands off verified ${workspace.role.name}', (
      tester,
    ) async {
      final handoff = _OfflineHandoff(workspace.uid);
      addTearDown(handoff.close);
      await tester.pumpWidget(handoff.app(_Resolver(() async => workspace)));
      await tester.pump(const Duration(milliseconds: 500));
      expect(handoff.transport, isNull);
      await _expectNoDispatch(tester, handoff.inventory.transport);
      handoff.authority.add(true);
      await tester.pumpAndSettle();
      expect(find.text('Offline ${workspace.role.name}'), findsOneWidget);
      await tester.runAsync(() => handoff.transport!.createItem(create()));
      final request = handoff.requests.single;
      expect(request.headers['authorization'], startsWith('Bearer '));
      expect(jsonDecode(request.body)['expectedCafeId'], 'cafe-a');
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final change in ['logout', 'same-UID replacement', 'gate disposal']) {
    testWidgets('offline gate rejects resolution after $change', (
      tester,
    ) async {
      final handoff = _OfflineHandoff(owner.uid);
      addTearDown(handoff.close);
      final result = Completer<CafeWorkspace>();
      final resolver = _Resolver(() => result.future);
      await tester.pumpWidget(handoff.app(resolver));
      await tester.pump();
      expect(resolver.calls, 1);
      if (change == 'gate disposal') {
        await tester.pumpWidget(const SizedBox());
      } else {
        handoff.auth.replace(change == 'logout' ? null : _User(uid: owner.uid));
      }
      result.complete(owner);
      await tester.pumpAndSettle();
      expect(handoff.transport, isNull);
      await _expectNoDispatch(tester, handoff.inventory.transport);
      expect(handoff.requests, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('invalid membership never hands off offline transport', (
    tester,
  ) async {
    final handoff = _OfflineHandoff(owner.uid);
    addTearDown(handoff.close);
    await tester.pumpWidget(
      handoff.app(
        _Resolver(() async {
          throw const WorkspaceResolutionException(
            WorkspaceFailure.inconsistentMembership,
          );
        }),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Workspace access not verified'), findsOneWidget);
    expect(handoff.transport, isNull);
    await _expectNoDispatch(tester, handoff.inventory.transport);
    expect(handoff.requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final dispose in [false, true]) {
    testWidgets(
      dispose
          ? 'disposed boundary releases offline transport'
          : 'replacement workspace revokes the previous transport',
      (tester) async {
        final handoff = _OfflineHandoff(owner.uid);
        addTearDown(handoff.close);
        final resolver = _Resolver(() async => owner);
        await tester.pumpWidget(handoff.app(resolver));
        await tester.pump(const Duration(milliseconds: 500));
        handoff.authority.add(true);
        await tester.pumpAndSettle();
        final transport = handoff.transport!;
        final revision = handoff.inventory.revision;
        if (dispose) {
          await tester.pumpWidget(const SizedBox());
        } else {
          resolver.result = () async => const CafeWorkspace(
            cafeId: 'different-cafe',
            uid: 'owner-a',
            ownerUid: 'owner-a',
            role: CafeRole.owner,
          );
          handoff.authority.add(true);
          await tester.pumpAndSettle();
          expect(find.text('Offline owner'), findsNothing);
        }
        expect(handoff.inventory.revision, greaterThan(revision));
        final nextSession = WorkspaceSession.fromVerified(owner);
        expect(
          handoff.inventory.bindVerifiedWorkspace(
            nextSession,
            expectedRevision: handoff.inventory.revision,
          ),
          isTrue,
        );
        await _expectNoDispatch(tester, transport);
        expect(handoff.requests, isEmpty);
        await tester.runAsync(
          () => handoff.inventory
              .transportForWorkspace(nextSession)
              .createItem(create()),
        );
        expect(handoff.requests, hasLength(1));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'missing workspace resumes verification then resolves again to setup without loops',
    (tester) async {
      final user = _User(verified: false);
      final auth = _Auth(_FirebaseAuth(user));
      final resolver = _Resolver(
        () async => throw const WorkspaceResolutionException(
          WorkspaceFailure.missingMembership,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspaceGate(resolver: resolver, authService: auth),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(OwnerEmailVerificationPage), findsOneWidget);
      expect(resolver.calls, 0);
      user.verified = true;
      await tester.tap(find.byKey(const ValueKey('owner-check-verification')));
      await tester.pumpAndSettle();
      expect(find.byType(BusinessSetupPage), findsOneWidget);
      expect(find.byType(OwnerEmailVerificationPage), findsNothing);
      expect(resolver.calls, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('successful Login enters the shared gate, not Home directly', (
    tester,
  ) async {
    final pending = Completer<CafeWorkspace>();
    final resolver = _Resolver(() => pending.future);
    final auth = _Auth();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: LoginPage(authService: auth, workspaceResolver: resolver),
      ),
    );
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'owner@example.test');
    await tester.enterText(fields.at(1), 'password');
    await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(auth.calls, 1);
    expect(find.byType(LoginPage), findsNothing);
    expect(find.byType(WorkspaceGate), findsOneWidget);
    expect(find.text('Verifying your workspace…'), findsOneWidget);
    expect(resolver.calls, 1);
  });

  for (final restored in [false, true]) {
    testWidgets(
      'unverified ${restored ? 'restored session' : 'login'} stays at the checkpoint',
      (tester) async {
        final user = _User(verified: false);
        final auth = _Auth(_FirebaseAuth(user));
        final resolver = _Resolver(() async => owner);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: restored
                ? SplashPage(authService: auth, workspaceResolver: resolver)
                : LoginPage(authService: auth, workspaceResolver: resolver),
          ),
        );
        if (restored) {
          await tester.pump(const Duration(seconds: 3));
        } else {
          final fields = find.byType(TextField);
          await tester.enterText(fields.at(0), 'owner@example.test');
          await tester.enterText(fields.at(1), 'password');
          await tester.tap(find.widgetWithText(FilledButton, 'Log In'));
        }
        await tester.pumpAndSettle();
        expect(find.byType(OwnerEmailVerificationPage), findsOneWidget);
        expect(user.reloads, 1);
        expect(resolver.calls, 0);
        await tester.tap(find.text('Sign out'));
        await tester.pumpAndSettle();
        expect(auth.firebaseAuth.currentUser, isNull);
        expect(find.byType(LoginPage), findsOneWidget);
        expect(resolver.calls, 0);
      },
    );
  }

  testWidgets('stale token and offline reload cannot resolve a workspace', (
    tester,
  ) async {
    final user = _User()..tokenVerified = false;
    final resolver = _Resolver(() async => owner);
    await tester.pumpWidget(_app(resolver, auth: _Auth(_FirebaseAuth(user))));
    await tester.pumpAndSettle();
    expect(find.byType(OwnerEmailVerificationPage), findsOneWidget);
    expect(resolver.calls, 0);
    user.reloadError = FirebaseAuthException(code: 'network-request-failed');
    await tester.tap(find.byKey(const ValueKey('owner-check-verification')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Verification could not be checked'),
      findsOneWidget,
    );
    expect(resolver.calls, 0);
  });

  testWidgets(
    'same-UID replacement during membership lookup cannot open Home',
    (tester) async {
      final pending = Completer<CafeWorkspace>();
      final auth = _Auth();
      final resolver = _Resolver(() => pending.future);
      await tester.pumpWidget(_app(resolver, auth: auth));
      await tester.pump();
      expect(resolver.calls, 1);
      auth.firebaseAuth.replace(null);
      auth.firebaseAuth.replace(_User());
      pending.complete(owner);
      await tester.pumpAndSettle();
      expect(find.text('Session could not be verified'), findsOneWidget);
      expect(find.textContaining('Verified Home'), findsNothing);
    },
  );

  for (final workspace in [owner, staff]) {
    testWidgets('verified ${workspace.role.name} reaches Home', (tester) async {
      final resolver = _Resolver(() async => workspace);
      await tester.pumpWidget(
        _app(resolver, auth: _Auth(_FirebaseAuth(_User(uid: workspace.uid)))),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Verified Home cafe-a ${workspace.role.name}'),
        findsOneWidget,
      );
      expect(find.text('Setup Preview'), findsNothing);
      expect(resolver.calls, 1);
    });
  }

  testWidgets('only missing membership reaches Business Setup preview', (
    tester,
  ) async {
    final resolver = _Resolver(
      () async => throw const WorkspaceResolutionException(
        WorkspaceFailure.missingMembership,
      ),
    );
    await tester.pumpWidget(_app(resolver));
    await tester.pumpAndSettle();

    expect(find.text('Setup Preview'), findsOneWidget);
    expect(find.textContaining('Verified Home'), findsNothing);
  });

  testWidgets('inconsistent membership fails closed', (tester) async {
    final resolver = _Resolver(
      () async => throw const WorkspaceResolutionException(
        WorkspaceFailure.inconsistentMembership,
      ),
    );
    await tester.pumpWidget(_app(resolver));
    await tester.pumpAndSettle();

    expect(find.text('Workspace access not verified'), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-retry')), findsOneWidget);
    expect(find.textContaining('Verified Home'), findsNothing);
    expect(find.text('Setup Preview'), findsNothing);
  });

  for (final failure in [
    WorkspaceFailure.unavailable,
    WorkspaceFailure.sessionChanged,
    WorkspaceFailure.unauthenticated,
  ]) {
    testWidgets('${failure.name} fails closed instead of showing Setup', (
      tester,
    ) async {
      final resolver = _Resolver(
        () async => throw WorkspaceResolutionException(failure),
      );
      await tester.pumpWidget(_app(resolver));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('workspace-retry')), findsOneWidget);
      expect(find.textContaining('Verified Home'), findsNothing);
      expect(find.text('Setup Preview'), findsNothing);
    });
  }

  testWidgets('unknown resolver errors fail closed and retry can recover', (
    tester,
  ) async {
    final first = Completer<CafeWorkspace>();
    final resolver = _Resolver(() => first.future);
    await tester.pumpWidget(_app(resolver));
    expect(find.text('Verifying your workspace…'), findsOneWidget);

    first.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Workspace unavailable'), findsOneWidget);

    resolver.result = () async => owner;
    await tester.tap(find.byKey(const ValueKey('workspace-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Verified Home cafe-a owner'), findsOneWidget);
    expect(resolver.calls, 2);
  });
}
