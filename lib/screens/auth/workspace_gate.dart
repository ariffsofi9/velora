import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../models/cafe_workspace.dart';
import '../../services/workspace_resolver.dart';
import '../../services/offline_verified_workspace_inventory.dart';
import '../../services/workspace_inventory_https_transport.dart';
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
  final AuthService? authService;
  final WorkspaceResolver? resolver;
  final Widget Function(BuildContext context, WorkspaceSession session)?
  homeBuilder;
  final WidgetBuilder? setupBuilder;
  final bool initiallyBlocked;
  final OwnerEmailVerification? ownerVerification;
  final OfflineVerifiedWorkspaceInventory? offlineInventory;
  final Stream<bool>? offlineAuthority;
  final Widget Function(
    BuildContext context,
    WorkspaceSession session,
    HttpsWorkspaceInventory transport,
  )?
  offlineHomeBuilder;

  const WorkspaceGate({
    super.key,
    this.pilot,
    this.authService,
    this.resolver,
    this.homeBuilder,
    this.setupBuilder,
    this.initiallyBlocked = false,
    this.ownerVerification,
    this.offlineInventory,
    this.offlineAuthority,
    this.offlineHomeBuilder,
  });

  @override
  State<WorkspaceGate> createState() => _WorkspaceGateState();
}

class _WorkspaceGateState extends State<WorkspaceGate> {
  AndroidPilotAuthDependencies? get _pilot =>
      widget.pilot ?? AndroidPilotAuthScope.read(context);
  FirebaseAuth get _auth =>
      _pilot?.auth ?? widget.authService?.firebaseAuth ?? FirebaseAuth.instance;
  EmailVerificationSession? _session;
  OwnerEmailVerification? _verification;
  bool _showVerification = false;
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

  Future<bool> _resolve({bool fromVerificationPage = false}) async {
    if (_routing || _resolving) return false;
    _resolving = true;
    final revision = ++_revision;
    final pilot = _pilot;
    final inventory = widget.offlineInventory;
    final offlineBuilder = widget.offlineHomeBuilder;
    final offlineAuthority = widget.offlineAuthority;
    final offline =
        inventory != null || offlineBuilder != null || offlineAuthority != null;
    if (!fromVerificationPage) {
      setState(() {
        _loading = true;
        _failure = null;
      });
    }
    try {
      if (pilot?.policy.isValid == false) {
        throw const WorkspaceResolutionException(
          WorkspaceFailure.unauthenticated,
        );
      }
      final offlineAuth = pilot == null
          ? widget.authService?.firebaseAuth
          : pilot.firebaseAuth;
      if (offline &&
          (inventory == null ||
              offlineBuilder == null ||
              offlineAuthority == null ||
              offlineAuth == null ||
              widget.resolver == null ||
              pilot?.policy.isRestricted == true ||
              !inventory.usesAuth(offlineAuth))) {
        throw const WorkspaceResolutionException(
          WorkspaceFailure.sessionChanged,
        );
      }
      final auth = offline ? offlineAuth! : _auth;
      final uid = auth.currentUser?.uid;
      if (uid == null) {
        throw const WorkspaceResolutionException(
          WorkspaceFailure.unauthenticated,
        );
      }
      final bound = _session ??= EmailVerificationSession(auth, uid);
      if (!identical(bound.auth, auth)) {
        throw const WorkspaceResolutionException(
          WorkspaceFailure.sessionChanged,
        );
      }
      await bound.ready(FirebaseOwnerEmailVerification.defaultTimeout);
      if (!mounted || revision != _revision || !identical(pilot, _pilot)) {
        return false;
      }
      final verification = _verification ??=
          widget.ownerVerification ??
          FirebaseOwnerEmailVerification(
            session: bound,
            pilotPolicy: pilot?.policy,
          );
      final verified = await verification.refreshVerified();
      bound.requireCurrent();
      if (!mounted || revision != _revision || !identical(pilot, _pilot)) {
        return false;
      }
      if (!verified || auth.currentUser?.emailVerified != true) {
        if (pilot?.policy.isRestricted == true) {
          throw const WorkspaceResolutionException(
            WorkspaceFailure.unauthenticated,
          );
        }
        setState(() {
          _loading = false;
          _showVerification = true;
        });
        return false;
      }
      final inventoryRevision = inventory?.revision;
      final resolver = widget.resolver ?? WorkspaceResolver(auth: auth);
      final workspace = await (pilot != null
          ? pilot.resolveEligibleWorkspace(
              resolve: offline ? resolver.resolve : null,
            )
          : resolver.resolve());
      bound.requireCurrent();
      if (workspace.uid != bound.uid ||
          auth.currentUser?.emailVerified != true) {
        throw const WorkspaceResolutionException(
          WorkspaceFailure.sessionChanged,
        );
      }
      if (!mounted || revision != _revision || !identical(pilot, _pilot)) {
        return false;
      }
      if (ModalRoute.of(context)?.isCurrent == false) return false;
      final session = WorkspaceSession.fromVerified(workspace);
      if (inventory != null) {
        if (inventory.revision != inventoryRevision ||
            !inventory.usesAuth(auth)) {
          session.invalidate();
          throw const WorkspaceResolutionException(
            WorkspaceFailure.sessionChanged,
          );
        }
        late final routeTransport = inventory.transportForWorkspace(session);
        _replace(
          (context) => WorkspaceSessionBoundary(
            session: session,
            pilot: pilot,
            identities: auth.authStateChanges().map((user) => user?.uid),
            authority: offlineAuthority!,
            resolve: resolver.resolve,
            offlineInventory: inventory,
            offlineInventoryRevision: inventoryRevision,
            child: Builder(
              builder: (context) =>
                  offlineBuilder!(context, session, routeTransport),
            ),
          ),
          '/workspace-home',
          bound,
        );
        return true;
      }
      final homeBuilder = widget.homeBuilder;
      final useBoundary =
          pilot != null || (homeBuilder == null && widget.resolver == null);
      _replace(
        (context) {
          final child =
              homeBuilder?.call(context, session) ??
              HomePage(workspaceSession: session);
          return useBoundary
              ? WorkspaceSessionBoundary(
                  session: session,
                  pilot: pilot,
                  child: child,
                )
              : child;
        },
        '/workspace-home',
        bound,
      );
      return true;
    } on WorkspaceResolutionException catch (error) {
      if (!mounted || revision != _revision || !identical(pilot, _pilot)) {
        return false;
      }
      final current = _session?.isCurrent ?? false;
      if (current &&
          !offline &&
          pilot?.policy.isRestricted != true &&
          _auth.currentUser?.emailVerified == true &&
          error.failure == WorkspaceFailure.missingMembership &&
          ModalRoute.of(context)?.isCurrent != false) {
        final setup = widget.setupBuilder;
        final verification =
            widget.ownerVerification ??
            FirebaseOwnerEmailVerification(
              auth: _auth,
              pilotPolicy: pilot?.policy,
            );
        _replace(
          (context) =>
              setup?.call(context) ??
              BusinessSetupPage(verification: verification),
          '/business-setup',
          _session!,
        );
        return true;
      }
      setState(() {
        _loading = false;
        _showVerification = false;
        _failure = _session != null && !current
            ? const WorkspaceResolutionException(
                WorkspaceFailure.sessionChanged,
              )
            : error;
      });
    } on OwnerVerificationException catch (error) {
      if (!mounted || revision != _revision) return false;
      final replaced =
          _session?.isCurrent == false ||
          error.failure == OwnerVerificationFailure.changed ||
          error.failure == OwnerVerificationFailure.signedOut;
      if (fromVerificationPage && !replaced) rethrow;
      setState(() {
        _loading = false;
        _showVerification = false;
        _failure = WorkspaceResolutionException(
          replaced
              ? WorkspaceFailure.sessionChanged
              : WorkspaceFailure.unavailable,
        );
      });
    } catch (_) {
      if (!mounted || revision != _revision) return false;
      setState(() {
        _loading = false;
        _showVerification = false;
        _failure = const WorkspaceResolutionException(
          WorkspaceFailure.unavailable,
        );
      });
    } finally {
      if (mounted && revision == _revision) _resolving = false;
    }
    return false;
  }

