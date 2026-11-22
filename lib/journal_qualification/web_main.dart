// This isolated qualification target uses the installed SDK's browser APIs.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'package:web/web.dart' as web;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../models/cafe_workspace.dart';
import '../services/android_pilot_policy.dart';
import '../services/mutation_recovery_service.dart';
import '../services/platform_journal_store.dart';
import '../services/workspace_inventory_https_transport.dart';
import '../services/workspace_inventory_stock_service.dart';
import '../services/workspace_session.dart';
import 'indexed_db_journal_engine.dart';

/// One isolated, synthetic Stock Out fixture. Nothing here initializes a
/// Firebase app or constructs an HTTP client capable of sending live requests.
final class ChromeRecoveryQualification {
  static const project = 'velora-spark-test';
  static const uid = 'synthetic-chrome-owner';
  static const cafe = 'synthetic-chrome-cafe';
  static const generation = 7;
  static const operation = 'adjust-stock';
  static const key = 'synthetic-chrome-stock-out-0001';
  static const receiptKey = 'synthetic-stock-out-attempt';
  final request = WorkspaceInventoryStockRequest(
    idempotencyKey: key,
    itemId: 'synthetic-item',
    direction: StockDirection.stockOut,
    quantity: 2,
    expectedVersion: 1,
  );
  static const _result = <String, Object>{
    'cafeId': cafe,
    'itemId': 'synthetic-item',
    'direction': 'out',
    'quantity': 2,
    'resultingQuantity': 3,
    'version': 2,
    'adjusted': true,
  };
  static const _bearer = 'synthetic.chrome.fixture';
  static final _endpoint = Uri.https('inventory.offline.invalid');

  final IndexedDbJournalEngine _engine;
  final IndexedDbJournalEngine _receipts;
  final WorkspaceSession workspace;
  final _changes = StreamController<InventoryHttpsSession?>.broadcast();
  late final MutationRecoveryJournal journal;
  late final HttpsWorkspaceInventory transport;
  late final MockClient _client;
  bool _prepared = false;
  bool _simulateCommit = true;
  void Function()? _onDispatch;
  int mutationRequests = 0;
  int observationRequests = 0;

  ChromeRecoveryQualification._(
    this._engine,
    this._receipts,
    InventoryHttpsSession session,
    Future<String?> Function(InventoryHttpsSession)? token,
  ) : workspace = session.workspace {
    final store = PlatformJournalStore(engine: _engine, sha256: _fixtureDigest);
    journal = MutationRecoveryJournal(store.mutations, sha256: _fixtureDigest);
    _client = MockClient(_respond);
    transport = HttpsWorkspaceInventory(
      pilotPolicy: AndroidPilotPolicy.parse(
        const {},
        isWeb: true,
        platform: TargetPlatform.windows,
      ),
      endpoint: _endpoint,
      projectId: project,
      endpointProjectId: project,
      client: _client,
      currentSession: () => workspace.isActive ? session : null,
      sessionChanges: _changes.stream,
      idToken: token ?? (_) async => _bearer,
      journal: journal,
    );
  }

  static InventoryHttpsSession syntheticSession({
    String projectId = project,
    String user = uid,
    String cafeId = cafe,
    int membershipGeneration = generation,
  }) => InventoryHttpsSession(
    uid: user,
    projectId: projectId,
    revision: 1,
    emailVerified: true,
    workspace: WorkspaceSession.fromVerified(
      CafeWorkspace(
        uid: user,
        cafeId: cafeId,
        ownerUid: user,
        role: CafeRole.owner,
        membershipGeneration: membershipGeneration,
      ),
    ),
  );

  static Future<ChromeRecoveryQualification> open({
    String database = IndexedDbJournalEngine.databaseName,
    InventoryHttpsSession? session,
    Future<String?> Function(InventoryHttpsSession)? token,
  }) async {
    final engine = await IndexedDbJournalEngine.open(name: database);
    try {
      final receipts = await IndexedDbJournalEngine.open(
        name: database,
        store: IndexedDbJournalEngine.receiptStore,
      );
      return ChromeRecoveryQualification._(
        engine,
        receipts,
        session ?? syntheticSession(),
        token,
      );
    } catch (_) {
      engine.close();
      rethrow;
    }
  }

  Future<PendingMutationOperation?> load() =>
      journal.load(project, workspace.uid, operation, key);

