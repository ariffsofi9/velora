import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/workspace_resolver.dart';
import 'package:velora/services/workspace_store.dart';

class _User extends Fake implements User {
  @override
  final String uid;
  _User(this.uid);
}

class _Auth extends Fake implements FirebaseAuth {
  User? user;
  _Auth(String? uid) : user = uid == null ? null : _User(uid);
  @override
  User? get currentUser => user;
}

class _Store implements WorkspaceStore, WorkspaceReader {
  final Map<String, Map<String, dynamic>> docs;
  final List<String> reads = [];
  Object? error;
  void Function()? afterRead;
  int transactions = 0;
  _Store(this.docs);
  @override
  Future<T> readTransaction<T>(Future<T> Function(WorkspaceReader) read) async {
    transactions++;
    if (error != null) throw error!;
    final result = await read(this);
    afterRead?.call();
    return result;
  }

  @override
  Future<Map<String, dynamic>?> readDocument(String path) async {
    reads.add(path);
    return docs[path];
  }
}

Map<String, dynamic> _link(String uid) => {
  'uid': uid,
  'cafeId': 'cafe-a',
  'status': 'active',
  'schemaVersion': 1,
};

_Store _fixture() => _Store({
  'user_cafe_memberships/owner-a': _link('owner-a'),
  'user_cafe_memberships/staff-a': _link('staff-a'),
  'cafes/cafe-a': {
    'ownerUid': 'owner-a',
    'status': 'active',
    'schemaVersion': 1,
  },
  'cafes/cafe-a/members/owner-a': {..._link('owner-a'), 'role': 'owner'},
  'cafes/cafe-a/members/staff-a': {..._link('staff-a'), 'role': 'staff'},
});

Matcher _failure(WorkspaceFailure failure) =>
    isA<WorkspaceResolutionException>().having(
      (e) => e.failure,
      'failure',
      failure,
    );

void main() {
  for (final role in CafeRole.values) {
    test('Resolves valid ${role.name} links in one read transaction', () async {
      final uid = role == CafeRole.owner ? 'owner-a' : 'staff-a';
      final store = _fixture();
      final workspace = await WorkspaceResolver(
        auth: _Auth(uid),
        store: store,
      ).resolve();
      expect(workspace.uid, uid);
      expect(workspace.cafeId, 'cafe-a');
      expect(workspace.ownerUid, 'owner-a');
      expect(workspace.role, role);
      expect(store.transactions, 1);
      expect(store.reads, isNot(contains('users/$uid')));
    });
  }

  test('Signed-out resolution does not access Firestore', () async {
    final store = _fixture();
    await expectLater(
      WorkspaceResolver(auth: _Auth(null), store: store).resolve(),
      throwsA(_failure(WorkspaceFailure.unauthenticated)),
    );
    expect(store.transactions, 0);
  });

  test('Missing mapping never creates an owner or repairs data', () async {
    final store = _fixture()..docs.remove('user_cafe_memberships/staff-a');
    final before = Map.of(store.docs);
    await expectLater(
      WorkspaceResolver(auth: _Auth('staff-a'), store: store).resolve(),
      throwsA(_failure(WorkspaceFailure.missingMembership)),
    );
    expect(store.docs, before);
    expect(store.reads, ['user_cafe_memberships/staff-a']);
  });

  final mutations = <String, void Function(_Store)>{
    'mapping points to another cafe': (s) =>
        s.docs['user_cafe_memberships/staff-a']!['cafeId'] = 'cafe-b',
    'forged UID': (s) =>
        s.docs['user_cafe_memberships/staff-a']!['uid'] = 'owner-a',
    'path injection': (s) =>
        s.docs['user_cafe_memberships/staff-a']!['cafeId'] = 'a/members/b',
    'unknown schema': (s) =>
        s.docs['user_cafe_memberships/staff-a']!['schemaVersion'] = 2,
    'disabled mapping': (s) =>
        s.docs['user_cafe_memberships/staff-a']!['status'] = 'disabled',
    'missing member': (s) {
      s.docs.remove('cafes/cafe-a/members/staff-a');
    },
    'disabled member': (s) =>
        s.docs['cafes/cafe-a/members/staff-a']!['status'] = 'disabled',
    'mismatched member cafe': (s) =>
        s.docs['cafes/cafe-a/members/staff-a']!['cafeId'] = 'cafe-b',
    'unknown role': (s) =>
        s.docs['cafes/cafe-a/members/staff-a']!['role'] = 'admin',
    'self promotion': (s) =>
        s.docs['cafes/cafe-a/members/staff-a']!['role'] = 'owner',
    'missing cafe': (s) {
      s.docs.remove('cafes/cafe-a');
    },
    'inactive cafe': (s) => s.docs['cafes/cafe-a']!['status'] = 'disabled',
    'missing owner': (s) {
      s.docs.remove('cafes/cafe-a/members/owner-a');
    },
    'owner demoted': (s) =>
        s.docs['cafes/cafe-a/members/owner-a']!['role'] = 'staff',
    'owner mapped elsewhere': (s) =>
        s.docs['user_cafe_memberships/owner-a']!['cafeId'] = 'cafe-b',
    'owner mapping missing': (s) {
      s.docs.remove('user_cafe_memberships/owner-a');
    },
  };
  for (final mutation in mutations.entries) {
    test('Fails closed: ${mutation.key}', () async {
      final store = _fixture();
      mutation.value(store);
      await expectLater(
        WorkspaceResolver(auth: _Auth('staff-a'), store: store).resolve(),
        throwsA(_failure(WorkspaceFailure.inconsistentMembership)),
      );
    });
  }

  test(
    'Offline/denied/backend errors are unavailable without leaking details',
    () async {
      final store = _fixture()..error = StateError('backend-sensitive-detail');
      try {
        await WorkspaceResolver(auth: _Auth('owner-a'), store: store).resolve();
        fail('Must not resolve');
      } on WorkspaceResolutionException catch (error) {
        expect(error.failure, WorkspaceFailure.unavailable);
        expect(error.toString(), isNot(contains('backend-sensitive-detail')));
      }
    },
  );

  test('Logout during resolution discards the result', () async {
    final auth = _Auth('owner-a');
    final store = _fixture()..afterRead = () => auth.user = null;
    await expectLater(
      WorkspaceResolver(auth: auth, store: store).resolve(),
      throwsA(_failure(WorkspaceFailure.sessionChanged)),
    );
  });

  test('Account change during resolution discards the result', () async {
    final auth = _Auth('owner-a');
    final store = _fixture()..afterRead = () => auth.user = _User('staff-a');
    await expectLater(
      WorkspaceResolver(auth: auth, store: store).resolve(),
      throwsA(_failure(WorkspaceFailure.sessionChanged)),
    );
  });
}
