// Offline Firebase interface doubles only.
// ignore_for_file: subtype_of_sealed_class
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/screens/team/staff_invitation_page.dart';
import 'package:velora/screens/team/team_management_page.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/staff_invitation_service.dart';
import 'package:velora/services/firebase_emulator_config.dart';
import 'package:firebase_core/firebase_core.dart';
import 'helpers/invitation_firebase.dart';
import 'helpers/staff_invitation_callable_fakes.dart';

class _Invites implements StaffInvitations {
  final capturedCreates = <CafeWorkspace>[];
  final capturedRevokes = <CafeWorkspace>[];
  int creates = 0;
  int revokes = 0;
  int redeems = 0;
  String? email;
  Object? redeemError;
  Object? revokeError;
  Object? revokeResponse = <String, dynamic>{'revoked': true};
  Object? redeemResponse = <String, dynamic>{'joined': true};
  Future<void>? pending;
  @override
  Future<StaffInvitation> create(
    String value, {
    required CafeWorkspace workspace,
  }) async {
    capturedCreates.add(workspace);
    creates++;
    email = value;
    return const StaffInvitation(
      'synthetic-id',
      'synthetic-display-code',
      '2030-01-01',
    );
  }

  @override
  Future<void> revoke(String id, {required CafeWorkspace workspace}) async {
    capturedRevokes.add(workspace);
    revokes++;
    await pending;
    if (revokeError != null) throw revokeError!;
    await StaffInvitationAcknowledgement.confirm('revoked', () async {
      return revokeResponse;
    });
  }

  @override
  Future<void> redeem(String code) async {
    redeems++;
    await pending;
    if (redeemError != null) throw redeemError!;
    await StaffInvitationAcknowledgement.confirm('joined', () async {
      return redeemResponse;
    });
  }
}

class _Auth extends Fake implements FirebaseAuth {
  User? user;
  @override
  User? get currentUser => user;
  @override
  Stream<User?> authStateChanges() => const Stream.empty();
}

CafeWorkspace _ownerScope([
  String uid = 'synthetic-staff',
  String cafe = 'a',
  int generation = 0,
]) => CafeWorkspace(
  cafeId: cafe,
  uid: uid,
  ownerUid: uid,
  role: CafeRole.owner,
  membershipGeneration: generation,
);

StaffInvitationPage _invitationPage({
  bool ownerMode = false,
  required StaffInvitations invitations,
  FirebaseAuth? auth,
  CafeWorkspace? workspace,
  VoidCallback? onJoined,
}) {
  final identity = auth ?? (_Auth()..user = _User());
  return StaffInvitationPage(
    ownerMode: ownerMode,
    invitations: invitations,
    auth: identity,
    workspace: ownerMode ? (workspace ?? _ownerScope()) : workspace,
    onJoined: onJoined,
  );
}

class _ChangingAuth extends _Auth {
  final changes = StreamController<User?>.broadcast(sync: true);
  _ChangingAuth(String uid) {
    user = _User(uid);
  }
  @override
  Stream<User?> authStateChanges() => changes.stream;
  void change(String? uid) {
    user = uid == null ? null : _User(uid);
    changes.add(user);
  }
}

class _LifecycleInvites extends _Invites {
  final String label;
  Future<StaffInvitation>? creation;
  Future<void>? revocation;
  Future<void>? redemption;
  String? revokedId;
  _LifecycleInvites(this.label);
  @override
  Future<StaffInvitation> create(
    String value, {
    required CafeWorkspace workspace,
  }) {
    capturedCreates.add(workspace);
    creates++;
    return creation ??
        Future.value(StaffInvitation('id-$label', 'code-$label', '2030-01-01'));
  }

  @override
  Future<void> revoke(String id, {required CafeWorkspace workspace}) {
    capturedRevokes.add(workspace);
    revokes++;
    revokedId = id;
    return revocation ?? Future.value();
  }

  @override
  Future<void> redeem(String code) {
    redeems++;
    return redemption ?? Future.value();
  }
}

