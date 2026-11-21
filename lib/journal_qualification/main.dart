import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/cafe_workspace.dart';
import '../services/android_pilot_policy.dart';
import '../services/android_sqlite_journal_engine.dart';
import '../services/mutation_recovery_service.dart';
import '../services/offline_verified_workspace_inventory.dart';
import '../services/platform_journal_store.dart';
import '../services/workspace_inventory_https_transport.dart';
import '../services/workspace_inventory_stock_service.dart';
import '../services/workspace_session.dart';

const _project = AndroidSqliteJournalEngine.projectId;
const _uid = 'synthetic-journal-owner';
const _cafe = 'synthetic-journal-cafe';
const _operation = 'adjust-stock';
const _key = 'synthetic-stock-restart-0001';
const _email = 'synthetic@example.invalid';
const _channel = MethodChannel('velora/journal_qualification');
const _request = WorkspaceInventoryStockRequest(
  idempotencyKey: _key,
  itemId: 'synthetic-item',
  direction: StockDirection.stockOut,
  quantity: 2,
  expectedVersion: 1,
);
const _result = <String, Object>{
  'cafeId': _cafe,
  'itemId': 'synthetic-item',
  'direction': 'out',
  'quantity': 2,
  'resultingQuantity': 3,
  'version': 2,
  'adjusted': true,
};

void main() => runApp(const MaterialApp(home: _QualificationPage()));

class _QualificationPage extends StatefulWidget {
  const _QualificationPage();

  @override
  State<_QualificationPage> createState() => _QualificationPageState();
}

class _QualificationPageState extends State<_QualificationPage> {
  bool _busy = false;
  String _status = 'Ready. Prepare once, then stop and relaunch this app.';

  Future<void> _run({required bool recover}) async {
    if (_busy) return;
    setState(() => _busy = true);
    String status;
    try {
      status = await _qualify(recover: recover);
    } catch (_) {
      status =
          'STOP. Qualification failed or evidence is incomplete. '
          'Do not repeat preparation or clear app storage.';
    }
    if (!mounted) return;
    setState(() {
      _status = status;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Offline journal qualification')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Current process: $pid'),
          const SizedBox(height: 16),
          SelectableText(_status),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : () => _run(recover: false),
            child: const Text('Prepare synthetic stock adjustment'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _busy ? null : () => _run(recover: true),
            child: const Text('Recover after process restart'),
          ),
        ],
      ),
    ),
  );
}

