import 'dart:async';
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
const _channel = MethodChannel('velora/journal_diagnostic');

/// The UI exposes only these fixed codes and sequence numbers.
enum DiagnosticStage {
  directory('DIRECTORY'),
  attempt('ATTEMPT'),
  sqliteSnapshot('SQLITE_SNAPSHOT'),
  nativeSnapshot('NATIVE_SNAPSHOT'),
  freshState('FRESH_STATE'),
  sessionBind('SESSION_BIND'),
  mutation('MUTATION'),
  journalPrepare('JOURNAL_PREPARE'),
  dispatchMarker('DISPATCH_MARKER'),
  handlerEntry('HANDLER_ENTRY'),
  receiptCreate('RECEIPT_CREATE'),
  receiptFlush('RECEIPT_FLUSH'),
  journalFinish('JOURNAL_FINISH'),
  finalVerify('FINAL_VERIFY'),
  close('CLOSE');

  final String code;
  const DiagnosticStage(this.code);
}

enum DiagnosticFailure {
  unavailable('UNAVAILABLE'),
  rejected('REJECTED'),
  timeout('TIMEOUT'),
  outcomeUncertain('OUTCOME_UNCERTAIN');

  final String code;
  const DiagnosticFailure(this.code);
}

final class DiagnosticTrace extends ChangeNotifier {
  final _events = <String>[];
  bool _closed = false;
  bool _failed = false;
  bool get failed => _failed;
  List<String> get events => List.unmodifiable(_events);

  void _record(DiagnosticStage stage, String outcome) {
    _events.add('${_events.length + 1} ${stage.code} $outcome');
    if (!_closed) notifyListeners();
  }

  Future<T> stage<T>(
    DiagnosticStage stage,
    Future<T> Function() action, {
    DiagnosticFailure failure = DiagnosticFailure.unavailable,
  }) async {
    _record(stage, 'ENTER');
    try {
      final result = await action();
      _record(stage, 'OK');
      return result;
    } catch (error) {
      _failed = true;
      final category = switch (error) {
        TimeoutException() => DiagnosticFailure.timeout,
        _Rejected() => DiagnosticFailure.rejected,
        InventoryHttpsStockException(outcomeUnknown: true) =>
          DiagnosticFailure.outcomeUncertain,
        _ => failure,
      };
      _record(stage, 'FAIL ${category.code}');
      rethrow;
    }
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}

final class _Rejected implements Exception {
  const _Rejected();
}

final class _TracedChannel extends MethodChannel {
  final DiagnosticTrace trace;
  _TracedChannel(this.trace) : super(AndroidSqliteJournalEngine.channelName);

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      method == 'snapshot'
      ? trace.stage(
          DiagnosticStage.nativeSnapshot,
          () => super.invokeMethod<T>(method, arguments),
        )
      : super.invokeMethod<T>(method, arguments);
}

final class _TracedPersistence implements MutationJournalPersistence {
  final MutationJournalPersistence delegate;
  final DiagnosticTrace trace;
  _TracedPersistence(this.delegate, this.trace);

  @override
  Future<Object?> read(String key) => delegate.read(key);

  @override
  Future<bool> compareAndSet(
    String key,
    int? revision,
    Map<String, Object> value,
  ) => trace.stage(
    switch (value['state']) {
      'prepared' => DiagnosticStage.journalPrepare,
      'dispatched' => DiagnosticStage.dispatchMarker,
      _ => DiagnosticStage.journalFinish,
    },
    () async {
      if (!await delegate.compareAndSet(key, revision, value)) {
        throw const _Rejected();
      }
      return true;
    },
    failure: DiagnosticFailure.outcomeUncertain,
  );
}

/// Runs Prepare once. The marker is claimed before even opening the database.
final class JournalDiagnostic {
  final DiagnosticTrace trace;
  final Future<Directory> Function() directory;
  final MutationJournalPersistence Function(WorkspaceSession) persistence;
  final FirebaseAuth auth;
  bool _attempted = false;

  JournalDiagnostic({
    required this.trace,
    required this.directory,
    required this.persistence,
    required this.auth,
  });

  bool get attempted => _attempted;

  File _marker(Directory root) => File('${root.path}/prepare-attempt-v1');

  Future<Directory> _directory() => trace.stage(
    DiagnosticStage.directory,
    () => directory().timeout(const Duration(seconds: 3)),
  );

  Future<bool> canPrepare() async {
    if (_attempted) return false;
    try {
      final root = await _directory();
      return !_attempted &&
          await FileSystemEntity.type(_marker(root).path, followLinks: false) ==
              FileSystemEntityType.notFound;
    } catch (_) {
      return false;
    }
  }

  Future<bool> prepare() async {
    if (_attempted) return false;
    _attempted = true;
    try {
      await _prepare();
      return !trace.failed;
    } catch (_) {
      return false;
    }
  }

