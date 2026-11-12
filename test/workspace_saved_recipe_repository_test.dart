import 'dart:async';
import 'dart:collection';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/saved_recipe.dart';
import 'package:velora/repositories/workspace_saved_recipe_repository.dart';
import 'package:velora/services/workspace_session.dart';

String rid([String c = 'a']) => 'recipe_${List.filled(64, c).join()}';
String get digest => List.filled(64, 'b').join();
const instant = '2026-11-12T00:00:00.000Z';
Map<String, Object?> content() => {
  'title': 'Rice 🍚',
  'ingredients': [
    {'itemId': 'item', 'quantity': 0.125, 'unit': 'kg'},
  ],
  'steps': ['Cook safely.'],
  'whyRecommended': 'Uses rice.',
};
Map<String, Object?> attribution() => {
  'kind': 'claimed-ai',
  'provider': 'groq',
  'ticketId': null,
};
Map<String, Object?> record() => {
  'schemaVersion': 1,
  'projectId': 'velora-spark-test',
  'cafeId': 'cafe',
  'recipeId': rid(),
  'contentDigest': digest,
  'recipe': content(),
  'source': 'workspace-submitted',
  'provenanceEvidence': 'unverified-attribution',
  'submittedAttribution': attribution(),
  'createdBy': 'owner',
  'updatedBy': 'owner',
  'createdAt': instant,
  'updatedAt': instant,
  'version': 1,
  'isArchived': false,
  'archivedBy': null,
  'archivedAt': null,
};
Map<String, Object?> summary({String c = 'a', bool archived = false}) => {
  'recipeId': rid(c),
  'title': 'Rice',
  'source': 'workspace-submitted',
  'provenanceEvidence': 'unverified-attribution',
  'submittedAttribution': attribution(),
  'version': archived ? 2 : 1,
  'isArchived': archived,
  'createdAt': instant,
  'updatedAt': instant,
};
Map<String, Object?> cursor({String c = 'a'}) => {
  'schemaVersion': 1,
  'projectId': 'velora-spark-test',
  'cafeId': 'cafe',
  'uid': 'owner',
  'membershipGeneration': 7,
  'mode': 'active',
  'limit': 1,
  'afterId': rid(c),
};
Map<String, Object?> ack({String outcome = 'created', bool replayed = true}) =>
    {
      'schemaVersion': 1,
      'cafeId': 'cafe',
      'recipeId': rid(),
      'contentDigest': digest,
      'version': outcome == 'created' ? 1 : 2,
      'isArchived': ['archived', 'existing-archived'].contains(outcome),
      'outcome': outcome,
      'changed': !outcome.startsWith('existing-'),
      'replayed': replayed,
      'requestHash': digest,
      'payloadHash': digest,
    };
SavedRecipeSaveIntent intent({String cafe = 'cafe', int generation = 7}) =>
    SavedRecipeSaveIntent(
      expectedCafeId: cafe,
      expectedMembershipGeneration: generation,
      idempotencyKey: 'saved-recipe-request-0001',
      recipe: SavedRecipeContent.parse(content()),
      attribution: SavedRecipeAttribution.parse(attribution()),
    );
SavedRecipeLifecycleIntent lifecycle({
  String action = 'archive',
  int version = 1,
}) => SavedRecipeLifecycleIntent(
  expectedCafeId: 'cafe',
  expectedMembershipGeneration: 7,
  idempotencyKey: 'saved-lifecycle-request-0001',
  recipeId: rid(),
  expectedVersion: version,
  action: action,
);
SavedRecipeSession session({
  String project = 'velora-spark-test',
  String uid = 'owner',
  String cafe = 'cafe',
  int generation = 7,
  int revision = 0,
  bool verified = true,
  CafeRole role = CafeRole.owner,
}) => SavedRecipeSession(
  projectId: project,
  uid: uid,
  revision: revision,
  emailVerified: verified,
  workspace: WorkspaceSession.fromVerified(
    CafeWorkspace(
      cafeId: cafe,
      uid: uid,
      ownerUid: 'owner',
      role: role,
      membershipGeneration: generation,
    ),
  ),
);
Matcher failure(SavedRecipeFailure f, {bool unknown = false}) =>
    isA<SavedRecipeException>()
        .having((e) => e.failure, 'failure', f)
        .having((e) => e.outcomeUnknown, 'uncertain', unknown);

