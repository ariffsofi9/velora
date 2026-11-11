/// Injected persistence must provide atomic compare-and-set and acknowledge a
/// completed write before dispatch. No OS storage, Firebase or secrets here.
abstract interface class InvitationJournalPersistence {
  Future<Object?> read(String projectId, String uid);
  Future<bool> compareAndSet(
    String projectId,
    String uid,
    Object? expected,
    Map<String, Object> value,
  );
}

class InvitationRecoveryFailure implements Exception {
  const InvitationRecoveryFailure();
  @override
  String toString() => 'Invitation recovery unavailable.';
}

class PendingInvitationOperation {
  final String projectId, uid, requestId, expectedCafeId, state;
  final int expectedMembershipGeneration;
  const PendingInvitationOperation({
    required this.projectId,
    required this.uid,
    required this.requestId,
    required this.expectedCafeId,
    required this.expectedMembershipGeneration,
    this.state = 'pending',
  });
  Map<String, Object> toJson() => {
    'version': 1,
    'projectId': projectId,
    'uid': uid,
    'requestId': requestId,
    'expectedCafeId': expectedCafeId,
    'expectedMembershipGeneration': expectedMembershipGeneration,
    'state': state,
  };
  static PendingInvitationOperation parse(
    Object? raw,
    String project,
    String uid,
  ) {
    bool id(Object? value) =>
        value is String &&
        value.isNotEmpty &&
        value.length <= 128 &&
        value.trim() == value &&
        !['.', '..'].contains(value) &&
        !RegExp(r'[/\\\x00-\x1f]').hasMatch(value);
    if (raw is! Map ||
        raw.length != 7 ||
        raw['version'] is! int ||
        raw['version'] != 1 ||
        !['velora-spark-test', 'velora-73222'].contains(project) ||
        raw['projectId'] != project ||
        raw['uid'] != uid ||
        !id(uid) ||
        !id(raw['expectedCafeId']) ||
        raw['requestId'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9_-]{16,64}$',
        ).hasMatch(raw['requestId'] as String) ||
        raw['expectedMembershipGeneration'] is! int ||
        (raw['expectedMembershipGeneration'] as int) < 0 ||
        (raw['expectedMembershipGeneration'] as int) > 9007199254740991 ||
        raw['state'] != 'pending') {
      throw const InvitationRecoveryFailure();
    }
    return PendingInvitationOperation(
      projectId: project,
      uid: uid,
      requestId: raw['requestId'] as String,
      expectedCafeId: raw['expectedCafeId'] as String,
      expectedMembershipGeneration: raw['expectedMembershipGeneration'] as int,
      state: raw['state'] as String,
    );
  }
}

class InvitationRecoveryJournal {
  // Direct, definite responses are remembered only in this process. Durable
  // pending metadata is never cleared by a late storage write or observation.
  static final _definite = Expando<Map<String, String>>();
  final InvitationJournalPersistence persistence;
  const InvitationRecoveryJournal(this.persistence);
  String _key(PendingInvitationOperation operation) =>
      '${operation.projectId}\u0000${operation.uid}';
  Future<PendingInvitationOperation?> load(String project, String uid) async {
    try {
      if (!['velora-spark-test', 'velora-73222'].contains(project) ||
          uid.isEmpty) {
        throw const InvitationRecoveryFailure();
      }
      final raw = await persistence.read(project, uid);
      return raw == null
          ? null
          : PendingInvitationOperation.parse(raw, project, uid);
    } catch (_) {
      throw const InvitationRecoveryFailure();
    }
  }

  Future<void> prepare(PendingInvitationOperation operation) async {
    try {
      PendingInvitationOperation.parse(
        operation.toJson(),
        operation.projectId,
        operation.uid,
      );
      final raw = await persistence.read(operation.projectId, operation.uid);
      if (raw != null) {
        final previous = PendingInvitationOperation.parse(
          raw,
          operation.projectId,
          operation.uid,
        );
        if (_definite[persistence]?[_key(previous)] != previous.requestId ||
            previous.requestId == operation.requestId) {
          throw const InvitationRecoveryFailure();
        }
      }
      if (operation.state != 'pending' ||
          !await persistence.compareAndSet(
            operation.projectId,
            operation.uid,
            raw,
            operation.toJson(),
          )) {
        throw const InvitationRecoveryFailure();
      }
    } catch (_) {
      throw const InvitationRecoveryFailure();
    }
  }

  /// Only an originating definite response permits another EXPLICIT creation in
  /// this process. This never updates durable state or establishes delivery.
  /// A restarted process conservatively blocks even if the old response was seen.
  void recordDefiniteResponse(PendingInvitationOperation operation) {
    PendingInvitationOperation.parse(
      operation.toJson(),
      operation.projectId,
      operation.uid,
    );
    final known = _definite[persistence] ??= <String, String>{};
    known[_key(operation)] = operation.requestId;
  }
}

/// Observation cannot clear a pending journal or supply an invitation code.
class InvitationReceiptObservation {
  final String state;
  final String? invitationState;
  const InvitationReceiptObservation._(this.state, this.invitationState);
  static InvitationReceiptObservation parse(Object? raw) {
    if (raw is Map<String, dynamic>) {
      if (raw.length == 1 && raw['state'] == 'unknown') {
        return const InvitationReceiptObservation._('unknown', null);
      }
      if (raw.length == 2 &&
          raw['state'] == 'committed' &&
          [
            'pending',
            'revoked',
            'redeemed',
            'expired',
          ].contains(raw['invitationState'])) {
        return InvitationReceiptObservation._(
          'committed',
          raw['invitationState'] as String,
        );
      }
    }
    throw const InvitationRecoveryFailure();
  }
}