  Future<void> _prepare() async {
    final root = await _directory();
    final marker = _marker(root);
    await trace.stage(DiagnosticStage.attempt, () async {
      if (await marker.exists()) throw const _Rejected();
      await marker.create(exclusive: true);
      await marker.writeAsString('claimed-v1', flush: true);
    });

    final receipt = File('${root.path}/synthetic-stock-receipt.json');
    final workspace = WorkspaceSession.fromVerified(
      const CafeWorkspace(
        cafeId: _cafe,
        uid: _uid,
        ownerUid: _uid,
        role: CafeRole.owner,
      ),
    );
    final journal = MutationRecoveryJournal(
      _TracedPersistence(persistence(workspace), trace),
      sha256: _syntheticDigest,
    );
    final pending = await trace.stage(
      DiagnosticStage.sqliteSnapshot,
      () => journal.load(_project, _uid, _operation, _key),
    );
    await trace.stage(DiagnosticStage.freshState, () async {
      if (pending != null || await receipt.exists()) throw const _Rejected();
    });

    final request = WorkspaceInventoryStockRequest(
      idempotencyKey: _key,
      itemId: 'synthetic-item',
      direction: StockDirection.stockOut,
      quantity: 2,
      expectedVersion: 1,
    );
    final expected = {...request.toCallableData(), ...workspace.mutationData};
    final savedReceipt = jsonEncode({
      'pid': pid,
      'dispatches': 1,
      'request': expected,
    });
    var dispatches = 0;
    var receiptFlushed = false;
    OfflineVerifiedWorkspaceInventory? inventory;
    try {
      final transport = await trace.stage(
        DiagnosticStage.sessionBind,
        () async {
          final bound = inventory = OfflineVerifiedWorkspaceInventory(
            auth: auth,
            projectId: _project,
            policy: AndroidPilotPolicy.parse(
              const {},
              isWeb: false,
              platform: TargetPlatform.android,
            ),
            journal: journal,
            respond: (request) async {
              await trace.stage(DiagnosticStage.handlerEntry, () async {
                dispatches++;
                final body = jsonDecode(request.body);
                if (request.url.path != '/inventory/adjust-stock' ||
                    dispatches != 1 ||
                    body is! Map<String, dynamic> ||
                    !mapEquals(body, expected)) {
                  throw const _Rejected();
                }
              });
              await trace.stage(
                DiagnosticStage.receiptCreate,
                () => receipt.create(exclusive: true),
                failure: DiagnosticFailure.outcomeUncertain,
              );
              await trace.stage(
                DiagnosticStage.receiptFlush,
                () => receipt.writeAsString(savedReceipt, flush: true),
                failure: DiagnosticFailure.outcomeUncertain,
              );
              receiptFlushed = true;
              throw http.ClientException('Synthetic acknowledgement lost.');
            },
          );
          await Future<void>.delayed(Duration.zero);
          if (!bound.bindVerifiedWorkspace(
            workspace,
            expectedRevision: bound.revision,
          )) {
            throw const _Rejected();
          }
          return bound.transportForWorkspace(workspace);
        },
      );

      await trace.stage(DiagnosticStage.mutation, () async {
        try {
          await transport.adjustStock(request);
        } on InventoryHttpsStockException catch (error) {
          if (error.outcomeUnknown && dispatches == 1 && receiptFlushed) return;
          rethrow;
        }
        throw const _Rejected();
      });

      await trace.stage(DiagnosticStage.finalVerify, () async {
        final saved = await journal.load(_project, _uid, _operation, _key);
        if (saved == null ||
            saved.state != 'unknown' ||
            !saved.everUncertain ||
            saved.stableKey != _key ||
            !mapEquals(saved.request, expected) ||
            await receipt.readAsString() != savedReceipt) {
          throw const _Rejected();
        }
      }, failure: DiagnosticFailure.outcomeUncertain);
    } finally {
      workspace.invalidate();
      final bound = inventory;
      if (bound != null) {
        await trace.stage(DiagnosticStage.close, bound.close);
      }
    }
  }
}

void main() => runApp(const MaterialApp(home: _DiagnosticPage()));

class _DiagnosticPage extends StatefulWidget {
  const _DiagnosticPage();

  @override
  State<_DiagnosticPage> createState() => _DiagnosticPageState();
}

class _DiagnosticPageState extends State<_DiagnosticPage> {
  final _trace = DiagnosticTrace();
  late final _diagnostic = JournalDiagnostic(
    trace: _trace,
    auth: _SyntheticAuth(),
    directory: () async {
      if (!Platform.isAndroid) throw const _Rejected();
      final path = await _channel.invokeMethod<String>('receiptDirectory');
      if (path == null || path.isEmpty) throw const _Rejected();
      return Directory(path);
    },
    persistence: (workspace) => PlatformJournalStore(
      engine: AndroidSqliteJournalEngine(
        workspace: workspace,
        channel: _TracedChannel(_trace),
      ),
      sha256: _syntheticDigest,
    ).mutations,
  );
  String _status = 'Checking diagnostic attempt marker…';
  bool _available = false;

  @override
  void initState() {
    super.initState();
    unawaited(_checkAttempt());
  }

  Future<void> _checkAttempt() async {
    final available = await _diagnostic.canPrepare();
    if (!mounted) return;
    setState(() {
      _available = available;
      _status = available
          ? 'Ready for one diagnostic Prepare.'
          : 'STOP. A prior attempt exists or storage is unavailable.';
    });
  }

  Future<void> _run() async {
    if (!_available || _diagnostic.attempted) return;
    setState(() {
      _available = false;
      _status = 'Prepare running…';
    });
    final prepared = await _diagnostic.prepare();
    if (!mounted) return;
    setState(() {
      _status = prepared
          ? 'Prepare completed. Unresolved journal and receipt verified.'
          : 'STOP. Preserve diagnostic storage and record the trace.';
    });
  }

  @override
  void dispose() {
    _trace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Offline journal diagnostic')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Process: $pid'),
          const SizedBox(height: 12),
          Text(_status),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _available ? _run : null,
            child: const Text('Prepare once'),
          ),
          ListenableBuilder(
            listenable: _trace,
            builder: (context, _) => SelectableText(_trace.events.join('\n')),
          ),
        ],
      ),
    ),
  );
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
