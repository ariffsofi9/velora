import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/menu_item.dart';
import '../repositories/workspace_menu_repository.dart';
import 'workspace_session.dart';

/// Trusted composition context, not authority. Revision advances on every auth
/// or workspace transition, including sign-out/back to the same UID.
class MenuHttpsSession {
  final String projectId, uid;
  final int revision;
  final bool emailVerified;
  final WorkspaceSession workspace;
  const MenuHttpsSession({
    required this.projectId,
    required this.uid,
    required this.revision,
    required this.emailVerified,
    required this.workspace,
  });
  bool matches(MenuHttpsSession? other) =>
      other != null &&
      projectId == other.projectId &&
      uid == other.uid &&
      revision == other.revision &&
      emailVerified == other.emailVerified &&
      identical(workspace, other.workspace);
}

class MenuHttpsException extends MenuException {
  final String code;
  final bool outcomeUnknown;
  const MenuHttpsException(
    super.failure,
    this.code, {
    required this.outcomeUnknown,
  });
  @override
  String toString() => 'Menu HTTPS unavailable: $code';
}

MenuHttpsException _error(String code, bool unknown) => MenuHttpsException(
  switch (code) {
    'unauthenticated' ||
    'session-changed' ||
    'request-context-changed' => MenuFailure.session,
    'permission-denied' || 'failed-precondition' => MenuFailure.permission,
    'aborted' => MenuFailure.stale,
    'already-exists' => MenuFailure.conflict,
    'invalid-argument' => MenuFailure.invalid,
    'invalid-response' => MenuFailure.invalidData,
    _ => MenuFailure.unavailable,
  },
  code,
  outcomeUnknown: unknown,
);

class _Binding {
  final MenuHttpsSession session;
  final String body, operation;
  bool busy = false, uncertain = false;
  _Binding(this.session, this.body, this.operation);
}

final _scopes = Expando<Map<String, _Binding>>(
  'Menu request identity and uncertainty',
);
bool _integer(Object? n) => n is int && n >= 0 && n <= 9007199254740991;
bool _keys(Map data, List<String> allowed, List<String> required) =>
    data.keys.every(allowed.contains) && required.every(data.containsKey);
int _compareId(String a, String b) {
  final left = utf8.encode(a), right = utf8.encode(b);
  for (var i = 0; i < left.length && i < right.length; i++) {
    if (left[i] != right[i]) return left[i].compareTo(right[i]);
  }
  return left.length.compareTo(right.length);
}

/// Unwired TEST-only MenuCallable. No Firebase SDK/default client, direct writes,
/// secrets or retries. Caller owns a non-retrying redirect-rejecting client and
/// real SHA-256 hex provider. Retain sessionScope across reconstruction. Bindings
/// are bounded in-memory evidence, not qualified crash recovery or activation.
class MenuHttpsTransport implements MenuCallable {
  final Uri endpoint;
  final String projectId;
  final http.Client client;
  final MenuHttpsSession? Function() currentSession;
  final Stream<MenuHttpsSession?> sessionChanges;
  final Future<String?> Function(MenuHttpsSession) idToken;
  final String Function(String) sha256;
  final Object sessionScope;
  final Duration timeout, cleanupTimeout;
  final int maxResponseBytes;
  static const _routes = {
    'createMenuItem': 'create',
    'getMenuItem': 'get',
    'listMenuItems': 'list',
    'updateMenuItem': 'update',
    'setMenuItemLifecycle': 'lifecycle',
  };
  MenuHttpsTransport({
    required this.endpoint,
    required this.projectId,
    required String endpointProjectId,
    required this.client,
    required this.currentSession,
    required this.sessionChanges,
    required this.idToken,
    required this.sha256,
    required this.sessionScope,
    this.timeout = const Duration(seconds: 15),
    this.cleanupTimeout = const Duration(milliseconds: 100),
    this.maxResponseBytes = 262144,
  }) {
    if (projectId != 'velora-spark-test' ||
        endpointProjectId != projectId ||
        endpoint.scheme != 'https' ||
        endpoint.port != 443 ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.authority.contains('@') ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        !['', '/'].contains(endpoint.path) ||
        endpoint.host.length > 253 ||
        !RegExp(
          r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$',
        ).hasMatch(endpoint.host) ||
        endpoint.host.endsWith('.localhost') ||
        timeout <= Duration.zero ||
        timeout > const Duration(seconds: 30) ||
        cleanupTimeout <= Duration.zero ||
        cleanupTimeout > const Duration(seconds: 5) ||
        maxResponseBytes < 1 ||
        maxResponseBytes > 262144) {
      throw _error('invalid-configuration', false);
    }
  }
  MenuHttpsSession _capture() {
    final s = currentSession();
    if (s == null ||
        s.projectId != projectId ||
        !MenuItem.validId(s.uid) ||
        !_integer(s.revision) ||
        !s.emailVerified ||
        !s.workspace.isActive ||
        s.uid != s.workspace.uid ||
        !MenuItem.validId(s.workspace.cafeId) ||
        !MenuItem.validId(s.workspace.ownerUid) ||
        !_integer(s.workspace.membershipGeneration) ||
        s.workspace.isOwner != (s.uid == s.workspace.ownerUid)) {
      throw _error('unauthenticated', false);
    }
    return s;
  }

