import 'dart:async';
import 'dart:math';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/menu_item.dart';
import '../models/cafe_workspace.dart';
import '../services/workspace_resolver.dart';

enum MenuFailure {
  session,
  permission,
  stale,
  conflict,
  invalid,
  invalidData,
  unavailable,
}

class MenuException implements Exception {
  final MenuFailure failure;
  const MenuException(this.failure);
  String get message => switch (failure) {
    MenuFailure.session =>
      'Your session changed. Sign in again to open this menu.',
    MenuFailure.permission =>
      'Your workspace permission could not be verified.',
    MenuFailure.stale =>
      'This menu item changed. Reload the latest values and review again.',
    MenuFailure.conflict =>
      'This request conflicts with an earlier action. Reload before retrying.',
    MenuFailure.invalid => 'Check the menu fields and try again.',
    MenuFailure.invalidData => 'Menu data could not be verified.',
    MenuFailure.unavailable =>
      'Menu is unavailable. Check your connection and retry.',
  };
}

String newMenuRequestKey() {
  final random = Random.secure();
  return List.generate(
    24,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class MenuItemsPage {
  final List<MenuItem> items;
  final String? nextCursor;
  const MenuItemsPage(this.items, this.nextCursor);
}

abstract interface class MenuRepository {
  Stream<void> get sessionChanges;
  Future<CafeWorkspace> resolve();
  Future<MenuItemsPage> list({bool includeArchived = false, String? cursor});
  Future<MenuItem> get(String id);
  Future<void> save({
    MenuItem? item,
    required MenuDraft draft,
    required String key,
  });
  Future<void> availability(MenuItem item, bool available, String key);
  Future<void> lifecycle(MenuItem item, bool archive, String key);
}

abstract interface class MenuCallable {
  Future<Map<String, dynamic>> call(String name, Map<String, Object> data);
}

class FirebaseMenuCallable implements MenuCallable {
  final FirebaseFunctions? functions;
  FirebaseMenuCallable({this.functions});
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, Object> data,
  ) async =>
      (await (functions ??
                  FirebaseFunctions.instanceFor(region: 'asia-southeast1'))
              .httpsCallable(name)
              .call<Map<String, dynamic>>(data))
          .data;
}

class FirebaseMenuRepository implements MenuRepository {
  final FirebaseAuth? auth;
  final WorkspaceResolver? resolver;
  final MenuCallable? callable;
  CafeWorkspace? _expected;
  FirebaseMenuRepository({this.auth, this.resolver, this.callable});
  FirebaseAuth get _auth => auth ?? FirebaseAuth.instance;
  @override
  Stream<void> get sessionChanges async* {
    var uid = _auth.currentUser?.uid;
    await for (final user in _auth.authStateChanges()) {
      if (user?.uid != uid) {
        uid = user?.uid;
        yield null;
      }
    }
  }

  @override
  Future<CafeWorkspace> resolve() async {
    try {
      final current = await (resolver ?? WorkspaceResolver(auth: _auth))
          .resolve();
      final expected = _expected;
      if (_auth.currentUser?.uid != current.uid ||
          (expected != null &&
              (current.uid != expected.uid ||
                  current.cafeId != expected.cafeId ||
                  current.ownerUid != expected.ownerUid ||
                  current.role != expected.role))) {
        throw const MenuException(MenuFailure.session);
      }
      _expected ??= current;
      return current;
    } on WorkspaceResolutionException catch (error) {
      throw MenuException(
        error.failure == WorkspaceFailure.unavailable
            ? MenuFailure.unavailable
            : MenuFailure.permission,
      );
    }
  }

  Future<Map<String, dynamic>> _request(
    String name,
    Map<String, Object> data, {
    bool ownerOnly = false,
    MenuItem? target,
  }) async {
    var invalidated = false;
    var uid = _auth.currentUser?.uid;
    final subscription = _auth.authStateChanges().listen(
      (user) {
        if (user?.uid != uid) invalidated = true;
        uid = user?.uid;
      },
      onError: (Object _) {
        invalidated = true;
      },
    );
    try {
      final workspace = await resolve();
      if (invalidated) throw const MenuException(MenuFailure.session);
      if (target != null && target.cafeId != workspace.cafeId) {
        throw const MenuException(MenuFailure.invalid);
      }
      if (ownerOnly && workspace.role != CafeRole.owner) {
        throw const MenuException(MenuFailure.permission);
      }
      final dataResult = await (callable ?? FirebaseMenuCallable()).call(
        name,
        data,
      );
      await resolve();
      if (invalidated) throw const MenuException(MenuFailure.session);
      return dataResult;
    } on FirebaseFunctionsException catch (error) {
      throw MenuException(switch (error.code) {
        'aborted' => MenuFailure.stale,
        'already-exists' => MenuFailure.conflict,
        'unauthenticated' => MenuFailure.session,
        'permission-denied' => MenuFailure.permission,
        'failed-precondition' => MenuFailure.permission,
        'invalid-argument' => MenuFailure.invalid,
        _ => MenuFailure.unavailable,
      });
    } on MenuException {
      rethrow;
    } catch (_) {
      throw const MenuException(MenuFailure.unavailable);
    } finally {
      await subscription.cancel();
    }
  }

  MenuItem _item(Object? raw) {
    try {
      if (raw is! Map) throw const FormatException();
      final item = MenuItem.fromMap(Map<String, dynamic>.from(raw));
      if (item.cafeId != _expected?.cafeId) throw const FormatException();
      return item;
    } catch (_) {
      throw const MenuException(MenuFailure.invalidData);
    }
  }

  @override
  Future<MenuItemsPage> list({
    bool includeArchived = false,
    String? cursor,
  }) async {
    if (cursor != null && !MenuItem.validId(cursor)) {
      throw const MenuException(MenuFailure.invalid);
    }
    final data = await _request('listMenuItems', {
      'includeArchived': includeArchived,
      'limit': 20,
      'cursor': ?cursor,
    });
    final rows = data['items'];
    final next = data['nextCursor'];
    if (data['cafeId'] != _expected?.cafeId ||
        rows is! List ||
        rows.length > 20 ||
        (next != null && (!MenuItem.validId(next) || rows.length != 20))) {
      throw const MenuException(MenuFailure.invalidData);
    }
    final items = rows.map(_item).toList(growable: false);
    if (items.map((item) => item.id).toSet().length != items.length ||
        (!includeArchived && items.any((item) => item.isArchived)) ||
        next == cursor && next != null) {
      throw const MenuException(MenuFailure.invalidData);
    }
    return MenuItemsPage(List.unmodifiable(items), next as String?);
  }

  @override
  Future<MenuItem> get(String id) async {
    if (!MenuItem.validId(id)) throw const MenuException(MenuFailure.invalid);
    final item = _item((await _request('getMenuItem', {'itemId': id}))['item']);
    if (item.id != id) throw const MenuException(MenuFailure.invalidData);
    return item;
  }

  Future<void> _write(
    String name,
    Map<String, Object> data, {
    bool ownerOnly = false,
    MenuItem? target,
  }) async {
    final result = await _request(
      name,
      data,
      ownerOnly: ownerOnly,
      target: target,
    );
    if (result['cafeId'] != _expected?.cafeId ||
        !MenuItem.validId(result['itemId']) ||
        (data.containsKey('itemId') && result['itemId'] != data['itemId']) ||
        !MenuItem.validVersion(result['version']) ||
        result['changed'] is! bool) {
      throw const MenuException(MenuFailure.invalidData);
    }
  }

  Map<String, Object> _target(MenuItem item, String key) {
    if (!MenuItem.validId(item.id) ||
        (_expected != null && item.cafeId != _expected!.cafeId) ||
        !MenuItem.validVersion(item.version) ||
        !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(key)) {
      throw const MenuException(MenuFailure.invalid);
    }
    return {
      'itemId': item.id,
      'expectedVersion': item.version,
      'idempotencyKey': key,
    };
  }

  @override
  Future<void> save({
    MenuItem? item,
    required MenuDraft draft,
    required String key,
  }) async {
    Map<String, Object> edits;
    try {
      edits = draft.toData();
    } catch (_) {
      throw const MenuException(MenuFailure.invalid);
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(key)) {
      throw const MenuException(MenuFailure.invalid);
    }
    await _write(
      item == null ? 'createMenuItem' : 'updateMenuItem',
      {
        if (item == null) 'idempotencyKey': key,
        if (item != null) ..._target(item, key),
        ...edits,
      },
      ownerOnly: true,
      target: item,
    );
  }

  @override
  Future<void> availability(MenuItem item, bool available, String key) async {
    await _write('updateMenuItem', {
      ..._target(item, key),
      'isAvailable': available,
    }, target: item);
  }

  @override
  Future<void> lifecycle(MenuItem item, bool archive, String key) async {
    await _write(
      'setMenuItemLifecycle',
      {..._target(item, key), 'action': archive ? 'archive' : 'restore'},
      ownerOnly: true,
      target: item,
    );
  }
}
