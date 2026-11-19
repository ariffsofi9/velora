import 'dart:async';
import 'package:flutter/material.dart';
import 'package:velora/screens/auth/workspace_gate.dart';
import 'package:velora/screens/inventory/add_item/add_item_page.dart';
import 'package:velora/screens/inventory/add_item/widgets_add/add_item_date_box.dart';
import 'package:velora/screens/inventory/add_item/widgets_add/add_item_save_button.dart';
import 'package:velora/services/android_pilot_policy.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/workspace_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/workspace_inventory_create_service.dart';

class _Callable implements WorkspaceInventoryCreateCallable {
  Map<String, Object>? payload;
  Completer<Map<String, dynamic>>? pending;
  Map<String, dynamic> result = {'itemId': 'item-a', 'created': true};

  @override
  Future<Map<String, dynamic>> call(Map<String, Object> data) async {
    payload = data;
    return pending == null ? result : await pending!.future;
  }
}

final _normalPolicy = AndroidPilotPolicy.parse(
  const {},
  isWeb: false,
  platform: TargetPlatform.android,
);

AndroidPilotPolicy _pilotPolicy(bool invalid) => AndroidPilotPolicy.parse(
  invalid
      ? {'VELORA_ANDROID_READ_ONLY_PILOT': 'false'}
      : {
          'VELORA_ANDROID_READ_ONLY_PILOT': 'true',
          'VELORA_FIREBASE_PROJECT': AndroidPilotPolicy.approvedProject,
          'VELORA_ANDROID_PILOT_BINDINGS': '[["owner","cafe"]]',
        },
  isWeb: false,
  platform: TargetPlatform.android,
);