  Future<void> prepare() async {
    if (await load() != null || await _receipt() != null) {
      throw const PlatformJournalFailure();
    }
    _prepared = true;
  }

  Future<void> dispatch({
    bool simulateCommit = true,
    void Function()? onDispatch,
  }) async {
    if (!_prepared) throw const PlatformJournalFailure();
    _prepared = false;
    _simulateCommit = simulateCommit;
    _onDispatch = onDispatch;
    try {
      await transport.adjustStock(request);
      throw const PlatformJournalFailure();
    } on InventoryHttpsStockException catch (error) {
      final saved = await load();
      if (!error.outcomeUnknown ||
          saved?.state != 'unknown' ||
          mutationRequests != 1 ||
          await dispatchCount() != 1) {
        rethrow;
      }
    } finally {
      _onDispatch = null;
    }
  }

  Future<MutationReceiptObservation> observe(
    PendingMutationOperation pending,
  ) => transport.reconcile(pending);

  Future<Map<String, dynamic>?> _receipt() => _receipts.transaction((tx) async {
    final raw = await tx.read(receiptKey);
    if (raw == null) return null;
    final record = jsonDecode(raw as String);
    if (record is! Map<String, dynamic> ||
        record.length != 6 ||
        record['project'] != project ||
        record['uid'] != uid ||
        record['count'] != 1 ||
        record['operation'] != operation ||
        record['request'] is! Map ||
        !['committed', 'not_committed'].contains(record['state'])) {
      throw const PlatformJournalFailure();
    }
    return record;
  });

  Future<int> dispatchCount() async => await _receipt() == null ? 0 : 1;

  Future<String?> receiptState() async =>
      (await _receipt())?['state'] as String?;

