import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../models/cafe_workspace.dart';
import '../../services/workspace_resolver.dart';
import '../../services/workspace_session.dart';
import '../business_setup/business_setup_page.dart';
import '../home/home_page.dart';
import 'workspace_session_boundary.dart';
import 'owner_email_verification_page.dart';
import '../../services/owner_email_verification.dart';
import '../../services/android_pilot_policy.dart';
import '../../services/auth_service.dart';
import '../../services/user_profile_service.dart';
import '../../services/workspace_store.dart';
import 'login_page.dart';

/// Caller-owned immutable composition. Never changes build configuration or
/// grants membership; injected SDK/store ports also support offline tests.
@immutable
final class AndroidPilotAuthDependencies {
  final AndroidPilotPolicy policy;
  final FirebaseAuth? firebaseAuth;
  final FirebaseFirestore? firestore;
  final AuthService authService;
  final WorkspaceResolver resolver;

  AndroidPilotAuthDependencies({
    required this.policy,
    this.firebaseAuth,
    this.firestore,
    WorkspaceResolver? resolver,
  }) : authService = AuthService(
         auth: firebaseAuth,
         profiles: UserProfileService(
           firestore: firestore,
           pilotPolicy: policy,
         ),
         pilotPolicy: policy,
       ),
       resolver =
           resolver ??
           WorkspaceResolver(
             auth: firebaseAuth,
             store: firestore == null
                 ? null
                 : FirestoreWorkspaceStore(firestore: firestore),
           );

  FirebaseAuth get auth => firebaseAuth ?? FirebaseAuth.instance;

  bool allows(AndroidPilotCapability capability) =>
      policy.state == AndroidPilotState.normal || policy.permits(capability);

  /// Keeps one Auth episode across both the server-profile read and canonical
  /// membership resolution. A same-UID reauthentication is a different episode.
  Future<CafeWorkspace> resolveEligibleWorkspace({
    Future<CafeWorkspace> Function()? resolve,
  }) async {
    if (!policy.isValid) {
      throw const WorkspaceResolutionException(
        WorkspaceFailure.unauthenticated,
      );
    }
    if (!policy.isRestricted) return (resolve ?? resolver.resolve)();
    final uid = auth.currentUser?.uid;
    if (uid == null) {
      throw const WorkspaceResolutionException(
        WorkspaceFailure.unauthenticated,
      );
    }
    var changed = false;
    final initial = Completer<void>();
    final subscription = auth.authStateChanges().listen(
      (user) {
        if (initial.isCompleted || user?.uid != uid) changed = true;
        if (!initial.isCompleted) initial.complete();
      },
      onError: (Object _) {
        changed = true;
        if (!initial.isCompleted) initial.complete();
      },
      onDone: () {
        changed = true;
        if (!initial.isCompleted) initial.complete();
      },
    );
    void requireCurrent() {
      if (changed ||
          auth.currentUser?.uid != uid ||
          auth.currentUser?.emailVerified != true) {
        throw const WorkspaceResolutionException(
          WorkspaceFailure.sessionChanged,
        );
      }
    }

    late CafeWorkspace workspace;
    try {
      await initial.future.timeout(const Duration(seconds: 15));
      requireCurrent();
      await authService.requirePilotProfileEligibility();
      requireCurrent();
      workspace = await (resolve ?? resolver.resolve)().timeout(
        const Duration(seconds: 15),
      );
      requireCurrent();
      if (workspace.uid != uid ||
          !policy.matchesBinding(uid: uid, cafeId: workspace.cafeId)) {
        throw const WorkspaceResolutionException(
          WorkspaceFailure.inconsistentMembership,
        );
      }
    } finally {
      await subscription.cancel();
    }
    requireCurrent();
    return workspace;
  }
}

/// Survives Navigator stack replacement. Default-constructed authentication
/// pages still borrow the same policy/services; no mutable global fallback.
class AndroidPilotAuthScope extends InheritedWidget {
  final AndroidPilotAuthDependencies dependencies;
  const AndroidPilotAuthScope({
    super.key,
    required this.dependencies,
    required super.child,
  });
  static AndroidPilotAuthDependencies? read(BuildContext context) => context
      .getInheritedWidgetOfExactType<AndroidPilotAuthScope>()
      ?.dependencies;
  @override
  bool updateShouldNotify(AndroidPilotAuthScope oldWidget) =>
      !identical(dependencies, oldWidget.dependencies);
}

