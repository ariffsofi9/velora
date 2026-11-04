// Offline Firebase interface doubles only.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/models/menu_item.dart';
import 'package:velora/repositories/workspace_menu_repository.dart';
import 'package:velora/services/workspace_resolver.dart';
import 'menu_model_test.dart' show menuData;

class UserDouble extends Fake implements User {
  @override
  final String uid;
  UserDouble(this.uid);
}

class AuthDouble extends Fake implements FirebaseAuth {
  User? user = UserDouble('staff-a');
  final changes = StreamController<User?>.broadcast(sync: true);
  @override
  User? get currentUser => user;
  @override
  Stream<User?> authStateChanges() => changes.stream;
  void change(String? uid) {
    user = uid == null ? null : UserDouble(uid);
    changes.add(user);
  }
}

class ResolverDouble extends WorkspaceResolver {
  Completer<CafeWorkspace>? pending;
  CafeWorkspace workspace = const CafeWorkspace(
    cafeId: 'cafe-a',
    uid: 'staff-a',
    ownerUid: 'owner-a',
    role: CafeRole.staff,
  );
  bool revoked = false;
  @override
  Future<CafeWorkspace> resolve() async {
    if (pending != null) return pending!.future;
    if (revoked) {
      throw const WorkspaceResolutionException(
        WorkspaceFailure.inconsistentMembership,
      );
    }
    return workspace;
  }
}

class CallableDouble implements MenuCallable {
  final calls = <(String, Map<String, Object>)>[];
  Future<Map<String, dynamic>> Function(String, Map<String, Object>)? handler;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, Object> data,
  ) async {
    calls.add((name, Map.from(data)));
    return handler != null
        ? await handler!(name, data)
        : {
            'cafeId': 'cafe-a',
            'itemId': 'menu-a',
            'version': 2,
            'changed': true,
          };
  }
}