Widget _scope(AndroidPilotPolicy policy, Widget page) => AndroidPilotAuthScope(
  dependencies: AndroidPilotAuthDependencies(policy: policy),
  child: MaterialApp(home: page),
);
WorkspaceSession _createSession() => WorkspaceSession.fromVerified(
  const CafeWorkspace(
    cafeId: 'cafe',
    uid: 'owner',
    ownerUid: 'owner',
    role: CafeRole.owner,
  ),
);
Future<void> _fillAdd(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).at(0), 'Milk');
  await tester.enterText(find.byType(TextField).at(1), '2');
  tester.widget<AddItemDateBox>(find.byType(AddItemDateBox)).onTap();
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {
  for (final invalid in [false, true]) {
    testWidgets('direct Add invalid=$invalid rejects injected normal creator', (
      tester,
    ) async {
      final callable = _Callable(), session = _createSession();
      var keys = 0;
      final creator = FirebaseWorkspaceInventoryCreator(
        pilotPolicy: _normalPolicy,
        session: session,
        callable: callable,
      );
      await tester.pumpWidget(
        _scope(
          _pilotPolicy(invalid),
          AddItemPage(
            workspaceSession: session,
            creator: creator,
            idempotencyKeyFactory: () {
              keys++;
              return 'create-request-01';
            },
          ),
        ),
      );
      expect(find.byType(PilotAccessBlockedPage), findsOneWidget);
      expect(callable.payload, isNull);
      expect(keys, 0);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets(
      'captured valid Add callback invalid=$invalid performs zero allocation',
      (tester) async {
        final callable = _Callable(), session = _createSession();
        var keys = 0;
        var policy = _normalPolicy;
        late StateSetter update;
        final creator = FirebaseWorkspaceInventoryCreator(
          pilotPolicy: _normalPolicy,
          session: session,
          callable: callable,
        );
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return _scope(
                policy,
                AddItemPage(
                  workspaceSession: session,
                  creator: creator,
                  idempotencyKeyFactory: () {
                    keys++;
                    return 'create-request-01';
                  },
                ),
              );
            },
          ),
        );
        await _fillAdd(tester);
        final submit = tester
            .widget<AddItemSaveButton>(find.byType(AddItemSaveButton))
            .onTap;
        update(() => policy = _pilotPolicy(invalid));
        await tester.pump();
        submit();
        submit();
        await tester.pump();
        expect(callable.payload, isNull);
        expect(keys, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final change in ['policy', 'session', 'dispose']) {
    testWidgets('pending Add cannot publish success after $change', (
      tester,
    ) async {
      final callable = _Callable()..pending = Completer<Map<String, dynamic>>(),
          session = _createSession();
      var policy = _normalPolicy;
      late StateSetter update;
      final creator = FirebaseWorkspaceInventoryCreator(
        pilotPolicy: _normalPolicy,
        session: session,
        callable: callable,
      );
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return _scope(
              policy,
              AddItemPage(workspaceSession: session, creator: creator),
            );
          },
        ),
      );
      await _fillAdd(tester);
      tester.widget<AddItemSaveButton>(find.byType(AddItemSaveButton)).onTap();
      await tester.pump();
      expect(callable.payload, isNotNull);
      if (change == 'dispose') {
        await tester.pumpWidget(const SizedBox());
      } else if (change == 'session') {
        session.invalidate();
      } else {
        update(() => policy = _pilotPolicy(false));
        await tester.pump();
      }
      callable.pending!.complete({'itemId': 'item-a', 'created': true});
      await tester.pump();
      expect(find.text('Milk added successfully'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final invalid in [false, true]) {
    test(
      'independent create invalid=$invalid rejects before preparation/SDK lookup',
      () async {
        final policy = _pilotPolicy(invalid), callable = _Callable();
        final service = FirebaseWorkspaceInventoryCreator(
          pilotPolicy: policy,
          callable: callable,
        );
        expect(service.pilotPolicy, same(policy));
        await expectLater(
          service.createItem(
            WorkspaceInventoryCreateRequest(
              idempotencyKey: 'create-request-01',
              name: 'Milk',
              category: 'Dairy',
              quantity: 1,
              unit: 'L',
              expiryDate: DateTime(2030),
            ),
          ),
          throwsA(isA<InventoryCreatePilotPolicyException>()),
        );
        expect(callable.payload, isNull);
        await expectLater(
          FirebaseWorkspaceInventoryCreateCallable(
            pilotPolicy: policy,
          ).call({}),
          throwsA(isA<InventoryCreatePilotPolicyException>()),
        );
      },
    );
  }

  test('maps the exact callable payload with canonical UTC expiry', () async {
    final callable = _Callable();
    final creator = FirebaseWorkspaceInventoryCreator(
      pilotPolicy: _normalPolicy,
      session: WorkspaceSession.fromVerified(
        const CafeWorkspace(
          cafeId: 'cafe-a',
          uid: 'owner',
          ownerUid: 'owner',
          role: CafeRole.owner,
        ),
      ),
      callable: callable,
    );
    final request = WorkspaceInventoryCreateRequest(
      idempotencyKey: 'request-00000001',
      name: 'Fresh Milk',
      category: 'Dairy',
      quantity: 4,
      unit: 'L',
      expiryDate: DateTime(2030, 1, 2, 18, 30),
    );

    final result = await creator.createItem(request);

    expect(result.itemId, 'item-a');
    expect(result.created, isTrue);
    expect(callable.payload, {
      'expectedCafeId': 'cafe-a',
      'expectedMembershipGeneration': 0,
      'idempotencyKey': 'request-00000001',
      'name': 'Fresh Milk',
      'category': 'Dairy',
      'quantity': 4,
      'unit': 'L',
      'expiryDate': '2030-01-02T00:00:00.000Z',
      'imageUrl': '',
    });
    expect(callable.payload, isNot(contains('cafeId')));
    expect(callable.payload, isNot(contains('uid')));
    expect(callable.payload, isNot(contains('role')));
  });

  test('rejects malformed callable results', () async {
    final callable = _Callable()..result = {'created': true};
    final creator = FirebaseWorkspaceInventoryCreator(
      pilotPolicy: _normalPolicy,
      session: WorkspaceSession.fromVerified(
        const CafeWorkspace(
          cafeId: 'cafe-a',
          uid: 'owner',
          ownerUid: 'owner',
          role: CafeRole.owner,
        ),
      ),
      callable: callable,
    );

    await expectLater(
      creator.createItem(
        WorkspaceInventoryCreateRequest(
          idempotencyKey: 'request-00000001',
          name: 'Milk',
          category: 'Dairy',
          quantity: 1,
          unit: 'L',
          expiryDate: DateTime(2030),
        ),
      ),
      throwsA(
        isA<WorkspaceInventoryCreateException>().having(
          (error) => error.failure,
          'failure',
          WorkspaceInventoryCreateFailure.internal,
        ),
      ),
    );
  });
}