  void _check(MenuHttpsSession s, bool unknown) {
    if (!s.workspace.isActive || !s.matches(currentSession())) {
      throw _error('session-changed', unknown);
    }
  }

  void _request(String op, Map<String, Object> data, MenuHttpsSession s) {
    final mutation = !['get', 'list'].contains(op);
    const edits = ['name', 'category', 'priceMinor', 'isAvailable'];
    final required = op == 'list'
        ? <String>[]
        : op == 'get'
        ? ['itemId']
        : op == 'create'
        ? ['idempotencyKey', ...edits]
        : [
            'idempotencyKey',
            'itemId',
            'expectedVersion',
            if (op == 'lifecycle') 'action',
          ];
    final allowed = op == 'list'
        ? ['includeArchived', 'limit', 'cursor']
        : op == 'get'
        ? ['itemId']
        : [...required, if (op == 'update') ...edits];
    if (mutation) {
      required.addAll(['expectedCafeId', 'expectedMembershipGeneration']);
      allowed.addAll(['expectedCafeId', 'expectedMembershipGeneration']);
    }
    if (!_keys(data, allowed, required) ||
        (data.containsKey('itemId') && !MenuItem.validId(data['itemId'])) ||
        (data.containsKey('expectedVersion') &&
            !MenuItem.validVersion(data['expectedVersion'])) ||
        (data.containsKey('priceMinor') &&
            !MenuItem.validPrice(data['priceMinor'])) ||
        (data.containsKey('isAvailable') && data['isAvailable'] is! bool) ||
        (data.containsKey('name') && data['name'] is! String) ||
        (data.containsKey('category') && data['category'] is! String) ||
        (op == 'update' && !edits.any(data.containsKey)) ||
        (op == 'lifecycle' &&
            !['archive', 'restore'].contains(data['action']))) {
      throw _error('invalid-argument', false);
    }
    if (op == 'list') {
      if ((data.containsKey('includeArchived') &&
              data['includeArchived'] is! bool) ||
          (data.containsKey('cursor') && !MenuItem.validId(data['cursor'])) ||
          (data.containsKey('limit') &&
              (!_integer(data['limit']) ||
                  (data['limit'] as int) < 1 ||
                  (data['limit'] as int) > 50))) {
        throw _error('invalid-argument', false);
      }
    }
    if (mutation) {
      if (data['idempotencyKey'] is! String ||
          !RegExp(
            r'^[A-Za-z0-9_-]{16,128}$',
          ).hasMatch(data['idempotencyKey'] as String) ||
          !MenuItem.validId(data['expectedCafeId']) ||
          !_integer(data['expectedMembershipGeneration'])) {
        throw _error('invalid-argument', false);
      }
      if (data['expectedCafeId'] != s.workspace.cafeId ||
          data['expectedMembershipGeneration'] !=
              s.workspace.membershipGeneration) {
        throw _error('aborted', false);
      }
      final availabilityOnly =
          op == 'update' &&
          edits.where(data.containsKey).toList().length == 1 &&
          data.containsKey('isAvailable');
      if (!s.workspace.isOwner && !availabilityOnly) {
        throw _error('permission-denied', false);
      }
    }
  }

