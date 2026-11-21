// Unwired TEST tooling. No entry point, Firebase initialization, sign-in,
// fixture creation, or discovery of a default Firebase client.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/services/owner_email_verification.dart';
import 'package:velora/services/workspace_provisioning_service.dart';
import 'package:velora/services/workspace_resolver.dart';
import 'package:velora/services/workspace_store.dart';

enum QualificationCase { ownerBootstrap, staffResolver }

enum QualificationStatus {
  wrongTarget,
  wrongRules,
  invalidFixture,
  unauthorized,
  unwired,
  budgetExhausted,
  passed,
  inconclusive,
}

final class QualificationRequest {
  final QualificationCase scenario;
  final String projectId, databaseId, accountAlias, cafeAlias;
  final String? rulesSha256;
  final bool authorized;

  const QualificationRequest({
    required this.scenario,
    required this.projectId,
    required this.databaseId,
    required this.accountAlias,
    required this.cafeAlias,
    this.rulesSha256,
    this.authorized = false,
  });
}

typedef _Execution = Future<bool> Function(QualificationCase, _Budget);

final class FirestoreRuntimeQualificationRunner {
  static const projectId = 'velora-spark-test';
  static const databaseId = '(default)';
  static const rulesSha256 =
      '73844e2174c028696bf5b36f22fbc2a6e2a3f6849ad9848913135e393d173611';
  static const transactionTimeout = Duration(seconds: 10);
  static const _runTimeout = Duration(seconds: 25);

  final _Execution? _execute;
  final Duration _timeout;
  final _attempted = <QualificationCase>{};
  bool _busy = false;
  bool _halted = false;

  FirestoreRuntimeQualificationRunner()
    : _execute = null,
      _timeout = _runTimeout;

  /// Deliberate future composition only. Supply clean TEST clients and a
  /// separately approved fixture manifest. Construction does not inspect Auth.
  FirestoreRuntimeQualificationRunner.withTestClients({
    required FirebaseAuth auth,
    required FirebaseFirestore firestore,
    required String bootstrapUid,
    required CafeWorkspace expectedStaff,
  }) : _timeout = _runTimeout,
       _execute = ((scenario, budget) async {
         final authApp = auth.app;
         final dataApp = firestore.app;
         if (authApp.options.projectId != projectId ||
             dataApp.options.projectId != projectId ||
             authApp.name != dataApp.name ||
             authApp.options.appId != dataApp.options.appId ||
             firestore.databaseId != databaseId) {
           throw const _WrongTarget();
         }
         final host = firestore.settings.host;
         if (host != null && host != 'firestore.googleapis.com') {
           throw const _WrongTarget();
         }
         if (!_identifier(bootstrapUid) ||
             !_identifier(expectedStaff.uid) ||
             !_identifier(expectedStaff.cafeId) ||
             !_identifier(expectedStaff.ownerUid) ||
             expectedStaff.role != CafeRole.staff ||
             expectedStaff.uid == expectedStaff.ownerUid ||
             bootstrapUid == expectedStaff.uid ||
             expectedStaff.membershipGeneration < 0) {
           throw const _InvalidFixture();
         }
         final uid = switch (scenario) {
           QualificationCase.ownerBootstrap => bootstrapUid,
           QualificationCase.staffResolver => expectedStaff.uid,
         };
         void checkSession() {
           budget.check();
           final user = auth.currentUser;
           if (user?.uid != uid || user?.emailVerified != true) {
             throw const _InvalidFixture();
           }
         }

         checkSession();
         if (scenario == QualificationCase.ownerBootstrap) {
           final provisioner = FirebaseWorkspaceProvisioner(
             store: _BootstrapStore(
               FirestoreWorkspaceBootstrapStore(
                 firestore: firestore,
                 timeout: transactionTimeout,
                 maxAttempts: 1,
               ),
               uid,
               budget,
               checkSession,
             ),
             resolveProfile: () => authApp.options,
             activeOptions: () => dataApp.options,
             currentUid: () {
               checkSession();
               return uid;
             },
             verification: FirebaseOwnerEmailVerification(
               auth: auth,
               operationTimeout: const Duration(seconds: 5),
             ),
           );
           final outcome = await provisioner.createWorkspace(
             const WorkspaceCreationRequest(
               businessName: 'Synthetic Rules Qualification',
               businessType: 'Bakery',
               address: '',
               inventoryUnit: 'kg',
               lowStockAlerts: false,
               expiryReminders: false,
               reminderDays: 1,
             ),
           );
           checkSession();
           return outcome.created;
         }

         final store = FirestoreWorkspaceStore(
           firestore: firestore,
           timeout: transactionTimeout,
           maxAttempts: 1,
         );
         final cafe = 'cafes/${expectedStaff.cafeId}';
         final resolver = WorkspaceResolver(
           auth: auth,
           debugLog: (_) {},
           store: _ResolverStore(
             store,
             [
               'user_cafe_memberships/$uid',
               cafe,
               '$cafe/members/$uid',
               '$cafe/members/${expectedStaff.ownerUid}',
               'user_cafe_memberships/${expectedStaff.ownerUid}',
             ],
             budget,
             checkSession,
           ),
         );
         final resolved = await resolver.resolve();
         checkSession();
         return resolved.uid == uid &&
             resolved.cafeId == expectedStaff.cafeId &&
             resolved.ownerUid == expectedStaff.ownerUid &&
             resolved.role == CafeRole.staff &&
             resolved.membershipGeneration ==
                 expectedStaff.membershipGeneration;
       });