  Future<http.Response> _respond(http.Request call) async {
    if (call.url.origin != _endpoint.origin ||
        call.method != 'POST' ||
        call.headers['authorization'] != 'Bearer $_bearer') {
      throw const PlatformJournalFailure();
    }
    final data = jsonDecode(call.body);
    if (data is! Map<String, dynamic>) throw const PlatformJournalFailure();
    if (call.url.path == '/inventory/adjust-stock') {
      mutationRequests++;
      final pending = await load();
      if (pending?.state != 'dispatched' ||
          !_sameRequest(data, pending!.request)) {
        throw const PlatformJournalFailure();
      }
      _onDispatch?.call();
      await _receipts.transaction((tx) async {
        if (await tx.read(receiptKey) != null) {
          throw const PlatformJournalFailure();
        }
        await tx.put(
          receiptKey,
          jsonEncode({
            'project': project,
            'uid': uid,
            'operation': operation,
            'request': data,
            'count': 1,
            'state': _simulateCommit ? 'committed' : 'not_committed',
          }),
        );
      });
      throw http.ClientException('Synthetic acknowledgement lost.');
    }
    if (call.url.path != '/inventory/reconcile' ||
        data.length != 2 ||
        data['operation'] != operation ||
        data['request'] is! Map) {
      throw const PlatformJournalFailure();
    }
    observationRequests++;
    final receipt = await _receipt();
    if (receipt != null && !_sameRequest(receipt['request'], data['request'])) {
      throw const PlatformJournalFailure();
    }
    // The canonical observation contract intentionally has no negative proof.
    final committed = receipt?['state'] == 'committed';
    return http.Response(
      jsonEncode(
        committed
            ? {'state': 'committed', 'result': _result}
            : {'state': 'unknown'},
      ),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  static bool _sameRequest(Object? a, Object? b) =>
      mutationJournalCanonicalJson(
        operation,
        Map<String, Object>.from(a as Map),
      ) ==
      mutationJournalCanonicalJson(
        operation,
        Map<String, Object>.from(b as Map),
      );

  Future<void> close() async {
    workspace.invalidate();
    _client.close();
    _engine.close();
    _receipts.close();
    await _changes.close();
  }
}

// A deterministic fixture digest. Production hashing is outside this scope.
String _fixtureDigest(String value) {
  var hash = 0;
  for (final byte in utf8.encode(value)) {
    hash = (hash * 31 + byte) & 0x7fffffff;
  }
  return List.filled(8, hash.toRadixString(16).padLeft(8, '0')).join();
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  runApp(const MaterialApp(home: _QualificationPage()));
}

class _QualificationPage extends StatefulWidget {
  const _QualificationPage();

  @override
  State<_QualificationPage> createState() => _QualificationPageState();
}

class _QualificationPageState extends State<_QualificationPage> {
  ChromeRecoveryQualification? _fixture;
  PendingMutationOperation? _record;
  String _status = 'Open the journal to start or recover.';
  int? _dispatches;
  bool _busy = false;
  bool _prepared = false;
  bool _canPrepare = false;
  bool _commit = true;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      _prepared = false;
      _canPrepare = false;
      _status = 'Unresolved or unavailable. Preserve the original evidence.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() async {
    if (![
      'localhost',
      '127.0.0.1',
      '::1',
    ].contains(web.window.location.hostname)) {
      throw const PlatformJournalFailure();
    }
    final fixture = _fixture ??= await ChromeRecoveryQualification.open();
    _record = await fixture.load();
    _dispatches = await fixture.dispatchCount();
    _canPrepare = _record == null && _dispatches == 0;
    _status = switch (_record?.state) {
      'acknowledged' => 'Confirmed committed.',
      'prepared' => 'Prepared record recovered. Observe only.',
      'dispatched' => 'Dispatched record recovered. Observe only.',
      'unknown' => 'Unknown outcome recovered. Observe only.',
      _ =>
        _canPrepare
            ? 'Ready to prepare synthetic Stock Out.'
            : 'Unresolved or unavailable.',
    };
  }

  @override
  void dispose() {
    final fixture = _fixture;
    if (fixture != null) unawaited(fixture.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Chrome inventory recovery qualification'),
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('Synthetic TEST fixture'),
        const SizedBox(height: 12),
        Text(_status, key: const ValueKey('status')),
        if (_record case final record?) ...[
          Text('Journal state: ${record.state}, revision ${record.revision}'),
          Text('Operation: ${record.operation}, key: ${record.stableKey}'),
          Text('Payload digest: ${record.payloadDigest}'),
          Text('Request: ${jsonEncode(record.request)}'),
        ],
        if (_dispatches != null)
          Text('Synthetic mutation dispatches: $_dispatches'),
        if (_fixture case final fixture?)
          Text(
            'This page: ${fixture.mutationRequests} mutation sends, ${fixture.observationRequests} read-only observations',
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: _busy || _fixture != null ? null : () => _run(_open),
              child: const Text('Open or recover journal'),
            ),
            OutlinedButton(
              onPressed: _busy || !_canPrepare || _prepared
                  ? null
                  : () => _run(() async {
                      await _fixture!.prepare();
                      _prepared = true;
                      _status =
                          'Prepared synthetic request. Dispatch writes the journal first.';
                    }),
              child: const Text('Prepare Stock Out'),
            ),
            FilledButton(
              onPressed: _busy || !_prepared
                  ? null
                  : () => _run(() async {
                      _prepared = false;
                      _canPrepare = false;
                      await _fixture!.dispatch(
                        simulateCommit: _commit,
                        onDispatch: () {
                          if (mounted) {
                            setState(
                              () => _status = 'Dispatched synthetic Stock Out.',
                            );
                          }
                        },
                      );
                      _record = await _fixture!.load();
                      _dispatches = await _fixture!.dispatchCount();
                      _status =
                          'Unknown outcome. Reload this page, then open the journal and observe.';
                    }),
              child: const Text('Dispatch synthetic mutation'),
            ),
            OutlinedButton(
              onPressed: _busy || _record == null
                  ? null
                  : () => _run(() async {
                      final result = await _fixture!.observe(_record!);
                      _record = await _fixture!.load();
                      _dispatches = await _fixture!.dispatchCount();
                      final state = await _fixture!.receiptState();
                      _status = result.committed
                          ? 'Confirmed committed. Synthetic receipt observed.'
                          : state == 'not_committed'
                          ? 'Fixture confirms not committed. Canonical observation remains unknown.'
                          : 'Unknown outcome. Receipt evidence is insufficient.';
                    }),
              child: const Text('Observe original operation'),
            ),
          ],
        ),
        SwitchListTile(
          title: const Text('Simulate server commit'),
          value: _commit,
          onChanged: _busy || !_canPrepare
              ? null
              : (value) => setState(() => _commit = value),
        ),
      ],
    ),
  );
}
