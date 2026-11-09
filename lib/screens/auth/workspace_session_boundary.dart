import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/workspace_resolver.dart';
import '../../services/workspace_session.dart';
import '../../services/workspace_session_monitor.dart';
import '../../models/cafe_workspace.dart';
import 'workspace_gate.dart';
import 'login_page.dart';

/// Remains mounted under pushed routes, and removes the whole old route stack
/// on revocation. Workspace content waits for server-backed authority snapshots.
class WorkspaceSessionBoundary extends StatefulWidget {
  final WorkspaceSession session;
  final Widget child;
  final Stream<String?>? identities;
  final Stream<bool>? authority;

  /// Optional subscription source; aggregation and metadata checks stay here.
  final Stream<DocumentSnapshot<Map<String, dynamic>>> Function(String path)?
  authoritySnapshots;
  final Future<CafeWorkspace> Function()? resolve;
  const WorkspaceSessionBoundary({
    super.key,
    required this.session,
    required this.child,
    this.identities,
    this.authority,
    this.authoritySnapshots,
    this.resolve,
  });
  @override
  State<WorkspaceSessionBoundary> createState() => _BoundaryState();
}

class _BoundaryState extends State<WorkspaceSessionBoundary>
    with WidgetsBindingObserver {
  late WorkspaceSessionMonitor _monitor;
  bool _ready = false;
  Timer? _verificationTimeout;
  String? _identity;
  @override
  void initState() {
    super.initState();
    _identity = widget.session.uid;
    WidgetsBinding.instance.addObserver(this);
    _monitor = WorkspaceSessionMonitor(
      session: widget.session,
      resolve: widget.resolve ?? WorkspaceResolver().resolve,
      onState: (ready) {
        if (!mounted) return;
        _verificationTimeout?.cancel();
        setState(() => _ready = ready);
        if (!ready) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
              MaterialPageRoute<void>(
                builder: (_) => _identity == null
                    ? const LoginPage()
                    : const WorkspaceGate(initiallyBlocked: true),
              ),
              (_) => false,
            );
          });
        }
      },
    );
    _verificationTimeout = Timer(
      const Duration(seconds: 15),
      _monitor.invalidate,
    );
    _monitor.start(
      (widget.identities ??
              FirebaseAuth.instance.authStateChanges().map((user) => user?.uid))
          .map((uid) {
            _identity = uid;
            return uid;
          }),
      widget.authority ?? _authority(),
    );
  }

  Stream<bool> _authority() {
    final session = widget.session;
    final paths = {
      'user_cafe_memberships/${session.uid}',
      'cafes/${session.cafeId}/members/${session.uid}',
      'cafes/${session.cafeId}',
      'user_cafe_memberships/${session.ownerUid}',
      'cafes/${session.cafeId}/members/${session.ownerUid}',
    };
    final values = <String, String>{};
    final subscriptions = <StreamSubscription<dynamic>>[];
    var started = false;
    late StreamController<bool> controller;
    controller = StreamController<bool>(
      onListen: () {
        for (final path in paths) {
          subscriptions.add(
            (widget.authoritySnapshots?.call(path) ??
                    FirebaseFirestore.instance
                        .doc(path)
                        .snapshots(includeMetadataChanges: true))
                .listen(
                  (snapshot) {
                    if (controller.isClosed) return;
                    if (snapshot.metadata.isFromCache ||
                        snapshot.metadata.hasPendingWrites) {
                      if (started) controller.add(false);
                      return;
                    }
                    final data = snapshot.data();
                    final signature = jsonEncode([
                      data?['uid'],
                      data?['cafeId'],
                      data?['ownerUid'],
                      data?['role'],
                      data?['status'],
                      data?['schemaVersion'],
                      data?.containsKey('membershipGeneration'),
                      data?['membershipGeneration'],
                    ]);
                    if (started && values[path] != signature) {
                      controller.add(false);
                      return;
                    }
                    values[path] = signature;
                    if (!started && values.length == paths.length) {
                      started = true;
                      controller.add(true);
                    }
                  },
                  onError: (Object _) {
                    if (!controller.isClosed) controller.add(false);
                  },
                ),
          );
        }
      },
      onCancel: () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      },
    );
    return controller.stream;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _monitor.invalidate();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _verificationTimeout?.cancel();
    widget.session.invalidate();
    _monitor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ready
      ? widget.child
      : const Scaffold(body: Center(child: CircularProgressIndicator()));
}