class FakePorts implements SavedRecipeReadPort, SavedRecipeObservationPort {
  final calls = <Map<String, Object?>>[];
  Future<Object?> Function(String, Map<String, Object?>)? hook;
  @override
  Future<Object?> read(
    SavedRecipeSession session,
    String operation,
    Map<String, Object?> request,
  ) async {
    calls.add({'operation': operation, 'request': request, 'uid': session.uid});
    if (hook != null) return hook!(operation, request);
    if (operation == 'get') {
      return {'schemaVersion': 1, 'cafeId': 'cafe', 'item': record()};
    }
    return {
      'schemaVersion': 1,
      'cafeId': 'cafe',
      'items': [summary()],
      'nextCursor': null,
    };
  }

  @override
  Future<Object?> reconcile(
    SavedRecipeSession session,
    Map<String, Object?> request,
  ) async {
    calls.add({
      'operation': 'reconcile',
      'request': request,
      'uid': session.uid,
    });
    return hook != null
        ? hook!('reconcile', request)
        : {'schemaVersion': 1, 'status': 'unknown'};
  }
}

class ChangingMap extends MapBase<String, Object?> {
  final Map<String, Object?> backing;
  final void Function() change;
  ChangingMap(this.backing, this.change);
  @override
  Iterable<String> get keys {
    change();
    return backing.keys;
  }

  @override
  Object? operator [](Object? key) => backing[key];
  @override
  void operator []=(String key, Object? value) => backing[key] = value;
  @override
  void clear() => backing.clear();
  @override
  Object? remove(Object? key) => backing.remove(key);
}

class Fixture {
  final ports = FakePorts();
  final changes = StreamController<SavedRecipeSession?>.broadcast(sync: true);
  SavedRecipeSession? current = session();
  late final WorkspaceSavedRecipeRepository repository;
  Fixture({Duration timeout = const Duration(seconds: 1)}) {
    repository = WorkspaceSavedRecipeRepository(
      readPort: ports,
      observationPort: ports,
      currentSession: () => current,
      sessionChanges: changes.stream,
      timeout: timeout,
    );
    addTearDown(() async {
      await repository.dispose();
      await changes.close();
    });
  }
}