  void _item(Object? raw, String cafe) {
    const fields = [
      'id',
      'cafeId',
      'name',
      'category',
      'priceMinor',
      'currency',
      'isAvailable',
      'isArchived',
      'version',
      'createdAt',
      'updatedAt',
      'createdBy',
      'updatedBy',
    ];
    if (raw is! Map<String, dynamic> || !_keys(raw, fields, fields)) {
      throw const FormatException();
    }
    final item = MenuItem.fromMap(raw);
    if (item.cafeId != cafe ||
        item.name.replaceAll(RegExp(r'\s+'), ' ') != item.name ||
        item.category.replaceAll(RegExp(r'\s+'), ' ') != item.category) {
      throw const FormatException();
    }
  }

  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, Object> input,
  ) async {
    final operation = _routes[name],
        mutation = !['get', 'list'].contains(_routes[name]);
    _Binding? binding;
    var owned = false, sent = false;
    try {
      if (operation == null) throw _error('invalid-argument', false);
      // Detach from mutable caller maps; deterministic flat-field order binds
      // equivalent repository retries without changing canonical payload values.
      final names = input.keys.toList()..sort();
      final data = <String, Object>{for (final key in names) key: input[key]!};
      final body = jsonEncode(data);
      final bindings = _scopes[sessionScope] ??= <String, _Binding>{};
      // A scope outlives identity transitions; the original binding must be
      // visible even after logout so a local rejection cannot erase uncertainty.
      final bindingKey = jsonEncode([projectId, data['idempotencyKey']]);
      if (mutation) binding = bindings[bindingKey];
      final s = _capture();
      _request(operation, data, s);
      if (binding != null &&
          (!binding.session.matches(s) ||
              binding.body != body ||
              binding.operation != operation)) {
        throw _error('already-exists', false);
      }
      if (mutation) {
        if (binding == null && bindings.length >= 1024) {
          throw _error('resource-exhausted', false);
        }
        binding ??= _Binding(s, body, operation);
        bindings[bindingKey] = binding;
        if (binding.busy) throw _error('request-in-flight', true);
        binding.busy = true;
        owned = true;
      }
      String? expectedId;
      if (operation == 'create') {
        final hash = sha256(
          '${s.uid}\u0000${s.workspace.cafeId}\u0000${data['idempotencyKey']}',
        );
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
          throw _error('invalid-configuration', false);
        }
        expectedId = 'menu_$hash';
      }
      final result = await _call(
        '/menu/$operation',
        data,
        s,
        mutation,
        onDispatch: () {
          sent = true;
        },
      );
      if (operation == 'get') {
        if (!_keys(result, ['item'], ['item'])) throw const FormatException();
        _item(result['item'], s.workspace.cafeId);
        if ((result['item'] as Map)['id'] != data['itemId']) {
          throw const FormatException();
        }
      } else if (operation == 'list') {
        const fields = ['cafeId', 'items', 'nextCursor'];
        if (!_keys(result, fields, fields) ||
            result['cafeId'] != s.workspace.cafeId ||
            result['items'] is! List) {
          throw const FormatException();
        }
        final rows = result['items'] as List,
            limit = data['limit'] as int? ?? 20;
        if (rows.length > limit) throw const FormatException();
        var previous = data['cursor'] as String?;
        for (final row in rows) {
          _item(row, s.workspace.cafeId);
          final id = (row as Map)['id'] as String;
          if ((previous != null && _compareId(id, previous) <= 0) ||
              (data['includeArchived'] != true && row['isArchived'] == true)) {
            throw const FormatException();
          }
          previous = id;
        }
        final cursor = result['nextCursor'];
        if (cursor != null &&
            (!MenuItem.validId(cursor) ||
                rows.length != limit ||
                cursor != previous)) {
          throw const FormatException();
        }
      } else {
        const fields = ['cafeId', 'itemId', 'version', 'changed'];
        final version = operation == 'create'
            ? 1
            : (data['expectedVersion'] as int) + 1;
        if (!_keys(result, fields, fields) ||
            result['cafeId'] != s.workspace.cafeId ||
            result['itemId'] != (expectedId ?? data['itemId']) ||
            !MenuItem.validVersion(result['version']) ||
            result['version'] != version ||
            result['changed'] is! bool) {
          throw const FormatException();
        }
      }
      _check(s, mutation);
      return result;
    } catch (e) {
      final code = e is MenuHttpsException
          ? e.code
          : e is FormatException
          ? 'invalid-response'
          : 'unavailable';
      final unknown =
          binding?.uncertain == true ||
          (e is MenuHttpsException ? e.outcomeUnknown : mutation && sent);
      if (owned && unknown) binding!.uncertain = true;
      throw _error(code, unknown);
    } finally {
      if (owned) binding!.busy = false;
    }
  }

  Future<Map<String, dynamic>> _call(
    String path,
    Map<String, Object> data,
    MenuHttpsSession s,
    bool mutation, {
    required void Function() onDispatch,
  }) async {
    var active = true, changed = false, sent = false;
    StreamSubscription<MenuHttpsSession?>? identities;
    StreamSubscription<List<int>>? reader;
    MenuHttpsException? failure;
    Map<String, dynamic>? result;
    void check() {
      if (!active || changed) throw _error('session-changed', mutation && sent);
      _check(s, mutation && sent);
    }

    Future<Map<String, dynamic>> perform() async {
      identities = sessionChanges.listen(
        (value) {
          if (!s.matches(value)) changed = true;
        },
        onError: (Object _) {
          changed = true;
        },
        onDone: () {
          changed = true;
        },
      );
      check();
      final token = await idToken(s);
      check();
      if (token == null ||
          !RegExp(r'^[A-Za-z0-9_.-]{1,8192}$').hasMatch(token)) {
        throw _error('unauthenticated', false);
      }
      final body = jsonEncode(data);
      if (utf8.encode(body).length > 2048) {
        throw _error('invalid-argument', false);
      }
      final request = http.Request('POST', endpoint.resolve(path))
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers.addAll({
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        })
        ..body = body;
      check();
      sent = true;
      onDispatch();
      final response = await client.send(request);
      if (!active) {
        await Future<void>.sync(
          () => response.stream.listen(null, onError: (Object _) {}).cancel(),
        ).timeout(cleanupTimeout);
        check();
      }
      final bytes = <int>[], done = Completer<void>();
      unawaited(done.future.then<void>((_) {}, onError: (Object _) {}));
      reader = response.stream.listen(
        (chunk) {
          if (done.isCompleted) return;
          try {
            check();
            if (bytes.length + chunk.length > maxResponseBytes) {
              throw const FormatException();
            }
            bytes.addAll(chunk);
          } catch (e, stack) {
            done.completeError(e, stack);
          }
        },
        onError: (Object e, StackTrace stack) {
          if (!done.isCompleted) done.completeError(e, stack);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw _error('redirect-rejected', mutation);
      }
      if ((response.contentLength ?? 0) > maxResponseBytes ||
          !RegExp(
            r'^application/json(?:\s*;\s*charset=utf-8)?$',
            caseSensitive: false,
          ).hasMatch(response.headers['content-type'] ?? '')) {
        throw const FormatException();
      }
      await done.future;
      check();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      if (response.statusCode != 200) {
        const statuses = {
          'unauthenticated': 401,
          'permission-denied': 403,
          'invalid-argument': 400,
          'already-exists': 409,
          'failed-precondition': 409,
          'aborted': 409,
          'not-found': 404,
          'resource-exhausted': 429,
          'deadline-exceeded': 408,
          'too-large': 413,
        };
        final code = decoded['error'];
        if (code is String &&
            statuses[code] == response.statusCode &&
            decoded.length == 1) {
          throw _error(code, false);
        }
        throw _error('unavailable', mutation);
      }
      return decoded;
    }

    try {
      result = await perform().timeout(timeout);
    } catch (e) {
      failure = e is MenuHttpsException
          ? e
          : _error(
              e is TimeoutException
                  ? 'deadline-exceeded'
                  : e is FormatException
                  ? 'invalid-response'
                  : 'unavailable',
              mutation && sent,
            );
    }
    active = false;
    Future<bool> cancel(FutureOr<void> Function() action) => Future<void>.sync(
      action,
    ).then((_) => true, onError: (Object _) => false);
    var cleaned = false;
    try {
      cleaned = (await Future.wait([
        cancel(() => reader?.cancel()),
        cancel(() => identities?.cancel()),
      ]).timeout(cleanupTimeout)).every((ok) => ok);
    } catch (_) {
      /* bounded, sanitized cleanup */
    }
    if (failure == null) {
      if (!cleaned) {
        failure = _error('cleanup-failed', mutation && sent);
      } else {
        active = true;
        try {
          check();
        } catch (_) {
          failure = _error('session-changed', mutation && sent);
        }
        active = false;
      }
    }
    if (failure != null) throw failure;
    return result!;
  }
}