Future<String> _qualify({required bool recover}) async {
  if (!Platform.isAndroid) throw StateError('Android is required.');
  final directory = await _channel.invokeMethod<String>('receiptDirectory');
  if (directory == null || directory.isEmpty) {
    throw StateError('Storage unavailable.');
  }
  final receipt = File('$directory/synthetic-stock-receipt.json');
  final workspace = WorkspaceSession.fromVerified(
    const CafeWorkspace(
      cafeId: _cafe,
      uid: _uid,
      ownerUid: _uid,
      role: CafeRole.owner,
    ),
  );
  final store = PlatformJournalStore(
    engine: AndroidSqliteJournalEngine(workspace: workspace),
    sha256: _syntheticDigest,
  );
  final journal = MutationRecoveryJournal(
    store.mutations,
    sha256: _syntheticDigest,
  );
  final pending = await journal.load(_project, _uid, _operation, _key);
  final expectedRequest = {
    ..._request.toCallableData(),
    ...workspace.mutationData,
  };

  int? preparedPid;
  if (recover) {
    final saved = jsonDecode(await receipt.readAsString());
    if (saved is! Map<String, dynamic> ||
        saved['pid'] is! int ||
        saved['pid'] == pid ||
        saved['dispatches'] != 1 ||
        saved['request'] is! Map<String, dynamic> ||
        !mapEquals(saved['request'] as Map<String, dynamic>, expectedRequest) ||
        pending == null ||
        pending.stableKey != _key ||
        pending.state != 'unknown' ||
        !pending.everUncertain ||
        !mapEquals(pending.request, expectedRequest)) {
      throw StateError('Restart evidence mismatch.');
    }
    preparedPid = saved['pid'] as int;
  } else if (pending != null || await receipt.exists()) {
    throw StateError('Preparation has already started.');
  }

  var mutationDispatches = 0;
  var observations = 0;
  final composition = OfflineVerifiedWorkspaceInventory(
    auth: _SyntheticAuth(),
    projectId: _project,
    policy: AndroidPilotPolicy.parse(
      const {},
      isWeb: false,
      platform: TargetPlatform.android,
    ),
    journal: journal,
    respond: (request) async {
      final body = jsonDecode(request.body);
      if (body is! Map<String, dynamic>) {
        throw StateError('Unexpected payload.');
      }
      if (request.url.path == '/inventory/adjust-stock' && !recover) {
        mutationDispatches++;
        if (mutationDispatches != 1 || !mapEquals(body, expectedRequest)) {
          throw StateError('Unexpected mutation.');
        }
        // Separate synthetic receipt evidence, with an exclusive one-shot fence.
        // This file never contains request headers or credentials.
        await receipt.create(exclusive: true);
        await receipt.writeAsString(
          jsonEncode({'pid': pid, 'dispatches': 1, 'request': body}),
          flush: true,
        );
        throw http.ClientException('Synthetic acknowledgement lost.');
      }
      if (request.url.path != '/inventory/reconcile' ||
          !recover ||
          body['operation'] != _operation ||
          body['request'] is! Map<String, dynamic> ||
          !mapEquals(
            body['request'] as Map<String, dynamic>,
            expectedRequest,
          ) ||
          ++observations > 2) {
        throw StateError('Unexpected observation.');
      }
      return http.Response(
        jsonEncode(
          observations == 1
              ? {'state': 'unknown'}
              : {'state': 'committed', 'result': _result},
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    },
  );
  try {
    await Future<void>.delayed(Duration.zero);
    if (!composition.bindVerifiedWorkspace(
      workspace,
      expectedRevision: composition.revision,
    )) {
      throw StateError('Synthetic workspace binding failed.');
    }
    final transport = composition.transportForWorkspace(workspace);
    if (!recover) {
      try {
        await transport.adjustStock(_request);
        throw StateError('Expected an uncertain outcome.');
      } on InventoryHttpsStockException catch (error) {
        if (!error.outcomeUnknown || mutationDispatches != 1) rethrow;
      }
      final saved = await journal.load(_project, _uid, _operation, _key);
      if (saved?.state != 'unknown' ||
          saved?.stableKey != _key ||
          !await receipt.exists()) {
        throw StateError('Uncertain evidence was not persisted.');
      }
      return 'PREPARED. Process $pid. One synthetic mutation dispatch. '
          'Original operation is unresolved. Stop the app process and relaunch.';
    }

    final first = await transport.reconcile(pending!);
    final unresolved = await journal.load(_project, _uid, _operation, _key);
    if (first.committed || unresolved?.state != 'unknown') {
      throw StateError('Unknown receipt changed the journal.');
    }
    final second = await transport.reconcile(unresolved!);
    final terminal = await journal.load(_project, _uid, _operation, _key);
    if (!second.committed ||
        terminal?.state != 'acknowledged' ||
        terminal?.stableKey != _key ||
        mutationDispatches != 0 ||
        observations != 2) {
      throw StateError('Recovery result mismatch.');
    }
    return 'RECOVERED. Processes $preparedPid → $pid. '
        'One original synthetic mutation and movement. Two read-only observations. '
        'Zero mutation dispatches during recovery.';
  } finally {
    workspace.invalidate();
    await composition.close();
  }
}

// Deterministic fixture digest for this isolated APK. Production hashing and
// collision resistance are outside this qualification.
String _syntheticDigest(String value) {
  var hash = 2166136261;
  for (final byte in utf8.encode(value)) {
    hash = ((hash ^ byte) * 16777619) & 0xffffffff;
  }
  return List.filled(8, hash.toRadixString(16).padLeft(8, '0')).join();
}

class _SyntheticAuth implements FirebaseAuth {
  @override
  final FirebaseApp app = _SyntheticApp();

  @override
  final User currentUser = _SyntheticUser();

  @override
  Stream<User?> authStateChanges() => Stream<User?>.multi((events) {
    events.add(currentUser);
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SyntheticApp implements FirebaseApp {
  @override
  FirebaseOptions get options => const FirebaseOptions(
    apiKey: 'synthetic',
    appId: 'synthetic',
    messagingSenderId: 'synthetic',
    projectId: _project,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SyntheticUser implements User {
  @override
  String get uid => _uid;
  @override
  String get email => _email;
  @override
  bool get emailVerified => true;

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    String segment(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final header = segment({'alg': 'RS256', 'kid': 'synthetic'});
    final claims = segment({
      'sub': uid,
      'aud': _project,
      'iss': 'https://securetoken.google.com/$_project',
      'email': email,
      'email_verified': true,
      'exp': now + 300,
      'iat': now,
      'auth_time': now,
    });
    return '$header.$claims.c3ludGhldGlj';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
