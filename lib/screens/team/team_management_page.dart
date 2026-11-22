import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;
import '../../services/android_pilot_policy.dart';
import '../auth/workspace_gate.dart';
import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/theme/app_tokens.dart';
import '../../models/cafe_workspace.dart';
import '../../services/workspace_resolver.dart';
import '../../services/team_members_service.dart';
import '../../services/staff_https_service.dart';
import '../../services/workspace_session.dart';
import 'team_management_widgets.dart';
import 'staff_invitation_page.dart';

class TeamManagementPage extends StatefulWidget {
  final FirebaseAuth? auth;
  final WorkspaceResolver? resolver;
  final TeamMembers? members;
  final WorkspaceSession? workspaceSession;
  final String rosterOrigin;
  final http.Client Function()? createRosterClient;

  const TeamManagementPage({
    super.key,
    this.auth,
    this.resolver,
    this.members,
    this.workspaceSession,
    this.rosterOrigin = StaffHttpsService.configuredOrigin,
    this.createRosterClient,
  });

  @override
  State<TeamManagementPage> createState() => _TeamManagementPageState();
}

class _TeamManagementPageState extends State<TeamManagementPage> {
  late final _buildPolicy = AndroidPilotPolicy.fromBuildConfiguration(
    isWeb: kIsWeb,
    platform: defaultTargetPlatform,
    androidFlavor: appFlavor,
  );
  AndroidPilotPolicy get _policy =>
      AndroidPilotAuthScope.read(context)?.policy ?? _buildPolicy;
  bool get _allowed =>
      _policy.state == AndroidPilotState.normal ||
      _policy.permits(AndroidPilotCapability.teamCallables);

  late Future<TeamRoster> _workspace;
  StreamSubscription<User?>? _authChanges;
  int _generation = 0;
  int _bindingRevision = 0;
  bool _rosterIdentityVerified = false;
  AndroidPilotPolicy? _boundPolicy;
  final List<String?> _previousCursors = [];
  String? _cursor;
  StaffHttpsService? _rest;
  http.Client? _rosterClient;
  final Map<String, StaffRemovalRequest> _pendingRemovals = {};
  bool _removing = false;

  FirebaseAuth get _auth => widget.auth ?? FirebaseAuth.instance;
  WorkspaceResolver get _resolver =>
      widget.resolver ?? WorkspaceResolver(auth: _auth);

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _previousCursors.clear();
    _cursor = null;
    _boundPolicy = _policy;
    _generation++;
    final binding = ++_bindingRevision;
    _rosterIdentityVerified = false;
    unawaited(_authChanges?.cancel());
    _authChanges = null;
    _closeRosterClient();
    if (!_allowed) return;
    final auth = _auth, workspace = widget.workspaceSession;
    final initialIdentity = Completer<void>();
    var active = true;
    bool currentBinding() => mounted && binding == _bindingRevision;
    if (widget.members == null &&
        workspace?.isActive == true &&
        widget.rosterOrigin.isNotEmpty) {
      try {
        final client = (widget.createRosterClient ?? http.Client.new)();
        _rosterClient = client;
        _rest = StaffHttpsService.realRoster(
          pilotPolicy: _policy,
          auth: auth,
          workspace: workspace!,
          client: client,
          origin: widget.rosterOrigin,
          isCurrent: () =>
              currentBinding() && active && identical(_rosterClient, client),
        );
      } catch (_) {
        _closeRosterClient();
      }
    }
    _workspace = widget.members != null
        ? _load()
        : initialIdentity.future
              .timeout(
                const Duration(seconds: 10),
                onTimeout: () => throw const StaffHttpsException(
                  'unauthenticated',
                  outcomeUnknown: false,
                ),
              )
              .then((_) {
                if (!currentBinding() || !active) {
                  throw const StaffHttpsException(
                    'session-changed',
                    outcomeUnknown: false,
                  );
                }
                return _load();
              });
    _workspace.ignore();
    void invalidateBinding() {
      if (!currentBinding()) return;
      active = false;
      _rosterIdentityVerified = false;
      _closeRosterClient();
      if (!initialIdentity.isCompleted) {
        initialIdentity.complete();
      } else {
        _retry();
      }
    }