class PilotAccessBlockedPage extends StatelessWidget {
  const PilotAccessBlockedPage({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(
    body: SafeArea(child: Center(child: Text('Pilot access unavailable'))),
  );
}

/// Resolves trusted membership before exposing any workspace-backed home UI.
class WorkspaceGate extends StatefulWidget {
  final AndroidPilotAuthDependencies? pilot;
  final WorkspaceResolver? resolver;
  final Widget Function(BuildContext context, WorkspaceSession session)?
  homeBuilder;
  final WidgetBuilder? setupBuilder;
  final bool initiallyBlocked;
  final OwnerEmailVerification? ownerVerification;

  const WorkspaceGate({
    super.key,
    this.pilot,
    this.resolver,
    this.homeBuilder,
    this.setupBuilder,
    this.initiallyBlocked = false,
    this.ownerVerification,
  });

  @override
  State<WorkspaceGate> createState() => _WorkspaceGateState();
}

class _WorkspaceGateState extends State<WorkspaceGate> {
  AndroidPilotAuthDependencies? get _pilot =>
      widget.pilot ?? AndroidPilotAuthScope.read(context);
  int _revision = 0;
  bool _resolving = false;
  WorkspaceResolutionException? _failure;
  bool _loading = true;
  bool _routing = false;

  @override
  void initState() {
    super.initState();
    if (widget.initiallyBlocked) {
      _loading = false;
      _failure = const WorkspaceResolutionException(
        WorkspaceFailure.sessionChanged,
      );
    } else {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    if (_routing || _resolving) return;
    _resolving = true;
    final revision = ++_revision;
    final pilot = _pilot;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final workspace = await (pilot != null
          ? pilot.resolveEligibleWorkspace()
          : (widget.resolver ?? WorkspaceResolver()).resolve());
      if (!mounted || revision != _revision || !identical(pilot, _pilot)) {
        return;
      }
      if (pilot != null && ModalRoute.of(context)?.isCurrent == false) return;
      final session = WorkspaceSession.fromVerified(workspace);
      _replace((context) {
        final child =
            widget.homeBuilder?.call(context, session) ??
            HomePage(workspaceSession: session);
        return pilot != null ||
                (widget.homeBuilder == null && widget.resolver == null)
            ? WorkspaceSessionBoundary(
                session: session,
                pilot: pilot,
                child: child,
              )
            : child;
      }, '/workspace-home');
    } on WorkspaceResolutionException catch (error) {
      if (!mounted || revision != _revision) return;
      if ((pilot == null ||
              !pilot.policy.isRestricted && pilot.policy.isValid) &&
          error.failure == WorkspaceFailure.missingMembership) {
        _replace(widget.setupBuilder ?? _ownerSetup, '/business-setup');
        return;
      }
      setState(() {
        _loading = false;
        _failure = error;
      });
    } catch (_) {
      if (!mounted || revision != _revision) return;
      setState(() {
        _loading = false;
        _failure = const WorkspaceResolutionException(
          WorkspaceFailure.unavailable,
        );
      });
    } finally {
      if (mounted && revision == _revision) _resolving = false;
    }
  }

  Future<void> _logout() async {
    final pilot = _pilot;
    if (pilot == null || _routing) return;
    _revision++;
    _routing = true;
    try {
      await pilot.authService.signOut();
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              LoginPage(pilot: pilot),
        ),
        (_) => false,
      );
    } catch (_) {
      if (mounted) setState(() => _routing = false);
    }
  }

  @override
  void didUpdateWidget(covariant WorkspaceGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.pilot, widget.pilot) ||
        !identical(oldWidget.resolver, widget.resolver)) {
      _revision++;
      _resolving = false;
      if (!_routing) _resolve();
    }
  }

  @override
  void dispose() {
    _revision++;
    super.dispose();
  }

  Widget _ownerSetup(BuildContext context) {
    // Route builders can outlive the originating State. Capture from the
    // destination context, never from a disposed Gate's context getter.
    final pilot = widget.pilot ?? AndroidPilotAuthScope.read(context);
    if (pilot != null && !pilot.allows(AndroidPilotCapability.businessSetup)) {
      return const PilotAccessBlockedPage();
    }
    final verification =
        widget.ownerVerification ?? FirebaseOwnerEmailVerification();
    return OwnerEmailVerificationPage(
      verification: verification,
      verifiedBuilder: (_) => WorkspaceGate(
        pilot: pilot,
        resolver: widget.resolver,
        homeBuilder: widget.homeBuilder,
        setupBuilder: (_) => BusinessSetupPage(verification: verification),
      ),
    );
  }

  void _replace(WidgetBuilder builder, String name) {
    _routing = true;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: builder,
        settings: RouteSettings(name: name),
      ),
    );
  }

  String get _title => switch (_failure?.failure) {
    WorkspaceFailure.inconsistentMembership => 'Workspace access not verified',
    WorkspaceFailure.sessionChanged ||
    WorkspaceFailure.unauthenticated => 'Session could not be verified',
    _ => 'Workspace unavailable',
  };

  String get _message => switch (_failure?.failure) {
    WorkspaceFailure.inconsistentMembership =>
      'Your workspace membership is incomplete or inconsistent. Please contact your business owner or support.',
    WorkspaceFailure.sessionChanged || WorkspaceFailure.unauthenticated =>
      'Your sign-in session changed while Velora was checking access. Please sign in again or retry.',
    _ =>
      'Velora could not securely verify your workspace. Check your connection and try again.',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _loading
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: AppColors.primary),
                      SizedBox(height: 18),
                      Text(
                        'Verifying your workspace…',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: const BoxDecoration(
                          color: AppColors.nude,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.lock_outline_rounded,
                          color: AppColors.primary,
                          size: 30,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          height: 1.45,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: FilledButton.icon(
                          key: const ValueKey('workspace-retry'),
                          onPressed: _resolve,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Try Again'),
                        ),
                      ),
                      if (_pilot != null)
                        TextButton(
                          key: const ValueKey('pilot-logout'),
                          onPressed: _routing ? null : _logout,
                          child: const Text('Log out'),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    ),
  );
}