void main() {
  late AuthDouble auth;
  late ResolverDouble resolver;
  late CallableDouble callable;
  late FirebaseMenuRepository repo;
  setUp(() {
    auth = AuthDouble();
    resolver = ResolverDouble();
    callable = CallableDouble();
    repo = FirebaseMenuRepository(
      auth: auth,
      resolver: resolver,
      callable: callable,
    );
  });
  tearDown(() async {
    await auth.changes.close();
  });
  test(
    'Staff availability sends only target/version/key/isAvailable',
    () async {
      await repo.availability(
        MenuItem.fromMap(menuData()),
        false,
        'availability-key-0001',
      );
      expect(callable.calls.single.$1, 'updateMenuItem');
      expect(callable.calls.single.$2, {
        'itemId': 'menu-a',
        'expectedVersion': 1,
        'idempotencyKey': 'availability-key-0001',
        'isAvailable': false,
      });
    },
  );
  test('Staff cannot use full save or lifecycle methods', () async {
    await expectLater(
      repo.save(
        draft: const MenuDraft('Latte', 'Coffee', 1200, true),
        key: 'create-request-0001',
      ),
      throwsA(isA<MenuException>()),
    );
    await expectLater(
      repo.lifecycle(
        MenuItem.fromMap(menuData()),
        true,
        'archive-request-0001',
      ),
      throwsA(isA<MenuException>()),
    );
    expect(callable.calls, isEmpty);
  });
  test(
    'Owner calls existing save and lifecycle names with exact version',
    () async {
      resolver.workspace = const CafeWorkspace(
        cafeId: 'cafe-a',
        uid: 'staff-a',
        ownerUid: 'staff-a',
        role: CafeRole.owner,
      );
      await repo.save(
        item: MenuItem.fromMap(menuData()),
        draft: const MenuDraft('Latte', 'Coffee', 1200, true),
        key: 'update-request-0001',
      );
      await repo.lifecycle(
        MenuItem.fromMap(menuData()),
        false,
        'restore-request-0001',
      );
      expect(callable.calls.map((c) => c.$1), [
        'updateMenuItem',
        'setMenuItemLifecycle',
      ]);
      expect(callable.calls.last.$2['action'], 'restore');
      expect(callable.calls.first.$2['priceMinor'], 1200);
    },
  );
  test(
    'Owner create sends integer sen and only the existing create contract',
    () async {
      resolver.workspace = const CafeWorkspace(
        cafeId: 'cafe-a',
        uid: 'staff-a',
        ownerUid: 'staff-a',
        role: CafeRole.owner,
      );
      await repo.save(
        draft: const MenuDraft('New Latte', 'Coffee', 1250, true),
        key: 'create-request-0001',
      );
      expect(callable.calls.single.$1, 'createMenuItem');
      expect(callable.calls.single.$2, {
        'idempotencyKey': 'create-request-0001',
        'name': 'New Latte',
        'category': 'Coffee',
        'priceMinor': 1250,
        'isAvailable': true,
      });
    },
  );
  test('pagination passes cursor and validates response scope', () async {
    callable.handler = (_, data) async => {
      'cafeId': 'cafe-a',
      'items': [menuData()],
      'nextCursor': null,
    };
    final page = await repo.list(cursor: 'previous', includeArchived: true);
    expect(page.items.single.id, 'menu-a');
    expect(callable.calls.single.$2, {
      'includeArchived': true,
      'limit': 20,
      'cursor': 'previous',
    });
    callable.handler = (_, data) async => {
      'cafeId': 'other',
      'items': [menuData()],
      'nextCursor': null,
    };
    await expectLater(repo.list(), throwsA(isA<MenuException>()));
  });
  test(
    'foreign item is blocked before dispatch, including first call',
    () async {
      await expectLater(
        repo.availability(
          MenuItem.fromMap(menuData(cafe: 'foreign')),
          false,
          'availability-key-0001',
        ),
        throwsA(isA<MenuException>()),
      );
      expect(callable.calls, isEmpty);
    },
  );
  for (final transition in [
    'signout',
    'identity',
    'away-back',
    'revoked',
    'cafe',
  ]) {
    test('pending result discarded: $transition', () async {
      final pending = Completer<Map<String, dynamic>>();
      callable.handler = (_, data) => pending.future;
      final result = repo.get('menu-a');
      final expectation = expectLater(result, throwsA(isA<MenuException>()));
      await Future<void>.delayed(Duration.zero);
      if (transition == 'revoked') {
        resolver.revoked = true;
      } else if (transition == 'cafe') {
        resolver.workspace = const CafeWorkspace(
          cafeId: 'other',
          uid: 'staff-a',
          ownerUid: 'other-owner',
          role: CafeRole.staff,
        );
      } else {
        auth.change(transition == 'identity' ? 'other-user' : null);
        if (transition == 'away-back') auth.change('staff-a');
      }
      pending.complete({'item': menuData()});
      await expectation;
    });
  }
  test(
    'version conflicts become safe typed errors without raw provider messages',
    () async {
      callable.handler = (_, data) async =>
          throw FirebaseFunctionsException(code: 'aborted', message: 'PRIVATE');
      await expectLater(
        repo.get('menu-a'),
        throwsA(
          isA<MenuException>().having(
            (e) => e.failure,
            'failure',
            MenuFailure.stale,
          ),
        ),
      );
    },
  );
  test(
    'malformed, duplicate and archived default-list results fail closed',
    () async {
      for (final rows in [
        [menuData(), menuData()],
        [menuData(archived: true)],
        [
          {'id': 'bad'},
        ],
      ]) {
        callable.handler = (_, data) async => {
          'cafeId': 'cafe-a',
          'items': rows,
          'nextCursor': null,
        };
        await expectLater(repo.list(), throwsA(isA<MenuException>()));
      }
    },
  );
  test(
    'session away-and-back during initial mutation authorization prevents dispatch',
    () async {
      resolver.pending = Completer<CafeWorkspace>();
      final operation = repo.availability(
        MenuItem.fromMap(menuData()),
        false,
        'availability-key-0001',
      );
      final expected = expectLater(operation, throwsA(isA<MenuException>()));
      await Future<void>.delayed(Duration.zero);
      auth.change(null);
      auth.change('staff-a');
      resolver.pending!.complete(resolver.workspace);
      await expected;
      expect(callable.calls, isEmpty);
    },
  );
  test(
    'full page cursor is accepted and carried to subsequent requests',
    () async {
      callable.handler = (_, data) async => {
        'cafeId': 'cafe-a',
        'items': List.generate(
          20,
          (n) => menuData(id: 'item-${n.toString().padLeft(2, '0')}'),
        ),
        'nextCursor': 'item-19',
      };
      final first = await repo.list();
      expect(first.items.length, 20);
      callable.handler = (_, data) async => {
        'cafeId': 'cafe-a',
        'items': <Object>[],
        'nextCursor': null,
      };
      await repo.list(cursor: first.nextCursor);
      expect(callable.calls.last.$2['cursor'], 'item-19');
    },
  );
}
