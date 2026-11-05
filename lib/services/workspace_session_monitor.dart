import 'dart:async';
import '../models/cafe_workspace.dart';
import 'workspace_session.dart';

/// One-shot episode lifetime. Invalidated monitors never adopt a new episode.
class WorkspaceSessionMonitor {
  final WorkspaceSession session;
  final Future<CafeWorkspace> Function() resolve;
  final void Function(bool ready) onState;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _closed = false;
  int _revision = 0;

  WorkspaceSessionMonitor({
    required this.session,
    required this.resolve,
    required this.onState,
  });

  void start(Stream<String?> identities, Stream<bool> authority) {
    _subscriptions.add(
      identities.listen((uid) {
        if (uid != session.uid) invalidate();
      }, onError: (Object _) => invalidate()),
    );
    _subscriptions.add(
      authority.listen((available) {
        if (!available) {
          invalidate();
          return;
        }
        verify();
      }, onError: (Object _) => invalidate()),
    );
  }

  Future<void> verify() async {
    if (_closed) return;
    final revision = ++_revision;
    try {
      final current = await resolve();
      if (_closed || revision != _revision) return;
      if (current.uid != session.uid ||
          current.cafeId != session.cafeId ||
          current.ownerUid != session.ownerUid ||
          current.role != session.role ||
          current.membershipGeneration != session.membershipGeneration) {
        invalidate();
        return;
      }
      onState(true);
    } catch (_) {
      invalidate();
    }
  }

  void invalidate() {
    if (_closed) return;
    session.invalidate();
    onState(false);
    dispose();
  }

  void dispose() {
    session.invalidate();
    _closed = true;
    _revision++;
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
  }
}