  @visibleForTesting
  FirestoreRuntimeQualificationRunner.synthetic(
    Future<bool> Function(QualificationCase) execute, {
    Duration timeout = _runTimeout,
  }) : _execute = ((scenario, _) => execute(scenario)),
       _timeout = timeout;

  /// Only fixed enum values leave this boundary. A timeout or uncertain result
  /// stops the run, and never grants permission to retry a bootstrap.
  Future<QualificationStatus> run(QualificationRequest request) async {
    if (request.projectId != projectId || request.databaseId != databaseId) {
      return QualificationStatus.wrongTarget;
    }
    if (request.rulesSha256 != rulesSha256) {
      return QualificationStatus.wrongRules;
    }
    final owner = request.scenario == QualificationCase.ownerBootstrap;
    if (request.accountAlias !=
            (owner ? 'synthetic-owner' : 'synthetic-staff') ||
        request.cafeAlias !=
            (owner ? 'synthetic-new-cafe' : 'synthetic-staff-cafe')) {
      return QualificationStatus.invalidFixture;
    }
    if (!request.authorized) return QualificationStatus.unauthorized;
    final execute = _execute;
    if (execute == null) return QualificationStatus.unwired;
    if (_busy || _halted || !_attempted.add(request.scenario)) {
      return QualificationStatus.budgetExhausted;
    }
    _busy = true;
    final budget = _Budget(_timeout);
    try {
      final passed = await execute(request.scenario, budget).timeout(_timeout);
      if (passed) return QualificationStatus.passed;
    } on _WrongTarget {
      _halted = true;
      return QualificationStatus.wrongTarget;
    } on _InvalidFixture {
      _halted = true;
      return QualificationStatus.invalidFixture;
    } catch (_) {
      // Includes native timeouts and ambiguous SDK failures. Never log errors.
    } finally {
      budget.active = false;
      _busy = false;
    }
    _halted = true;
    return QualificationStatus.inconclusive;
  }
}

bool _identifier(String value) =>
    value.isNotEmpty &&
    value.length <= 128 &&
    value.trim() == value &&
    value != '.' &&
    value != '..' &&
    !RegExp(r'[/\\\x00-\x1f\x7f-\x9f]').hasMatch(value);

final class _WrongTarget implements Exception {
  const _WrongTarget();
}

final class _InvalidFixture implements Exception {
  const _InvalidFixture();
}

final class _Budget {
  final Duration timeout;
  final _clock = Stopwatch()..start();
  bool active = true;
  bool _started = false;
  bool _attempted = false;
  _Budget(this.timeout);

  void check() {
    if (!active || _clock.elapsed >= timeout) {
      throw StateError('Budget exhausted');
    }
  }

  void begin() {
    check();
    if (_started) throw StateError('Transaction already started');
    _started = true;
  }

  void attempt() {
    check();
    if (_attempted) throw StateError('Transaction retry refused');
    _attempted = true;
  }
}

class _BoundReader implements WorkspaceReader {
  final WorkspaceReader _reader;
  final List<String> _paths;
  final void Function() _check;
  int _reads = 0;

  _BoundReader(this._reader, this._paths, this._check);

  @override
  Future<Map<String, dynamic>?> readDocument(String path) async {
    _check();
    if (_reads >= _paths.length || path != _paths[_reads]) {
      throw StateError('Read outside the qualification fixture');
    }
    _reads++;
    final document = await _reader.readDocument(path);
    _check();
    return document;
  }
}

final class _ResolverStore implements WorkspaceStore {
  final WorkspaceStore _store;
  final List<String> _paths;
  final _Budget _budget;
  final void Function() _checkSession;
  _ResolverStore(this._store, this._paths, this._budget, this._checkSession);

  @override
  Future<T> readTransaction<T>(Future<T> Function(WorkspaceReader) read) {
    _checkSession();
    _budget.begin();
    return _store.readTransaction((reader) {
      _budget.attempt();
      return read(_BoundReader(reader, _paths, _checkSession));
    });
  }
}

final class _BootstrapStore implements WorkspaceBootstrapStore {
  final WorkspaceBootstrapStore _store;
  final String _uid;
  final _Budget _budget;
  final void Function() _checkSession;
  String? _cafeId;
  _BootstrapStore(this._store, this._uid, this._budget, this._checkSession);

  @override
  String newCafeId() {
    _checkSession();
    if (_cafeId != null) throw StateError('Cafe ID already allocated');
    return _cafeId = _store.newCafeId();
  }

  @override
  Object serverTimestamp() => _store.serverTimestamp();

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(WorkspaceBootstrapTransaction) action,
  ) {
    _checkSession();
    _budget.begin();
    return _store.runTransaction((tx) async {
      _budget.attempt();
      final cafe = 'cafes/$_cafeId';
      final mapping = 'user_cafe_memberships/$_uid';
      final bounded = _BoundBootstrap(tx, mapping, [
        cafe,
        '$cafe/members/$_uid',
        mapping,
      ], _checkSession);
      final result = await action(bounded);
      _checkSession();
      if (bounded._writes != 3) throw StateError('Incomplete bootstrap');
      return result;
    });
  }
}

final class _BoundBootstrap extends _BoundReader
    implements WorkspaceBootstrapTransaction {
  final WorkspaceBootstrapTransaction _tx;
  final List<String> _writePaths;
  int _writes = 0;

  _BoundBootstrap(
    this._tx,
    String mapping,
    this._writePaths,
    void Function() check,
  ) : super(_tx, [mapping], check);

  @override
  void set(String path, Map<String, dynamic> data) {
    _check();
    if (_writes >= _writePaths.length || path != _writePaths[_writes]) {
      throw StateError('Write outside the qualification fixture');
    }
    _writes++;
    _tx.set(path, data);
  }
}