    _authChanges = auth.authStateChanges().listen(
      (user) {
        if (!currentBinding()) return;
        if (widget.members != null) {
          _retry();
          return;
        }
        if (!initialIdentity.isCompleted &&
            workspace?.isActive == true &&
            user?.uid == workspace?.uid &&
            user?.emailVerified == true) {
          _rosterIdentityVerified = true;
          initialIdentity.complete();
          return;
        }
        invalidateBinding();
      },
      onError: (Object _) => invalidateBinding(),
      onDone: invalidateBinding,
    );
  }

  void _closeRosterClient() {
    _rest = null;
    _rosterClient?.close();
    _rosterClient = null;
  }

  Future<void> _remove(TeamMember member) async {
    final service = _rest;
    final workspace = widget.workspaceSession;
    final generation = member.membershipGeneration;
    if (_removing ||
        service == null ||
        workspace == null ||
        !workspace.isActive ||
        !workspace.isOwner ||
        generation == null) {
      return;
    }
    setState(() => _removing = true);
    try {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove Staff access?'),
          content: Text('${member.name} will lose access to this workspace.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (!mounted ||
          approved != true ||
          !identical(service, _rest) ||
          !workspace.isActive) {
        return;
      }
      final key =
          '${workspace.uid}/${workspace.cafeId}/${workspace.membershipGeneration}/${member.uid}/$generation';
      final request = _pendingRemovals.putIfAbsent(key, () {
        final random = Random.secure();
        return StaffRemovalRequest(
          targetUid: member.uid,
          expectedCafeId: workspace.cafeId,
          expectedGeneration: generation,
          expectedActorGeneration: workspace.membershipGeneration,
          idempotencyKey: List.generate(
            24,
            (_) => random.nextInt(16).toRadixString(16),
          ).join(),
        );
      });
      try {
        await service.remove(request);
        _pendingRemovals.remove(key);
        if (mounted && identical(service, _rest)) _retry();
      } on StaffHttpsException catch (error) {
        if (!error.outcomeUnknown) _pendingRemovals.remove(key);
        if (!mounted || !identical(service, _rest)) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.outcomeUnknown
                  ? 'Removal may have completed. Refresh the roster before retrying.'
                  : 'Staff access could not be removed. Refresh the roster.',
            ),
          ),
        );
        _retry();
      }
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.dependOnInheritedWidgetOfExactType<AndroidPilotAuthScope>();
    if (!identical(_boundPolicy, _policy)) _bind();
  }

  @override
  void didUpdateWidget(covariant TeamManagementPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.auth != widget.auth ||
        oldWidget.resolver != widget.resolver ||
        oldWidget.members != widget.members ||
        oldWidget.workspaceSession != widget.workspaceSession ||
        oldWidget.rosterOrigin != widget.rosterOrigin ||
        oldWidget.createRosterClient != widget.createRosterClient) {
      _bind();
    }
  }

  Future<TeamRoster> _load([String? cursor]) async {
    if (!mounted || !_allowed) throw const TeamPilotPolicyException();
    if (widget.members == null && !_rosterIdentityVerified) {
      throw const StaffHttpsException('session-changed', outcomeUnknown: false);
    }
    final generation = ++_generation;
    final service = widget.members ?? _rest;
    final session = widget.workspaceSession;
    if (service == null) {
      throw StaffHttpsException(
        session?.isActive == true && _auth.currentUser?.uid == session?.uid
            ? 'unavailable'
            : 'session-changed',
        outcomeUnknown: false,
      );
    }
    final uid = _auth.currentUser?.uid;
    final CafeWorkspace workspace;
    if (widget.members != null) {
      workspace = await _resolver.resolve();
    } else {
      if (session == null || !session.isActive) {
        throw StateError('Session changed.');
      }
      workspace = CafeWorkspace(
        cafeId: session.cafeId,
        uid: session.uid,
        ownerUid: session.ownerUid,
        role: session.role,
        membershipGeneration: session.membershipGeneration,
      );
    }
    if (!mounted ||
        !_allowed ||
        uid == null ||
        workspace.uid != uid ||
        _auth.currentUser?.uid != uid ||
        generation != _generation) {
      throw StateError('Session changed.');
    }
    if (cursor != null && service is! PagedTeamMembers) {
      throw StateError('Team pagination is unavailable.');
    }
    final roster = cursor == null
        ? await service.load(workspace)
        : await (service as PagedTeamMembers).loadPage(workspace, cursor);
    if (!mounted ||
        !_allowed ||
        generation != _generation ||
        (session != null && !session.isActive) ||
        _auth.currentUser?.uid != uid) {
      throw StateError('Session changed.');
    }
    return roster;
  }

  void _retry() {
    if (!mounted || !_allowed) return;
    setState(() {
      _previousCursors.clear();
      _cursor = null;
      _workspace = _load();
      // Auth errors can complete before the next build attaches FutureBuilder.
      // Mark handled here; FutureBuilder still receives the original error.
      _workspace.ignore();
    });
  }

  void _goToPage(
    Future<TeamRoster> request,
    String? cursor, {
    required bool previous,
  }) {
    if (!mounted || !_allowed || !identical(_workspace, request)) return;
    setState(() {
      if (previous) {
        _previousCursors.removeLast();
      } else {
        _previousCursors.add(_cursor);
      }
      _cursor = cursor;
      _workspace = _load(cursor)..ignore();
    });
  }

  @override
  void dispose() {
    _generation++;
    _bindingRevision++;
    _authChanges?.cancel();
    _closeRosterClient();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed) return const PilotAccessBlockedPage();
    final request = _workspace;
    final hasPrevious = _previousCursors.isNotEmpty;
    final previousCursor = hasPrevious ? _previousCursors.last : null;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        title: const Text(
          'Team Management',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: FutureBuilder<TeamRoster>(
              future: request,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  );
                }

                final workspace = snapshot.data;
                if (snapshot.hasError || workspace == null) {
                  return _NoTrustedTeam(onRetry: _retry, error: snapshot.error);
                }

                return _VerifiedTeamView(
                  roster: workspace,
                  onRefresh: _retry,
                  onPrevious: hasPrevious
                      ? () => _goToPage(request, previousCursor, previous: true)
                      : null,
                  onNext: workspace.nextCursor == null
                      ? null
                      : () => _goToPage(
                          request,
                          workspace.nextCursor,
                          previous: false,
                        ),
                  auth: _auth,
                  workspaceSession: widget.workspaceSession,
                  onRemove: _rest == null || _removing ? null : _remove,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _VerifiedTeamView extends StatelessWidget {
  final TeamRoster roster;
  final VoidCallback onRefresh;
  final VoidCallback? onPrevious, onNext;
  final FirebaseAuth auth;
  final WorkspaceSession? workspaceSession;
  final ValueChanged<TeamMember>? onRemove;

  const _VerifiedTeamView({
    required this.roster,
    required this.onRefresh,
    required this.onPrevious,
    required this.onNext,
    required this.auth,
    required this.workspaceSession,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final role = roster.workspace.role == CafeRole.owner ? 'Owner' : 'Staff';

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        _TeamHeader(
          role: role,
          workspace: roster.workspace,
          auth: auth,
          workspaceSession: workspaceSession,
        ),
        const SizedBox(height: 24),
        Text(
          'Verified Members (${roster.members.length})',
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        if (roster.members.isEmpty)
          const Text('No verified members are available.')
        else
          for (final member in roster.members) ...[
            _MemberCard(
              name: member.name,
              email: member.email,
              role: member.role == CafeRole.owner ? 'Owner' : 'Staff',
            ),
            if (roster.workspace.role == CafeRole.owner &&
                member.role == CafeRole.staff &&
                member.membershipGeneration != null)
              TextButton(
                onPressed: onRemove == null ? null : () => onRemove!(member),
                child: const Text('Remove access'),
              ),
            const SizedBox(height: 10),
          ],
        OutlinedButton.icon(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Refresh members'),
        ),
        if (onPrevious != null || onNext != null)
          Wrap(
            spacing: 12,
            children: [
              if (onPrevious != null)
                OutlinedButton(
                  onPressed: onPrevious,
                  child: const Text('Previous page'),
                ),
              if (onNext != null)
                OutlinedButton(
                  onPressed: onNext,
                  child: const Text('Next page'),
                ),
            ],
          ),
        if (roster.workspace.role == CafeRole.staff)
          const TeamBackendNotice(
            message:
                'Staff can view their own membership and the workspace owner.',
          ),
      ],
    );
  }
}

class _TeamHeader extends StatelessWidget {
  final String role;
  final CafeWorkspace workspace;
  final FirebaseAuth auth;
  final WorkspaceSession? workspaceSession;

  const _TeamHeader({
    required this.role,
    required this.workspace,
    required this.auth,
    required this.workspaceSession,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.nude,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.groups_2_outlined,
                color: AppColors.primary,
              ),
            ),
            const Text(
              'Your Café Team',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          role == 'Owner'
              ? 'Your owner membership is verified.'
              : 'Your staff membership is verified.',
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w400,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton.icon(
            key: const ValueKey('invite-staff-button'),
            onPressed:
                role == 'Owner' &&
                    auth.app.options.projectId == StaffHttpsService.realProject
                ? () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => StaffInvitationPage(
                        ownerMode: true,
                        auth: auth,
                        workspace: workspace,
                        workspaceSession: workspaceSession,
                      ),
                    ),
                  )
                : null,
            icon: const Icon(Icons.person_add_alt_1_outlined),
            label: const Text('Invite Staff'),
          ),
        ),
      ],
    ),
  );
}

