import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../models/cafe_workspace.dart';
import '../../services/workspace_resolver.dart';
import '../../services/team_members_service.dart';
import 'team_management_widgets.dart';
import 'staff_invitation_page.dart';
import '../../services/firebase_emulator_config.dart';

class TeamManagementPage extends StatefulWidget {
  final FirebaseAuth? auth;
  final WorkspaceResolver? resolver;
  final TeamMembers? members;

  const TeamManagementPage({super.key, this.auth, this.resolver, this.members});

  @override
  State<TeamManagementPage> createState() => _TeamManagementPageState();
}

class _TeamManagementPageState extends State<TeamManagementPage> {
  late Future<TeamRoster> _workspace;
  StreamSubscription<User?>? _authChanges;
  int _generation = 0;

  FirebaseAuth get _auth => widget.auth ?? FirebaseAuth.instance;
  WorkspaceResolver get _resolver =>
      widget.resolver ?? WorkspaceResolver(auth: _auth);

  @override
  void initState() {
    super.initState();
    _workspace = _load();
    _workspace.ignore();
    _authChanges = _auth.authStateChanges().listen((_) {
      if (mounted) _retry();
    });
  }

  Future<TeamRoster> _load() async {
    final generation = ++_generation;
    final uid = _auth.currentUser?.uid;
    final workspace = await _resolver.resolve();
    if (uid == null ||
        workspace.uid != uid ||
        _auth.currentUser?.uid != uid ||
        generation != _generation) {
      throw StateError('Session changed.');
    }
    final roster =
        await (widget.members ??
                FirebaseTeamMembers(auth: _auth, resolver: _resolver))
            .load(workspace);
    if (!mounted ||
        generation != _generation ||
        _auth.currentUser?.uid != uid) {
      throw StateError('Session changed.');
    }
    return roster;
  }

  void _retry() {
    setState(() {
      _workspace = _load();
      // Auth errors can complete before the next build attaches FutureBuilder.
      // Mark handled here; FutureBuilder still receives the original error.
      _workspace.ignore();
    });
  }

  @override
  void dispose() {
    _generation++;
    _authChanges?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
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
            future: _workspace,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                );
              }

              final workspace = snapshot.data;
              if (snapshot.hasError || workspace == null) {
                return _NoTrustedTeam(onRetry: _retry);
              }

              return _VerifiedTeamView(roster: workspace, onRefresh: _retry);
            },
          ),
        ),
      ),
    ),
  );
}

class _VerifiedTeamView extends StatelessWidget {
  final TeamRoster roster;
  final VoidCallback onRefresh;

  const _VerifiedTeamView({required this.roster, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final role = roster.workspace.role == CafeRole.owner ? 'Owner' : 'Staff';

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        _TeamHeader(role: role),
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
            const SizedBox(height: 10),
          ],
        OutlinedButton.icon(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Refresh members'),
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

  const _TeamHeader({required this.role});

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
                    FirebaseEmulatorConfig.enabled &&
                    FirebaseEmulatorConfig.staffDemo
                ? () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const StaffInvitationPage(ownerMode: true),
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

  const _NoTrustedTeam({required this.onRetry});

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
      const Text(
        'The team list could not be verified. Check your connection and workspace access, then retry.',
        textAlign: TextAlign.center,
        style: TextStyle(
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