Future<void> _mountLifecycle(
  WidgetTester tester,
  FirebaseAuth auth,
  StaffInvitations service,
  CafeWorkspace? scope, {
  bool ownerMode = true,
  VoidCallback? onJoined,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: StaffInvitationPage(
        auth: auth,
        invitations: service,
        workspace: scope,
        ownerMode: ownerMode,
        onJoined: onJoined,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _largeViewport(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(900, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<void> _createDisplayed(WidgetTester tester, String label) async {
  await tester.enterText(find.byType(TextField).first, 'private@example.test');
  await tester.tap(find.text('Create invitation'));
  await tester.pumpAndSettle();
  expect(find.text('code-$label'), findsOneWidget);
  expect(
    tester.widget<TextField>(find.byType(TextField).last).controller!.text,
    'id-$label',
  );
}

Map<String, dynamic> _creationResponse([String letter = 'a']) {
  final id = List.filled(32, letter).join();
  return {
    'invitationId': id,
    'code': '$id.${List.filled(64, 'c').join()}',
    'expiresAt': '2030-01-01T00:00:00.000Z',
  };
}

class _CreationInvites extends _Invites {
  final guard = StaffInvitationCreation();
  Object? response = _creationResponse();
  Object? creationError;
  Future<void>? creationPending;

  @override
  Future<StaffInvitation> create(
    String value, {
    required CafeWorkspace workspace,
  }) => guard.issue((onStage) async {
    email = value;
    capturedCreates.add(workspace);
    creates++;
    onStage(StaffRedeemStage.callableInvocation);
    await creationPending;
    if (creationError != null) throw creationError!;
    onStage(StaffRedeemStage.callableResponse);
    return response;
  }, clock: () => DateTime.utc(2029));
}

class _User extends Fake implements User {
  final String identity;
  _User([this.identity = 'synthetic-staff']);
  bool verified = true;
  Object? reloadError, tokenError;
  VoidCallback? afterReload;
  bool refreshed = false;
  @override
  String get uid => identity;
  @override
  bool get emailVerified => verified;
  @override
  Future<void> reload() async {
    if (reloadError != null) throw reloadError!;
    afterReload?.call();
  }

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    refreshed = forceRefresh;
    if (tokenError != null) throw tokenError!;
    return 'synthetic-token';
  }
}

void main() {
  test('typed HTTPS rejection preserves definite failure classification', () {
    final failure = StaffInvitationFailure.fromError(
      StaffRedeemStage.callableInvocation,
      const StaffInvitationTransportException(
        'permission-denied',
        outcomeUnknown: false,
      ),
    );
    expect(failure.code, 'permission-denied');
    expect(failure.outcomeUnknown, false);
  });

  test('typed uncertain HTTPS error cannot become definite rejection', () {
    final failure = StaffInvitationFailure.fromError(
      StaffRedeemStage.callableInvocation,
      const StaffInvitationTransportException(
        'permission-denied',
        outcomeUnknown: true,
      ),
    );
    expect(failure.outcomeUnknown, true);
    expect(failure.toString(), isNot(contains('Bearer')));
  });

  test('shared Owner capture preserves zero and nonzero expectations', () {
    for (final generation in [0, 7]) {
      expect(
        captureInvitationOwnerContext(
          _ownerScope('owner', 'cafe', generation),
          'owner',
        ),
        {'expectedCafeId': 'cafe', 'expectedMembershipGeneration': generation},
      );
    }
    expect(
      () => captureInvitationOwnerContext(_ownerScope('owner'), 'other'),
      throwsA(isA<StaffInvitationFailure>()),
    );
  });
  setUp(installInvitationFirebase);
  group('actual invitation callable adapter', () {
    final profile = FirebaseEmulatorConfig.invitationProfileAllows(
      FirebaseEmulatorConfig.ai1Mock ? 'demo-velora-ai1' : 'demo-velora-staff',
    );
    StaffCallableFunctions transport() =>
        StaffCallableFunctions(Firebase.app());
    _Auth identity() => _Auth()..user = _User();
    Future<Object?> invoke(FirebaseStaffInvitations service, String action) =>
        switch (action) {
          'create' => service.create(
            'private@example.test',
            workspace: _ownerScope(),
          ),
          'revoke' => service.revoke(
            'synthetic-invitation-id',
            workspace: _ownerScope(),
          ),
          _ => service.redeem('  PRIVATE-SYNTHETIC-CODE  '),
        };
    Object response(String action) => switch (action) {
      'create' => {
        ..._creationResponse(),
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(days: 1))
            .toIso8601String()
            .replaceFirst(RegExp(r'\.\d+Z$'), '.000Z'),
      },
      'revoke' => <String, dynamic>{'revoked': true},
      _ => <String, dynamic>{'joined': true},
    };
    for (final action in ['create', 'revoke', 'redeem']) {
      test('$action default profile fails before transport', () async {
        final functions = transport();
        final service = FirebaseStaffInvitations(
          auth: identity(),
          functions: functions,
        );
        await expectLater(
          invoke(service, action),
          throwsA(
            isA<StaffInvitationFailure>().having(
              (e) => e.outcomeUnknown,
              'unknown',
              false,
            ),
          ),
        );
        expect(functions.names, isEmpty);
        expect(functions.routes, isEmpty);
        expect(functions.payloads, isEmpty);
      }, skip: profile);
      test(
        '$action uses only injected instance and explicit loopback route',
        () async {
          final functions = transport()
            ..respond = (() async => response(action));
          final unused = transport();
          final auth = identity();
          final service = FirebaseStaffInvitations(
            auth: auth,
            functions: functions,
          );
          await invoke(service, action);
          expect(identical(service.functions, functions), true);
          expect(unused.payloads, isEmpty);
          expect(functions.names, ['${action}StaffInvitation']);
          expect(functions.payloads, hasLength(1));
          final payload = functions.payloads.single;
          if (action == 'create') {
            expect(payload.keys.toSet(), {
              'email',
              'requestId',
              'expectedCafeId',
              'expectedMembershipGeneration',
            });
            expect(payload['expectedCafeId'], 'a');
            expect(payload['expectedMembershipGeneration'], 0);
            expect(payload['email'] == 'private@example.test', true);
            expect(
              RegExp(
                r'^[A-Za-z0-9_-]{16,64}$',
              ).hasMatch(payload['requestId'] as String),
              true,
            );
          } else {
            expect(
              payload.keys.toSet(),
              action == 'revoke'
                  ? {
                      'invitationId',
                      'expectedCafeId',
                      'expectedMembershipGeneration',
                    }
                  : {'code'},
            );
            expect(
              payload[action == 'revoke' ? 'invitationId' : 'code'],
              action == 'revoke'
                  ? 'synthetic-invitation-id'
                  : 'PRIVATE-SYNTHETIC-CODE',
            );
            if (action == 'revoke') {
              expect(payload['expectedCafeId'], 'a');
              expect(payload['expectedMembershipGeneration'], 0);
            }
          }
          expect(functions.routes.single, (
            host: '127.0.0.1',
            port: FirebaseEmulatorConfig.invitationFunctionsPort,
            automaticHostMapping: false,
          ));
          if (action == 'redeem') expect((auth.user as _User).refreshed, true);
        },
        skip: !profile,
      );
      for (final outcome in [
        'malformed',
        'permission',
        'stale',
        'timeout',
        'transport',
      ]) {
        test(
          '$action adapter $outcome is sanitized and never retried',
          () async {
            final functions = transport()
              ..respond = (() async {
                switch (outcome) {
                  case 'stale':
                    throw FirebaseFunctionsException(
                      code: 'failed-precondition',
                      message: 'Workspace changed',
                    );
                  case 'permission':
                    throw FirebaseFunctionsException(
                      code: 'permission-denied',
                      message: 'PRIVATE',
                      details: 'PRIVATE',
                    );
                  case 'timeout':
                    throw TimeoutException('PRIVATE');
                  case 'transport':
                    throw StateError('PRIVATE');
                  default:
                    return <String, dynamic>{
                      'joined': 'true',
                      'revoked': 'true',
                      'private': 'PRIVATE',
                    };
                }
              });
            final service = FirebaseStaffInvitations(
              auth: identity(),
              functions: functions,
            );
            await expectLater(
              invoke(service, action),
              throwsA(
                isA<StaffInvitationFailure>()
                    .having(
                      (e) => e.outcomeUnknown,
                      'unknown',
                      !['permission', 'stale'].contains(outcome),
                    )
                    .having(
                      (e) => e.code,
                      'code',
                      outcome == 'stale'
                          ? 'failed-precondition'
                          : outcome == 'permission'
                          ? 'permission-denied'
                          : outcome == 'timeout'
                          ? 'deadline-exceeded'
                          : outcome == 'malformed'
                          ? (action == 'create'
                                ? 'invalid-creation-acknowledgement'
                                : 'invalid-acknowledgement')
                          : 'unknown',
                    )
                    .having(
                      (e) => e.toString().contains('PRIVATE'),
                      'private diagnostics',
                      false,
                    ),
              ),
            );
            expect(functions.payloads, hasLength(1));
            expect(functions.names, hasLength(1));
            if (action == 'create' &&
                !['permission', 'stale'].contains(outcome)) {
              await expectLater(
                service.create(
                  'another@example.test',
                  workspace: _ownerScope(),
                ),
                throwsA(isA<StaffInvitationFailure>()),
              );
              expect(functions.payloads, hasLength(1));
            }
          },
          skip: !profile,
        );
      }
      test('$action adapter pending completion remains controlled', () async {
        final pending = Completer<Object?>();
        final functions = transport()..respond = (() => pending.future);
        var completed = false;
        final operation = invoke(
          FirebaseStaffInvitations(auth: identity(), functions: functions),
          action,
        ).then((_) => completed = true);
        await Future<void>.delayed(Duration.zero);
        expect(completed, false);
        expect(functions.payloads, hasLength(1));
        pending.complete(response(action));
        await operation;
        expect(completed, true);
        expect(functions.payloads, hasLength(1));
      }, skip: !profile);
    }
    test(
      'wrong Functions project is rejected without routing or invocation',
      () async {
        final core = installInvitationFirebase();
        core.projectId = 'synthetic-wrong-project';
        final wrong = transport();
        installInvitationFirebase();
        await expectLater(
          FirebaseStaffInvitations(
            auth: identity(),
            functions: wrong,
          ).create('private@example.test', workspace: _ownerScope()),
          throwsA(
            isA<StaffInvitationFailure>().having(
              (e) => e.outcomeUnknown,
              'unknown',
              false,
            ),
          ),
        );
        expect(wrong.routes, isEmpty);
        expect(wrong.names, isEmpty);
        expect(wrong.payloads, isEmpty);
      },
      skip: !profile,
    );
    test(
      'wrong default app rejects even an approved injected transport',
      () async {
        final functions = transport();
        installInvitationFirebase().projectId = 'synthetic-wrong-project';
        await expectLater(
          FirebaseStaffInvitations(
            auth: identity(),
            functions: functions,
          ).revoke('synthetic-id', workspace: _ownerScope()),
          throwsA(
            isA<StaffInvitationFailure>().having(
              (e) => e.outcomeUnknown,
              'unknown',
              false,
            ),
          ),
        );
        expect(functions.routes, isEmpty);
        expect(functions.payloads, isEmpty);
      },
      skip: !profile,
    );
  });
  test(
    'Team Management caller remains compiled with explicit Auth context',
    () {
      final auth = _Auth()..user = _User();
      expect(TeamManagementPage(auth: auth).auth, same(auth));
    },
  );
  for (final action in ['create', 'revoke']) {
    testWidgets(
      'page retains original captured Owner context during pending $action',
      (tester) async {
        await _largeViewport(tester);
        final auth = _ChangingAuth('owner-a');
        final service = _LifecycleInvites('pending');
        final first = _ownerScope('owner-a', 'a', 0);
        final next = _ownerScope('owner-a', 'b', 7);
        final creation = Completer<StaffInvitation>();
        final revocation = Completer<void>();
        service.creation = creation.future;
        service.revocation = revocation.future;
        await _mountLifecycle(tester, auth, service, first);
        if (action == 'create') {
          await tester.enterText(
            find.byType(TextField).first,
            'staff@example.test',
          );
          await tester.tap(find.text('Create invitation'));
        } else {
          await tester.enterText(find.byType(TextField).last, 'original-id');
          await tester.tap(find.text('Revoke invitation'));
        }
        await tester.pump();
        final captures = action == 'create'
            ? service.capturedCreates
            : service.capturedRevokes;
        expect(captures.single, same(first));
        await _mountLifecycle(tester, auth, service, next);
        creation.complete(
          const StaffInvitation('old-id', 'old-private-code', '2030'),
        );
        revocation.complete();
        await tester.pumpAndSettle();
        expect(captures, [first]);
        expect(find.text('old-private-code'), findsNothing);
        expect(find.text('Invitation revoked.'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await auth.changes.close();
      },
    );
  }
  for (final transition in [
    'equivalent',
    'auth',
    'uid',
    'service',
    'workspace',
    'generation',
    'mode',
  ]) {
    testWidgets(
      'State reuse binds $transition without cross-context presentation',
      (tester) async {
        await _largeViewport(tester);
        final auth = _ChangingAuth('owner-a');
        final first = _LifecycleInvites('first');
        await _mountLifecycle(tester, auth, first, _ownerScope('owner-a'));
        final state = tester.state(find.byType(StaffInvitationPage));
        await _createDisplayed(tester, 'first');
        final nextAuth = transition == 'auth' ? _ChangingAuth('owner-a') : auth;
        final nextService = transition == 'service'
            ? _LifecycleInvites('second')
            : first;
        if (transition == 'uid') auth.change('owner-b');
        await _mountLifecycle(
          tester,
          nextAuth,
          nextService,
          _ownerScope(
            transition == 'uid' ? 'owner-b' : 'owner-a',
            transition == 'workspace' ? 'b' : 'a',
            transition == 'generation' ? 1 : 0,
          ),
          ownerMode: transition != 'mode',
        );
        expect(tester.state(find.byType(StaffInvitationPage)), same(state));
        if (transition == 'equivalent') {
          expect(find.text('code-first'), findsOneWidget);
          expect(
            tester
                .widget<TextField>(find.byType(TextField).last)
                .controller!
                .text,
            'id-first',
          );
        } else {
          expect(find.text('code-first'), findsNothing);
          for (final field in tester.widgetList<TextField>(
            find.byType(TextField),
          )) {
            expect(field.controller!.text, isEmpty);
          }
          expect(find.byType(CircularProgressIndicator), findsNothing);
        }
        if (transition == 'service') {
          await _createDisplayed(tester, 'second');
          expect(first.creates, 1);
          expect(nextService.creates, 1);
        }
        await tester.pumpWidget(const SizedBox());
        await auth.changes.close();
        if (!identical(nextAuth, auth)) await nextAuth.changes.close();
      },
    );
  }
  for (final operation in ['create', 'revoke']) {
    for (final completion in ['success', 'unknown', 'rejected']) {
      testWidgets(
        'stale $operation $completion cannot affect a newer pending operation',
        (tester) async {
          await _largeViewport(tester);
          final auth = _ChangingAuth('owner-a');
          final oldService = _LifecycleInvites('old');
          final create = Completer<StaffInvitation>();
          final revoke = Completer<void>();
          await _mountLifecycle(
            tester,
            auth,
            oldService,
            _ownerScope('owner-a'),
          );
          if (operation == 'revoke') {
            await _createDisplayed(tester, 'old');
            oldService.revocation = revoke.future;
            await tester.tap(find.text('Revoke invitation'));
          } else {
            oldService.creation = create.future;
            await tester.tap(find.text('Create invitation'));
          }
          await tester.pump();
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          auth.change('owner-b');
          final nextService = _LifecycleInvites('new');
          await _mountLifecycle(
            tester,
            auth,
            nextService,
            _ownerScope('owner-b'),
          );
          await _createDisplayed(tester, 'new');
          final nextPending = Completer<StaffInvitation>();
          nextService.creation = nextPending.future;
          await tester.tap(find.text('Create invitation'));
          await tester.pump();
          if (completion == 'success') {
            if (operation == 'create')
              create.complete(
                const StaffInvitation('id-stale', 'PRIVATE-OLD-CODE', '2030'),
              );
            else
              revoke.complete();
          } else {
            final error = completion == 'unknown'
                ? StaffInvitationFailure.fromError(
                    StaffRedeemStage.callableInvocation,
                    TimeoutException('PRIVATE-ERROR'),
                  )
                : StaffInvitationFailure.fromError(
                    StaffRedeemStage.callableInvocation,
                    FirebaseFunctionsException(
                      code: 'permission-denied',
                      message: 'PRIVATE-ERROR',
                    ),
                  );
            if (operation == 'create')
              create.completeError(error);
            else
              revoke.completeError(error);
          }
          await tester.pump();
          await tester.pump();
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          expect(
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull,
          );
          expect(find.text('code-new'), findsOneWidget);
          expect(
            tester
                .widget<TextField>(find.byType(TextField).last)
                .controller!
                .text,
            'id-new',
          );
          expect(find.text('Invitation revoked.'), findsNothing);
          expect(find.textContaining('PRIVATE'), findsNothing);
          expect(find.textContaining('Outcome unknown.'), findsNothing);
          final oldGuard = StaffInvitationCreation.forSession(auth, 'owner-a');
          expect(
            oldGuard.blocked,
            operation == 'create' && completion != 'rejected',
          );
          expect(
            StaffInvitationCreation.forSession(auth, 'owner-b').blocked,
            false,
          );
          nextPending.complete(
            const StaffInvitation('id-latest', 'code-latest', '2030'),
          );
          await tester.pumpAndSettle();
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(find.text('code-latest'), findsOneWidget);
          expect(nextService.creates, 2);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await auth.changes.close();
        },
      );
    }
  }
  for (final operation in ['create', 'revoke', 'redeem']) {
    testWidgets(
      'disposal rejects late $operation completion without navigation',
      (tester) async {
        await _largeViewport(tester);
        final auth = _ChangingAuth('owner-a');
        final service = _LifecycleInvites('old');
        final create = Completer<StaffInvitation>();
        final action = Completer<void>();
        var navigated = 0;
        await _mountLifecycle(
          tester,
          auth,
          service,
          operation == 'redeem' ? null : _ownerScope('owner-a'),
          ownerMode: operation != 'redeem',
          onJoined: () => navigated++,
        );
        if (operation == 'revoke') {
          await _createDisplayed(tester, 'old');
          service.revocation = action.future;
          await tester.tap(find.text('Revoke invitation'));
        } else if (operation == 'redeem') {
          service.redemption = action.future;
          await tester.tap(find.text('Redeem invitation'));
        } else {
          service.creation = create.future;
          await tester.tap(find.text('Create invitation'));
        }
        await tester.pump();
        await tester.pumpWidget(const MaterialApp(home: Text('New screen')));
        if (operation == 'create')
          create.complete(
            const StaffInvitation('id-old', 'PRIVATE-CODE', '2030'),
          );
        else
          action.complete();
        await tester.pumpAndSettle();
        expect(find.text('New screen'), findsOneWidget);
        expect(find.textContaining('PRIVATE'), findsNothing);
        expect(navigated, 0);
        expect(tester.takeException(), isNull);
        if (operation == 'create')
          expect(
            StaffInvitationCreation.forSession(auth, 'owner-a').blocked,
            true,
          );
        await auth.changes.close();
      },
    );
  }
  for (final matching in [false, true]) {
    testWidgets(
      'revocation clears displayed invitation only when ID matches: $matching',
      (tester) async {
        await _largeViewport(tester);
        final auth = _ChangingAuth('owner-a');
        final service = _LifecycleInvites('first');
        await _mountLifecycle(tester, auth, service, _ownerScope('owner-a'));
        await _createDisplayed(tester, 'first');
        if (!matching)
          await tester.enterText(find.byType(TextField).last, 'unrelated-id');
        await tester.tap(find.text('Revoke invitation'));
        await tester.pumpAndSettle();
        expect(service.revokedId, matching ? 'id-first' : 'unrelated-id');
        expect(
          find.text('code-first'),
          matching ? findsNothing : findsOneWidget,
        );
        expect(find.text('Invitation revoked.'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await auth.changes.close();
      },
    );
  }
  testWidgets(
    'unknown guard survives page/service reconstruction and Owner round trip',
    (tester) async {
      await _largeViewport(tester);
      final auth = _ChangingAuth('owner-a');
      final service = _CreationInvites()
        ..creationError = TimeoutException('PRIVATE');
      await _mountLifecycle(tester, auth, service, _ownerScope('owner-a'));
      await tester.tap(find.text('Create invitation'));
      await tester.pumpAndSettle();
      final guard = StaffInvitationCreation.forSession(auth, 'owner-a');
      expect(guard.blocked, true);
      await tester.pumpWidget(const SizedBox());
      final replacement = _LifecycleInvites('replacement');
      await _mountLifecycle(tester, auth, replacement, _ownerScope('owner-a'));
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(replacement.creates, 0);
      auth.change('owner-b');
      await _mountLifecycle(tester, auth, replacement, _ownerScope('owner-b'));
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      await _createDisplayed(tester, 'replacement');
      auth.change(null);
      await tester.pump();
      expect(find.text('code-replacement'), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      auth.change('owner-a');
      await _mountLifecycle(tester, auth, replacement, _ownerScope('owner-a'));
      expect(guard.blocked, true);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      final otherAuth = _ChangingAuth('owner-a');
      await _mountLifecycle(
        tester,
        otherAuth,
        replacement,
        _ownerScope('owner-a'),
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
      await auth.changes.close();
      await otherAuth.changes.close();
    },
  );
  for (final invalid in ['missing', 'uid', 'role', 'generation']) {
    testWidgets(
      'invalid Owner context $invalid fails closed without invoking service',
      (tester) async {
        final auth = _ChangingAuth('owner-a');
        final service = _LifecycleInvites('never');
        final scope = invalid == 'missing'
            ? null
            : CafeWorkspace(
                cafeId: 'a',
                uid: invalid == 'uid' ? 'other' : 'owner-a',
                ownerUid: 'owner-a',
                role: invalid == 'role' ? CafeRole.staff : CafeRole.owner,
                membershipGeneration: invalid == 'generation' ? -1 : 0,
              );
        await _mountLifecycle(tester, auth, service, scope);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        expect(
          tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
          isNull,
        );
        expect(service.creates, 0);
        expect(service.revokes, 0);
        await tester.pumpWidget(const SizedBox());
        await auth.changes.close();
      },
    );
  }
  final invalidCreationResponses = <String, Object?>{
    'missing id': {..._creationResponse()}..remove('invitationId'),
    'empty id': {..._creationResponse(), 'invitationId': ''},
    'wrong id type': {..._creationResponse(), 'invitationId': 1},
    'uppercase id': {
      ..._creationResponse(),
      'invitationId': List.filled(32, 'A').join(),
    },
    'missing code': {..._creationResponse()}..remove('code'),
    'empty code': {..._creationResponse(), 'code': ''},
    'wrong code type': {..._creationResponse(), 'code': true},
    'invalid code': {..._creationResponse(), 'code': 'PRIVATE-CODE'},
    'newline code': {
      ..._creationResponse(),
      'code': '${_creationResponse()['code']}\n',
    },
    'prefix mismatch': {
      ..._creationResponse(),
      'code': _creationResponse('b')['code'],
    },
    'missing expiry': {..._creationResponse()}..remove('expiresAt'),
    'empty expiry': {..._creationResponse(), 'expiresAt': ''},
    'wrong expiry type': {..._creationResponse(), 'expiresAt': 1},
    'invalid expiry': {..._creationResponse(), 'expiresAt': 'PRIVATE-EXPIRY'},
    'calendar overflow': {
      ..._creationResponse(),
      'expiresAt': '2030-02-30T00:00:00.000Z',
    },
    'hour overflow': {
      ..._creationResponse(),
      'expiresAt': '2030-01-01T24:00:00.000Z',
    },
    'offset expiry': {
      ..._creationResponse(),
      'expiresAt': '2030-01-01T00:00:00.000+00:00',
    },
    'missing milliseconds': {
      ..._creationResponse(),
      'expiresAt': '2030-01-01T00:00:00Z',
    },
    'expired': {
      ..._creationResponse(),
      'expiresAt': '2028-01-01T00:00:00.000Z',
    },
    'nested envelope': {'data': _creationResponse()},
    'list envelope': [_creationResponse()],
    'null envelope': null,
    'string envelope': 'PRIVATE-RESPONSE',
  };
  test(
    'creation accepts canonical response without exposing diagnostics',
    () async {
      final invites = _CreationInvites();
      final result = await invites.create(
        'staff@example.test',
        workspace: _ownerScope(),
      );
      expect(result.id, _creationResponse()['invitationId']);
      expect(result.code, _creationResponse()['code']);
      expect(result.expiresAt, '2030-01-01T00:00:00.000Z');
      expect(invites.guard.blocked, false);
      expect(invites.creates, 1);
    },
  );
  for (final entry in invalidCreationResponses.entries) {
    test(
      'creation rejects ${entry.key} and guards unconfirmed issuance',
      () async {
        final invites = _CreationInvites()..response = entry.value;
        await expectLater(
          invites.create('staff@example.test', workspace: _ownerScope()),
          throwsA(
            isA<StaffInvitationFailure>()
                .having((e) => e.outcomeUnknown, 'unknown', true)
                .having(
                  (e) => e.toString().contains('PRIVATE'),
                  'private data',
                  false,
                ),
          ),
        );
        await expectLater(
          invites.create('different@example.test', workspace: _ownerScope()),
          throwsA(isA<StaffInvitationFailure>()),
        );
        expect(invites.guard.blocked, true);
        expect(invites.creates, 1);
      },
    );
  }
  for (final entry in <String, Object>{
    'timeout': TimeoutException('PRIVATE'),
    'transport': FirebaseFunctionsException(
      code: 'unavailable',
      message: 'PRIVATE',
    ),
    'decoding': StateError('PRIVATE'),
    'duplicate receipt': FirebaseFunctionsException(
      code: 'already-exists',
      message: 'PRIVATE',
    ),
  }.entries) {
    test(
      'creation ${entry.key} may follow commit and blocks another invocation',
      () async {
        final invites = _CreationInvites()..creationError = entry.value;
        await expectLater(
          invites.create('staff@example.test', workspace: _ownerScope()),
          throwsA(
            isA<StaffInvitationFailure>().having(
              (e) => e.outcomeUnknown,
              'unknown',
              true,
            ),
          ),
        );
        await expectLater(
          invites.create('other@example.test', workspace: _ownerScope()),
          throwsA(isA<StaffInvitationFailure>()),
        );
        expect(invites.creates, 1);
      },
    );
  }
  test(
    'permission rejection releases creation guard without claiming success',
    () async {
      final invites = _CreationInvites()
        ..creationError = FirebaseFunctionsException(
          code: 'permission-denied',
          message: 'PRIVATE',
        );
      await expectLater(
        invites.create('staff@example.test', workspace: _ownerScope()),
        throwsA(
          isA<StaffInvitationFailure>().having(
            (e) => e.outcomeUnknown,
            'unknown',
            false,
          ),
        ),
      );
      expect(invites.guard.blocked, false);
      invites.creationError = null;
      expect(
        (await invites.create(
          'staff@example.test',
          workspace: _ownerScope(),
        )).id,
        _creationResponse()['invitationId'],
      );
    },
  );
  test('pre-invocation failure creates no unknown guard', () async {
    final guard = StaffInvitationCreation();
    await expectLater(
      guard.issue((_) async => throw StateError('PRIVATE')),
      throwsA(
        isA<StaffInvitationFailure>().having(
          (e) => e.outcomeUnknown,
          'unknown',
          false,
        ),
      ),
    );
    expect(guard.blocked, false);
    expect(
      (await guard.issue((stage) async {
        stage(StaffRedeemStage.callableInvocation);
        return _creationResponse();
      }, clock: () => DateTime.utc(2029))).id,
      _creationResponse()['invitationId'],
    );
  });
  test(
    'guard survives service lookup but is isolated by Auth instance and Owner',
    () async {
      final session = Object();
      final guard = StaffInvitationCreation.forSession(session, 'owner');
      await expectLater(
        guard.issue((stage) async {
          stage(StaffRedeemStage.callableInvocation);
          throw TimeoutException('PRIVATE');
        }),
        throwsA(isA<StaffInvitationFailure>()),
      );
      expect(
        identical(guard, StaffInvitationCreation.forSession(session, 'owner')),
        true,
      );
      expect(
        StaffInvitationCreation.forSession(session, 'owner').blocked,
        true,
      );
      expect(
        StaffInvitationCreation.forSession(session, 'other').blocked,
        false,
      );
      expect(
        StaffInvitationCreation.forSession(Object(), 'owner').blocked,
        false,
      );
    },
  );
  test('concurrent creation reaches invocation only once', () async {
    final invites = _CreationInvites();
    final pending = Completer<void>();
    invites.creationPending = pending.future;
    final first = invites.create(
      'staff@example.test',
      workspace: _ownerScope(),
    );
    await expectLater(
      invites.create('other@example.test', workspace: _ownerScope()),
      throwsA(isA<StaffInvitationFailure>()),
    );
    expect(invites.creates, 1);
    pending.complete();
    await first;
  });
  for (final outcome in ['success', 'permission', 'timeout', 'malformed']) {
    testWidgets(
      'creation replacement $outcome preserves invitation and paired ID',
      (tester) async {
        final invites = _CreationInvites();
        await tester.pumpWidget(
          MaterialApp(
            home: _invitationPage(ownerMode: true, invitations: invites),
          ),
        );
        await tester.enterText(
          find.byType(TextField).first,
          'staff@example.test',
        );
        await tester.tap(find.text('Create invitation'));
        await tester.pumpAndSettle();
        final old = _creationResponse();
        expect(find.text(old['code']), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).last)
              .controller!
              .text,
          old['invitationId'],
        );
        final pending = Completer<void>();
        invites.creationPending = pending.future;
        invites.response = outcome == 'malformed' ? {} : _creationResponse('b');
        if (outcome == 'permission')
          invites.creationError = FirebaseFunctionsException(
            code: 'permission-denied',
            message: 'PRIVATE',
          );
        if (outcome == 'timeout')
          invites.creationError = TimeoutException('PRIVATE');
        final callback = tester
            .widget<FilledButton>(find.byType(FilledButton))
            .onPressed!;
        callback();
        callback();
        await tester.pump();
        expect(invites.creates, 2);
        expect(find.text(old['code']), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).last)
              .controller!
              .text,
          old['invitationId'],
        );
        pending.complete();
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        final success = outcome == 'success';
        final expected = success ? _creationResponse('b') : old;
        expect(find.text(expected['code']), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).last)
              .controller!
              .text,
          expected['invitationId'],
        );
        expect(find.text('Invitation revoked.'), findsNothing);
        expect(find.textContaining('PRIVATE'), findsNothing);
        final unknown = outcome == 'timeout' || outcome == 'malformed';
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed ==
              null,
          unknown,
        );
        if (unknown) {
          await tester.scrollUntilVisible(
            find.textContaining('Outcome unknown.'),
            150,
            scrollable: find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(find.textContaining('Outcome unknown.'), findsOneWidget);
          await tester.drag(find.byType(ListView), const Offset(0, 1000));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byType(TextField).first,
            'different@example.test',
          );
          callback(); // A stale callback may not bypass the unknown guard.
          await tester.pumpAndSettle();
          expect(invites.creates, 2);
          await tester.scrollUntilVisible(
            find.text('Revoke invitation'),
            150,
            scrollable: find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.ensureVisible(find.text('Revoke invitation'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Revoke invitation'));
          await tester.pumpAndSettle();
          await tester.drag(find.byType(ListView), const Offset(0, 1000));
          await tester.pumpAndSettle();
          expect(find.text(old['code']), findsNothing);
          expect(invites.guard.blocked, true);
          expect(
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull,
          );
          expect(invites.creates, 2);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  test('diagnostics retain only stage and allowlisted Firebase error code', () {
    final error = FirebaseAuthException(
      code: 'network-request-failed',
      message: 'PRIVATE-CODE-AND-TOKEN',
    );
    final failure = StaffInvitationFailure.fromError(
      StaffRedeemStage.authReload,
      error,
    );
    expect(
      failure.toString(),
      'Invitation action failed at authReload (network-request-failed).',
    );
    for (final error in [
      StateError('PRIVATE-CODE-AND-TOKEN'),
      FirebaseAuthException(code: 'PRIVATE-CODE-AND-TOKEN', message: 'PRIVATE'),
    ]) {
      expect(
        StaffInvitationFailure.fromError(
          StaffRedeemStage.tokenRefresh,
          error,
        ).code,
        'unknown',
      );
    }
  });
  for (final field in ['revoked', 'joined']) {
    final responses = <String, Object?>{
      'true': <String, dynamic>{field: true},
      'false': <String, dynamic>{field: false},
      'missing': <String, dynamic>{},
      'string': <String, dynamic>{field: 'true'},
      'integer': <String, dynamic>{field: 1},
      'null field': <String, dynamic>{field: null},
      'list field': <String, dynamic>{
        field: [true],
      },
      'nested field': <String, dynamic>{
        field: {'value': true},
      },
      'nested envelope': <String, dynamic>{
        'data': {field: true},
      },
      'null envelope': null,
      'list envelope': [true],
      'string envelope': 'PRIVATE-RESPONSE',
    };
    for (final entry in responses.entries) {
      test('$field acknowledgement: ${entry.key}', () async {
        var calls = 0;
        final result = StaffInvitationAcknowledgement.confirm(field, () async {
          calls++;
          return entry.value;
        });
        if (entry.key == 'true') {
          expect((await result)[field], true);
        } else {
          await expectLater(
            result,
            throwsA(
              isA<StaffInvitationFailure>()
                  .having((e) => e.outcomeUnknown, 'unknown completion', true)
                  .having((e) => e.code, 'code', 'invalid-acknowledgement'),
            ),
          );
        }
        expect(calls, 1);
      });
    }
    for (final entry in <String, Object>{
      'permission-denied': FirebaseFunctionsException(
        code: 'permission-denied',
        message: 'PRIVATE-ERROR',
        details: 'PRIVATE',
      ),
      'transport': FirebaseFunctionsException(
        code: 'unavailable',
        message: 'PRIVATE-ERROR',
      ),
      'timeout': TimeoutException('PRIVATE-ERROR'),
      'decoding': StateError('PRIVATE-ERROR'),
      'cancelled': FirebaseFunctionsException(
        code: 'cancelled',
        message: 'PRIVATE-ERROR',
      ),
    }.entries) {
      test(
        '$field invocation ${entry.key} has honest sanitized outcome',
        () async {
          var calls = 0;
          try {
            await StaffInvitationAcknowledgement.confirm(field, () async {
              calls++;
              throw entry.value;
            });
            fail('Must not accept an exception as acknowledgement');
          } on StaffInvitationFailure catch (error) {
            expect(error.outcomeUnknown, entry.key != 'permission-denied');
            expect(error.toString(), isNot(contains('PRIVATE')));
            if (entry.key == 'timeout') expect(error.code, 'deadline-exceeded');
          }
          expect(calls, 1);
        },
      );
    }
  }
  test('pre-dispatch transport error does not imply a possible commit', () {
    final failure = StaffInvitationFailure.fromError(
      StaffRedeemStage.tokenRefresh,
      TimeoutException('PRIVATE'),
    );
    expect(failure.outcomeUnknown, false);
    expect(failure.toString(), isNot(contains('PRIVATE')));
  });
  for (final ownerMode in [false, true]) {
    for (final outcome in [
      'acknowledged',
      'malformed',
      'permission',
      'timeout',
    ]) {
      testWidgets(
        '${ownerMode ? 'revoke' : 'redeem'} $outcome preserves pending and completion safety',
        (tester) async {
          final pending = Completer<void>();
          final invites = _Invites();
          var joined = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: _invitationPage(
                ownerMode: ownerMode,
                invitations: invites,
                onJoined: () => joined++,
              ),
            ),
          );
          if (ownerMode) {
            await tester.enterText(
              find.byType(TextField).first,
              'staff@example.test',
            );
            await tester.tap(find.text('Create invitation'));
            await tester.pumpAndSettle();
          } else {
            await tester.enterText(
              find.byType(TextField).first,
              'PRIVATE-INVITE',
            );
          }
          invites.pending = pending.future;
          if (outcome == 'malformed') {
            invites.revokeResponse = {'revoked': false};
            invites.redeemResponse = {
              'joined': 'true',
              'message': 'PRIVATE-ERROR',
            };
          } else if (outcome == 'permission' || outcome == 'timeout') {
            final error = outcome == 'permission'
                ? FirebaseFunctionsException(
                    code: 'permission-denied',
                    message: 'PRIVATE-ERROR',
                  )
                : TimeoutException('PRIVATE-ERROR');
            // The same boundary used by the production transport classifies the error.
            try {
              await StaffInvitationAcknowledgement.confirm(
                'joined',
                () async => throw error,
              );
            } on StaffInvitationFailure catch (failure) {
              invites.revokeError = failure;
              invites.redeemError = failure;
            }
          }
          final label = ownerMode ? 'Revoke invitation' : 'Redeem invitation';
          await tester.ensureVisible(find.text(label));
          final button = ownerMode
              ? find.byType(OutlinedButton)
              : find.byType(FilledButton);
          final callback = tester.widget<ButtonStyleButton>(button).onPressed!;
          callback();
          callback(); // A stale callback must still respect the synchronous busy guard.
          await tester.pump();
          expect(ownerMode ? invites.revokes : invites.redeems, 1);
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          expect(joined, 0);
          pending.complete();
          await tester.pumpAndSettle();
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(tester.widget<ButtonStyleButton>(button).onPressed, isNotNull);
          expect(ownerMode ? invites.revokes : invites.redeems, 1);
          final success = outcome == 'acknowledged';
          if (ownerMode) {
            expect(
              find.text('Invitation revoked.'),
              success ? findsOneWidget : findsNothing,
            );
            expect(
              find.text('synthetic-display-code'),
              success ? findsNothing : findsOneWidget,
            );
          } else {
            expect(joined, success ? 1 : 0);
            expect(
              tester
                  .widget<TextField>(find.byType(TextField).first)
                  .controller!
                  .text,
              success ? isEmpty : 'PRIVATE-INVITE',
            );
            expect(find.byType(StaffInvitationPage), findsOneWidget);
          }
          if (outcome == 'malformed' || outcome == 'timeout') {
            expect(find.textContaining('Outcome unknown.'), findsOneWidget);
            expect(
              find.textContaining('Do not submit again blindly.'),
              findsOneWidget,
            );
          }
          expect(find.textContaining('PRIVATE-ERROR'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final scenario in [
    'signed-out',
    'reload',
    'unverified',
    'token',
    'session-changed',
    'reloaded-user',
  ]) {
    test(
      'redeem diagnoses $scenario before callable invocation',
      () async {
        final auth = _Auth();
        final user = _User();
        auth.user = user;
        var expectedStage = StaffRedeemStage.authSession;
        var expectedCode = 'unauthenticated';
        switch (scenario) {
          case 'signed-out':
            auth.user = null;
          case 'reload':
            user.reloadError = FirebaseAuthException(
              code: 'network-request-failed',
              message: 'PRIVATE',
            );
            expectedStage = StaffRedeemStage.authReload;
            expectedCode = 'network-request-failed';
          case 'unverified':
            user.verified = false;
            expectedStage = StaffRedeemStage.emailVerification;
            expectedCode = 'email-not-verified';
          case 'token':
            user.tokenError = FirebaseAuthException(
              code: 'user-token-expired',
              message: 'PRIVATE',
            );
            expectedStage = StaffRedeemStage.tokenRefresh;
            expectedCode = 'user-token-expired';
          case 'session-changed':
            user.afterReload = () => auth.user = null;
            expectedCode = 'session-changed';
          case 'reloaded-user':
            user.verified = false;
            user.afterReload = () => auth.user = (_User()
              ..tokenError = FirebaseAuthException(
                code: 'network-request-failed',
              ));
            expectedStage = StaffRedeemStage.tokenRefresh;
            expectedCode = 'network-request-failed';
        }
        await expectLater(
          FirebaseStaffInvitations(auth: auth).redeem('PRIVATE-INVITE'),
          throwsA(
            isA<StaffInvitationFailure>()
                .having((e) => e.stage, 'stage', expectedStage)
                .having((e) => e.code, 'code', expectedCode),
          ),
        );
        if (scenario == 'token') expect(user.refreshed, true);
      },
      skip:
          !((FirebaseEmulatorConfig.staffDemo ||
                  FirebaseEmulatorConfig.ai1Mock) &&
              FirebaseEmulatorConfig.enabled &&
              !FirebaseEmulatorConfig.conflictingProfiles &&
              FirebaseEmulatorConfig.host == '127.0.0.1'),
    );
  }
  testWidgets(
    'redeem failure displays safe stage and code without provider message',
    (tester) async {
      final invites = _Invites()
        ..redeemError = StaffInvitationFailure.fromError(
          StaffRedeemStage.tokenRefresh,
          FirebaseAuthException(
            code: 'user-token-expired',
            message: 'PRIVATE-TOKEN',
          ),
        );
      await tester.pumpWidget(
        MaterialApp(home: _invitationPage(invitations: invites)),
      );
      await tester.enterText(find.byType(TextField), 'PRIVATE-INVITE');
      await tester.tap(find.text('Redeem invitation'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('tokenRefresh (user-token-expired)'),
        findsOneWidget,
      );
      expect(find.textContaining('PRIVATE-TOKEN'), findsNothing);
    },
  );
  testWidgets('owner creates one-time code and revokes without persistence', (
    tester,
  ) async {
    final invites = _Invites();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: _invitationPage(ownerMode: true, invitations: invites),
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'staff@example.test');
    await tester.tap(find.text('Create invitation'));
    await tester.pumpAndSettle();
    expect(invites.creates, 1);
    expect(invites.email, 'staff@example.test');
    expect(find.text('synthetic-display-code'), findsOneWidget);
    await tester.ensureVisible(find.text('Revoke invitation'));
    await tester.tap(find.text('Revoke invitation'));
    await tester.pumpAndSettle();
    expect(invites.revokes, 1);
    expect(find.text('synthetic-display-code'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'staff redeems and re-enters gate callback only after service success',
    (tester) async {
      final invites = _Invites();
      var joined = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: _invitationPage(
            invitations: invites,
            onJoined: () => joined = true,
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'synthetic-code');
      await tester.tap(find.text('Redeem invitation'));
      await tester.pumpAndSettle();
      expect(invites.redeems, 1);
      expect(joined, true);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    },
  );
  test(
    'staff demo requires explicit loopback routing and uses only demo project',
    () {
      const normal = FirebaseOptions(
        apiKey: 'public-placeholder',
        appId: 'public-placeholder',
        messagingSenderId: 'public-placeholder',
        projectId: 'normal-placeholder',
      );
      if (FirebaseEmulatorConfig.staffDemo ||
          FirebaseEmulatorConfig.ai1Mock ||
          FirebaseEmulatorConfig.recipeConnectivity) {
        if (!FirebaseEmulatorConfig.enabled ||
            FirebaseEmulatorConfig.host != '127.0.0.1' ||
            FirebaseEmulatorConfig.conflictingProfiles) {
          expect(
            () => FirebaseEmulatorConfig.optionsFor(normal),
            throwsStateError,
          );
          return;
        }
        final options = FirebaseEmulatorConfig.optionsFor(normal);
        expect(
          options.projectId,
          FirebaseEmulatorConfig.ai1Mock
              ? 'demo-velora-ai1'
              : FirebaseEmulatorConfig.recipeConnectivity
              ? FirebaseEmulatorConfig.recipeProject
              : 'demo-velora-staff',
        );
        expect(FirebaseEmulatorConfig.enabled, true);
        expect(FirebaseEmulatorConfig.host, '127.0.0.1');
      } else {
        if (FirebaseEmulatorConfig.enabled) {
          expect(
            FirebaseEmulatorConfig.optionsFor(normal).projectId,
            'demo-velora-workspaces',
          );
        } else {
          expect(
            () => FirebaseEmulatorConfig.optionsFor(normal),
            throwsStateError,
          );
        }
      }
    },
  );
}