  Future<void> _retry() async {
    if (_routing || _resolving) return;
    final previous = _session;
    if (previous != null && !previous.isCurrent) {
      _session = null;
      _verification = null;
      unawaited(previous.close());
    }
    await _resolve();
  }

  Future<void> _logout() async {
    final pilot = _pilot;
    if (_routing) return;
    _revision++;
    _routing = true;
    try {
      await (pilot?.authService ?? widget.authService ?? AuthService())
          .signOut();
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
        !identical(oldWidget.authService, widget.authService) ||
        !identical(oldWidget.resolver, widget.resolver) ||
        !identical(oldWidget.offlineInventory, widget.offlineInventory) ||
        !identical(oldWidget.offlineAuthority, widget.offlineAuthority) ||
        !identical(oldWidget.offlineHomeBuilder, widget.offlineHomeBuilder) ||
        !identical(oldWidget.ownerVerification, widget.ownerVerification)) {
      _revision++;
      _resolving = false;
      _showVerification = false;
      unawaited(_session?.close());
      _session = null;
      _verification = null;
      if (!_routing) _resolve();
    }
  }

  @override
  void dispose() {
    _revision++;
    unawaited(_session?.close());
    super.dispose();
  }

  void _replace(
    WidgetBuilder builder,
    String name,
    EmailVerificationSession bound,
  ) {
    _routing = true;
    final pilot = _pilot;
    final authService = widget.authService;
    var admitted = false;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) {
          if (!admitted &&
              (!bound.isCurrent ||
                  bound.auth.currentUser?.emailVerified != true)) {
            return WorkspaceGate(
              pilot: pilot,
              authService: authService,
              initiallyBlocked: true,
            );
          }
          admitted = true;
          return builder(context);
        },
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
  Widget build(BuildContext context) {
    if (_showVerification) {
      return OwnerEmailVerificationPage(
        verification: _verification!,
        checkAndContinue: () => _resolve(fromVerificationPage: true),
      );
    }
    return _buildWorkspaceStatus();
  }

  Widget _buildWorkspaceStatus() => Scaffold(
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
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Try Again'),
                        ),
                      ),
                      TextButton(
                        key: _pilot == null
                            ? null
                            : const ValueKey('pilot-logout'),
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