class _MemberCard extends StatelessWidget {
  final String name;
  final String email;
  final String role;

  const _MemberCard({
    required this.name,
    required this.email,
    required this.role,
  });

  String get _initials {
    final words = name.trim().split(RegExp(r'\s+'));
    return words.take(2).map((word) => word[0].toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: AppColors.nude,
          foregroundColor: AppColors.primary,
          child: Text(
            _initials,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (email.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  email,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              TeamRoleBadge(role: role),
            ],
          ),
        ),
      ],
    ),
  );
}

class _NoTrustedTeam extends StatelessWidget {
  final VoidCallback onRetry;
  final Object? error;

  const _NoTrustedTeam({required this.onRetry, this.error});

  String get message => switch (error) {
    StaffHttpsException(code: 'unauthenticated' || 'session-changed') =>
      'Your sign-in could not be verified for the team list. Return to Profile and reopen Team Management. Sign in again if the session has expired.',
    StaffHttpsException(code: 'permission-denied') =>
      'The service denied access to this workspace’s team list.',
    StaffHttpsException(code: 'resource-exhausted') =>
      'The team service is busy. Wait a moment, then retry.',
    StaffHttpsException(code: 'network-unavailable') =>
      'Velora could not reach the team service from this app. Check your connection, then retry.',
    _ =>
      'The team list could not be verified. Check your connection and workspace access, then retry.',
  };

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const SizedBox(height: 48),
      Container(
        width: 88,
        height: 88,
        decoration: const BoxDecoration(
          color: AppColors.nude,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.group_off_outlined,
          color: AppColors.primary,
          size: 40,
        ),
      ),
      const SizedBox(height: 22),
      const Text(
        'Team members unavailable',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 10),
      Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: AppColors.textSecondary,
          height: 1.5,
          fontWeight: FontWeight.w400,
        ),
      ),
      const SizedBox(height: 22),
      SizedBox(
        height: 48,
        child: FilledButton.icon(
          key: const ValueKey('invite-staff-button'),
          onPressed: null,
          icon: const Icon(Icons.person_add_alt_1_outlined),
          label: const Text('Invite Staff'),
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Check Again'),
      ),
    ],
  );
}