void main() {
  test(
    'session change during response parsing suppresses the result',
    () async {
      final f = Fixture();
      f.ports.hook = (_, _) async => ChangingMap({
        'schemaVersion': 1,
        'cafeId': 'cafe',
        'item': record(),
      }, () => f.current = session());
      await expectLater(
        f.repository.get(rid()),
        throwsA(failure(SavedRecipeFailure.session)),
      );
    },
  );
  test(
    'staff context can read and observe; role is not sent as authority',
    () async {
      final ports = FakePorts(),
          changes = StreamController<SavedRecipeSession?>.broadcast();
      final s = session(uid: 'staff', role: CafeRole.staff);
      final repository = WorkspaceSavedRecipeRepository(
        readPort: ports,
        observationPort: ports,
        currentSession: () => s,
        sessionChanges: changes.stream,
      );
      addTearDown(() async {
        await repository.dispose();
        await changes.close();
      });
      await repository.get(rid());
      await repository.reconcile(intent());
      expect(ports.calls.every((c) => c['uid'] == 'staff'), true);
      expect((ports.calls.first['request'] as Map).containsKey('role'), false);
    },
  );
  test('invalid request arguments fail without port dispatch', () async {
    final f = Fixture();
    await expectLater(
      f.repository.get('../foreign'),
      throwsA(failure(SavedRecipeFailure.invalid)),
    );
    for (final limit in [0, 21]) {
      await expectLater(
        f.repository.list(mode: 'active', limit: limit),
        throwsA(failure(SavedRecipeFailure.invalid)),
      );
    }
    await expectLater(
      f.repository.list(mode: 'other', limit: 1),
      throwsA(failure(SavedRecipeFailure.invalid)),
    );
    expect(f.ports.calls, isEmpty);
  });
  test('invalid immutable intent keys and lifecycle values are rejected', () {
    for (final key in ['short', 'x' * 129, 'bad key with spaces']) {
      expect(
        () => SavedRecipeSaveIntent(
          expectedCafeId: 'cafe',
          expectedMembershipGeneration: 7,
          idempotencyKey: key,
          recipe: SavedRecipeContent.parse(content()),
          attribution: SavedRecipeAttribution.parse(attribution()),
        ),
        throwsFormatException,
      );
    }
    expect(() => lifecycle(action: 'delete'), throwsFormatException);
    expect(() => lifecycle(version: 0), throwsFormatException);
    expect(() => intent(generation: -1), throwsFormatException);
  });
  test(
    'safe numbers reject fractional and oversized versions and generations',
    () {
      for (final n in [0, -1, 1.5, 9007199254740992]) {
        expect(
          () => SavedRecipe.parse(
            {...record(), 'version': n},
            projectId: 'velora-spark-test',
            cafeId: 'cafe',
          ),
          throwsFormatException,
        );
      }
      expect(SavedRecipeValidation.integer(9007199254740991), true);
      expect(SavedRecipeValidation.integer(1.0, 1), true);
    },
  );
  test(
    'missing stored metadata and detail target mismatch fail closed',
    () async {
      for (final key in record().keys) {
        final raw = record()..remove(key);
        expect(
          () => SavedRecipe.parse(
            raw,
            projectId: 'velora-spark-test',
            cafeId: 'cafe',
          ),
          throwsFormatException,
          reason: key,
        );
      }
      final f = Fixture();
      f.ports.hook = (_, _) async => {
        'schemaVersion': 1,
        'cafeId': 'cafe',
        'item': {...record(), 'recipeId': rid('c')},
      };
      await expectLater(
        f.repository.get(rid()),
        throwsA(failure(SavedRecipeFailure.invalidData)),
      );
    },
  );
  test(
    'duplicate and descending page IDs fail without silently sorting',
    () async {
      final f = Fixture();
      for (final items in [
        [summary(), summary()],
        [summary(c: 'b'), summary()],
      ]) {
        f.ports.hook = (_, _) async => {
          'schemaVersion': 1,
          'cafeId': 'cafe',
          'items': items,
          'nextCursor': null,
        };
        await expectLater(
          f.repository.list(mode: 'active', limit: 2),
          throwsA(failure(SavedRecipeFailure.invalidData)),
        );
      }
    },
  );
  test(
    'arbitrary dependency details are sanitized and observation stays uncertain',
    () async {
      final f = Fixture();
      f.ports.hook = (_, _) async => throw StateError('SECRET_RAW_TOKEN');
      await expectLater(
        f.repository.get(rid()),
        throwsA(failure(SavedRecipeFailure.unavailable)),
      );
      await expectLater(
        f.repository.reconcile(intent()),
        throwsA(failure(SavedRecipeFailure.unavailable, unknown: true)),
      );
    },
  );
  test(
    'session replacement during observation retains original uncertainty',
    () async {
      final f = Fixture(), pending = Completer<Object?>();
      f.ports.hook = (_, _) => pending.future;
      final future = f.repository.reconcile(intent());
      f.current = session();
      pending.complete({'schemaVersion': 1, 'status': 'unknown'});
      await expectLater(
        future,
        throwsA(failure(SavedRecipeFailure.session, unknown: true)),
      );
    },
  );
  test(
    'content, records and intent nested collections are detached and immutable',
    () {
      final raw = content(), parsed = SavedRecipeContent.parse(raw);
      (raw['steps'] as List)[0] = 'Modified';
      expect(parsed.steps.single, 'Cook safely.');
      expect(() => parsed.steps.add('x'), throwsUnsupportedError);
      expect(() => parsed.ingredients.clear(), throwsUnsupportedError);
      expect(
        () => (parsed.toJson()['ingredients'] as List).clear(),
        throwsUnsupportedError,
      );
      final r = SavedRecipe.parse(
        record(),
        projectId: 'velora-spark-test',
        cafeId: 'cafe',
      );
      expect(
        () => ((r.data['recipe'] as Map)['ingredients'] as List).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (intent().request['recipe'] as Map)['title'] = 'x',
        throwsUnsupportedError,
      );
      expect(r.provenance.evidence, 'unverified-attribution');
    },
  );
  final badContent = <String, void Function(Map<String, Object?>)>{
    'unexpected': (m) => m['extra'] = true,
    'missing': (m) => m.remove('title'),
    'surrogate': (m) => m['title'] = String.fromCharCode(0xd800),
    'control': (m) => m['title'] = 'Rice\u0085',
    'trim': (m) => m['title'] = ' Rice',
    'long title': (m) => m['title'] = 'a' * 101,
    'empty steps': (m) => m['steps'] = [],
    'long step': (m) => m['steps'] = ['a' * 301],
    'zero quantity': (m) => (m['ingredients'] as List)[0]['quantity'] = 0,
    'negative quantity': (m) => (m['ingredients'] as List)[0]['quantity'] = -1,
    'infinite quantity': (m) =>
        (m['ingredients'] as List)[0]['quantity'] = double.infinity,
    'nan quantity': (m) =>
        (m['ingredients'] as List)[0]['quantity'] = double.nan,
    'string quantity': (m) => (m['ingredients'] as List)[0]['quantity'] = '1',
    'large quantity': (m) =>
        (m['ingredients'] as List)[0]['quantity'] = 1000001,
    'fractional pcs': (m) => (m['ingredients'] as List)[0]['unit'] = 'pcs',
    'path': (m) => (m['ingredients'] as List)[0]['itemId'] = '../item',
    'duplicate ingredient': (m) => (m['ingredients'] as List).add({
      'itemId': 'item',
      'quantity': 1,
      'unit': 'g',
    }),
  };
  for (final e in badContent.entries) {
    test('rejects content ${e.key}', () {
      final m = content();
      e.value(m);
      expect(() => SavedRecipeContent.parse(m), throwsFormatException);
    });
  }
  test(
    'maximum Unicode fields accepted; aggregate byte validator rejects overflow',
    () {
      final m = content();
      m['title'] = '界' * 100;
      m['steps'] = List.filled(8, '界' * 300);
      m['whyRecommended'] = '界' * 300;
      m['ingredients'] = List.generate(
        10,
        (i) => {'itemId': '$i${'界' * 127}', 'quantity': 1000000, 'unit': 'kg'},
      );
      expect(SavedRecipeContent.parse(m).ingredients.length, 10);
      expect(
        () => SavedRecipeValidation.bound({'value': '界' * 5500}, 16384),
        throwsFormatException,
      );
    },
  );
  for (final kind in ['unspecified', 'sample', 'mock', 'claimed-ai']) {
    test('preserves attribution $kind including required nulls', () {
      final a = SavedRecipeAttribution.parse({
        'kind': kind,
        'provider': null,
        'ticketId': null,
      });
      expect(a.toJson(), {'kind': kind, 'provider': null, 'ticketId': null});
    });
  }
  for (final patch in [
    {'provider': 'other'},
    {'verified': true},
    {'kind': 'verified'},
    {'ticketId': 'bad'},
  ]) {
    test(
      'rejects attribution spoof $patch',
      () => expect(
        () => SavedRecipeAttribution.parse({...attribution(), ...patch}),
        throwsFormatException,
      ),
    );
  }
  test('required attribution null cannot be omitted', () {
    final m = attribution()..remove('ticketId');
    expect(() => SavedRecipeAttribution.parse(m), throwsFormatException);
  });
  final badRecord = <String, Object?>{
    'projectId': 'velora-73222',
    'cafeId': 'other',
    'version': 9007199254740992,
    'createdAt': '2026-02-30T00:00:00.000Z',
    'updatedAt': '2026-11-11T00:00:00.000Z',
    'archivedBy': 'owner',
    'source': 'groq',
    'provenanceEvidence': 'verified',
    'contentDigest': 'bad',
    'extra': true,
  };
  for (final e in badRecord.entries) {
    test(
      'rejects stored record ${e.key}',
      () => expect(
        () => SavedRecipe.parse(
          {...record(), e.key: e.value},
          projectId: 'velora-spark-test',
          cafeId: 'cafe',
        ),
        throwsFormatException,
      ),
    );
  }
  test(
    'archive requires matching updater/time; restoration uses explicit nulls',
    () {
      final m = {
        ...record(),
        'version': 2,
        'isArchived': true,
        'archivedBy': 'owner',
        'archivedAt': instant,
      };
      expect(
        SavedRecipe.parse(
          m,
          projectId: 'velora-spark-test',
          cafeId: 'cafe',
        ).isArchived,
        true,
      );
      expect(
        () => SavedRecipe.parse(
          {...m, 'archivedBy': 'staff'},
          projectId: 'velora-spark-test',
          cafeId: 'cafe',
        ),
        throwsFormatException,
      );
      expect(
        SavedRecipe.parse(
          {...record(), 'version': 3},
          projectId: 'velora-spark-test',
          cafeId: 'cafe',
        ).isArchived,
        false,
      );
    },
  );
  for (final value in [
    '2026-11-12T00:00:00Z',
    '2026-11-12T00:00:00.000+00:00',
    '2026-11-12',
    '2026-13-01T00:00:00.000Z',
  ]) {
    test(
      'rejects noncanonical UTC timestamp $value',
      () => expect(
        () => SavedRecipeValidation.instant(value),
        throwsFormatException,
      ),
    );
  }
  for (final outcome in [
    'created',
    'existing-active',
    'existing-archived',
    'archived',
    'restored',
  ]) {
    test(
      'historical acknowledgement preserves $outcome changed and replayed',
      () {
        final a = SavedRecipeAcknowledgement.parse(
          ack(outcome: outcome),
          cafeId: 'cafe',
          operation: ['archived', 'restored'].contains(outcome)
              ? 'lifecycle'
              : 'save',
        );
        expect(a.changed, !outcome.startsWith('existing-'));
        expect(a.replayed, true);
      },
    );
  }
  for (final patch in [
    {'changed': false},
    {'version': 2},
    {'replayed': 'true'},
    {'cafeId': 'other'},
    {'requestHash': 'bad'},
    {'extra': 1},
  ]) {
    test(
      'rejects inconsistent acknowledgement $patch',
      () => expect(
        () => SavedRecipeAcknowledgement.parse(
          {...ack(), ...patch},
          cafeId: 'cafe',
          operation: 'save',
        ),
        throwsFormatException,
      ),
    );
  }
  test('list and get exact E4 envelopes with immutable responses', () async {
    final f = Fixture();
    expect((await f.repository.get(rid())).recipeId, rid());
    final page = await f.repository.list(mode: 'active', limit: 1);
    expect(page.items.single.recipeId, rid());
    expect(() => page.items.clear(), throwsUnsupportedError);
    expect(f.ports.calls[0]['request'], {
      'expectedCafeId': 'cafe',
      'expectedMembershipGeneration': 7,
      'recipeId': rid(),
    });
    expect(f.ports.calls[1]['request'], {
      'expectedCafeId': 'cafe',
      'expectedMembershipGeneration': 7,
      'mode': 'active',
      'limit': 1,
      'cursor': null,
    });
  });
  test('pagination cursor preserves wire scope and exact session', () async {
    final f = Fixture();
    f.ports.hook = (_, _) async => {
      'schemaVersion': 1,
      'cafeId': 'cafe',
      'items': [summary()],
      'nextCursor': cursor(),
    };
    final page = await f.repository.list(mode: 'active', limit: 1);
    f.ports.hook = (_, _) async => {
      'schemaVersion': 1,
      'cafeId': 'cafe',
      'items': [summary(c: 'b')],
      'nextCursor': null,
    };
    await f.repository.list(mode: 'active', limit: 1, cursor: page.nextCursor);
    expect((f.ports.calls.last['request'] as Map)['cursor'], cursor());
    final replacement = Fixture();
    await expectLater(
      replacement.repository.list(
        mode: 'active',
        limit: 1,
        cursor: page.nextCursor,
      ),
      throwsA(failure(SavedRecipeFailure.invalid)),
    );
    expect(replacement.ports.calls, isEmpty);
  });
  for (final mode in ['active', 'archived', 'all']) {
    test('list mode $mode', () async {
      final f = Fixture();
      f.ports.hook = (_, _) async => {
        'schemaVersion': 1,
        'cafeId': 'cafe',
        'items': [summary(archived: mode != 'active')],
        'nextCursor': null,
      };
      expect((await f.repository.list(mode: mode, limit: 20)).items.length, 1);
    });
  }
  for (final patch in [
    {'projectId': 'other'},
    {'uid': 'staff'},
    {'cafeId': 'other'},
    {'membershipGeneration': 8},
    {'mode': 'all'},
    {'limit': 2},
    {'afterId': '../x'},
  ]) {
    test('rejects foreign/malformed cursor $patch', () async {
      final f = Fixture();
      f.ports.hook = (_, _) async => {
        'schemaVersion': 1,
        'cafeId': 'cafe',
        'items': [summary()],
        'nextCursor': {...cursor(), ...patch},
      };
      await expectLater(
        f.repository.list(mode: 'active', limit: 1),
        throwsA(failure(SavedRecipeFailure.invalidData)),
      );
    });
  }
  for (final raw in [
    {'schemaVersion': 1, 'cafeId': 'other', 'items': [], 'nextCursor': null},
    {
      'schemaVersion': 1,
      'cafeId': 'cafe',
      'items': [summary(), summary()],
      'nextCursor': null,
    },
    {
      'schemaVersion': 1,
      'cafeId': 'cafe',
      'items': [summary(archived: true)],
      'nextCursor': null,
    },
    {'schemaVersion': 1, 'cafeId': 'cafe', 'items': [], 'nextCursor': cursor()},
    {
      'schemaVersion': 1,
      'cafeId': 'cafe',
      'items': [],
      'nextCursor': null,
      'extra': true,
    },
  ]) {
    test('rejects invalid page $raw', () async {
      final f = Fixture();
      f.ports.hook = (_, _) async => raw;
      await expectLater(
        f.repository.list(mode: 'active', limit: 1),
        throwsA(failure(SavedRecipeFailure.invalidData)),
      );
    });
  }
  for (final invalid in [
    session(project: 'velora-73222'),
    session(verified: false),
    session(uid: 'staff'),
    session(generation: -1),
    session(revision: -1),
  ]) {
    test(
      'rejects invalid construction context ${invalid.uid} ${invalid.projectId} ${invalid.revision}',
      () {
        final changes = StreamController<SavedRecipeSession?>.broadcast();
        addTearDown(changes.close);
        final port = FakePorts();
        expect(
          () => WorkspaceSavedRecipeRepository(
            readPort: port,
            observationPort: port,
            currentSession: () => invalid,
            sessionChanges: changes.stream,
          ),
          throwsA(failure(SavedRecipeFailure.session)),
        );
        expect(port.calls, isEmpty);
      },
    );
  }
  for (final mode in [
    'logout',
    'replacement',
    'cafe',
    'generation',
    'role',
    'revision',
    'invalidated',
    'error',
    'done',
  ]) {
    test('late read rejected after $mode', () async {
      final f = Fixture(), pending = Completer<Object?>();
      f.ports.hook = (_, _) => pending.future;
      final future = f.repository.get(rid());
      switch (mode) {
        case 'logout':
          f.current = null;
        case 'replacement':
          f.current = session();
        case 'cafe':
          f.current = session(cafe: 'other');
        case 'generation':
          f.current = session(generation: 8);
        case 'role':
          f.current = session(uid: 'staff', role: CafeRole.staff);
        case 'revision':
          f.current = SavedRecipeSession(
            projectId: 'velora-spark-test',
            uid: 'owner',
            revision: 1,
            emailVerified: true,
            workspace: f.current!.workspace,
          );
        case 'invalidated':
          f.current!.workspace.invalidate();
        case 'error':
          f.changes.addError(StateError('secret'));
        case 'done':
          await f.changes.close();
      }
      pending.complete({
        'schemaVersion': 1,
        'cafeId': 'cafe',
        'item': record(),
      });
      await expectLater(future, throwsA(failure(SavedRecipeFailure.session)));
    });
  }
  test(
    'stream replacement is sticky even if current context later returns',
    () async {
      final f = Fixture();
      f.changes.add(session());
      await expectLater(
        f.repository.get(rid()),
        throwsA(failure(SavedRecipeFailure.session)),
      );
      expect(f.ports.calls, isEmpty);
    },
  );
  test(
    'read timeout is bounded; late completion cannot publish or retry',
    () async {
      final f = Fixture(timeout: const Duration(milliseconds: 10)),
          pending = Completer<Object?>();
      f.ports.hook = (_, _) => pending.future;
      await expectLater(
        f.repository.get(rid()),
        throwsA(failure(SavedRecipeFailure.unavailable)),
      );
      pending.complete({
        'schemaVersion': 1,
        'cafeId': 'cafe',
        'item': record(),
      });
      expect(f.ports.calls.length, 1);
    },
  );
  test('oversized response fails closed', () async {
    final f = Fixture();
    f.ports.hook = (_, _) async => {'padding': '界' * 22000};
    await expectLater(
      f.repository.get(rid()),
      throwsA(failure(SavedRecipeFailure.invalidData)),
    );
  });
  test('mutations always blocked, zero port calls', () async {
    final f = Fixture();
    await expectLater(
      f.repository.save(intent()),
      throwsA(failure(SavedRecipeFailure.unavailable)),
    );
    await expectLater(
      f.repository.lifecycle(lifecycle()),
      throwsA(failure(SavedRecipeFailure.unavailable)),
    );
    expect(f.ports.calls, isEmpty);
  });
  test(
    'read-only reconciliation preserves exact original request and unknown absence',
    () async {
      final f = Fixture(), original = intent();
      expect((await f.repository.reconcile(original)).committed, false);
      expect(f.ports.calls.single['request'], {
        'operation': 'save',
        'request': original.request,
      });
      f.ports.hook = (_, _) async => {
        'schemaVersion': 1,
        'status': 'committed',
        'result': ack(),
      };
      final result = await f.repository.reconcile(original);
      expect(result.result!.changed, true);
      expect(result.result!.replayed, true);
      expect(f.ports.calls.length, 2);
    },
  );
  test(
    'lifecycle reconciliation validates original target/version/action',
    () async {
      final f = Fixture();
      f.ports.hook = (_, _) async => {
        'schemaVersion': 1,
        'status': 'committed',
        'result': ack(outcome: 'archived'),
      };
      expect((await f.repository.reconcile(lifecycle())).committed, true);
      await expectLater(
        f.repository.reconcile(lifecycle(action: 'restore')),
        throwsA(failure(SavedRecipeFailure.invalidData, unknown: true)),
      );
    },
  );
  test('reconciliation cannot adopt another cafe/generation', () async {
    final f = Fixture();
    for (final i in [intent(cafe: 'other'), intent(generation: 8)]) {
      await expectLater(
        f.repository.reconcile(i),
        throwsA(failure(SavedRecipeFailure.stale, unknown: true)),
      );
    }
    expect(f.ports.calls, isEmpty);
  });
  for (final raw in [
    {'schemaVersion': 1, 'status': 'definitely-not-committed'},
    {'schemaVersion': 1, 'status': 'unknown', 'result': null},
    {'schemaVersion': 1, 'status': 'committed', 'result': ack(replayed: false)},
  ]) {
    test('invalid observation never permits resend $raw', () async {
      final f = Fixture();
      f.ports.hook = (_, _) async => raw;
      await expectLater(
        f.repository.reconcile(intent()),
        throwsA(failure(SavedRecipeFailure.invalidData, unknown: true)),
      );
      expect(f.ports.calls.length, 1);
    });
  }
  for (final kind in [
    SavedRecipeFailure.conflict,
    SavedRecipeFailure.permission,
    SavedRecipeFailure.notFound,
    SavedRecipeFailure.unavailable,
  ]) {
    test('safe injected failure $kind and no retries', () async {
      final f = Fixture();
      f.ports.hook = (_, _) async => throw SavedRecipeException(kind);
      await expectLater(f.repository.get(rid()), throwsA(failure(kind)));
      await expectLater(
        f.repository.reconcile(intent()),
        throwsA(failure(kind, unknown: true)),
      );
      expect(f.ports.calls.length, 2);
    });
  }
}
