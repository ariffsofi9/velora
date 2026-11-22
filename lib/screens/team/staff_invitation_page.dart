import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/staff_invitation_service.dart';
import '../../services/staff_https_service.dart';
import '../../services/staff_invitation_https_transport.dart';
import '../../services/owner_email_verification.dart';
import '../../services/workspace_session.dart';
import '../../services/staff_invitation_journal_stub.dart'
    if (dart.library.js_interop) '../../services/staff_invitation_journal_web.dart';
import '../auth/workspace_gate.dart';
import '../../models/cafe_workspace.dart';
import '../../services/android_pilot_policy.dart';

class StaffInvitationPage extends StatefulWidget {
  final AndroidPilotAuthDependencies? pilot;
  final bool ownerMode;
  final StaffInvitations? invitations;
  final FirebaseAuth? auth;
  final VoidCallback? onJoined;
  final CafeWorkspace? workspace;
  final WorkspaceSession? workspaceSession;
  const StaffInvitationPage({
    super.key,
    this.pilot,
    this.ownerMode = false,
    this.invitations,
    this.auth,
    this.onJoined,
    this.workspace,
    this.workspaceSession,
  });
  @override
  State<StaffInvitationPage> createState() => _StaffInvitationPageState();
}

class _InvitationOperation {
  final int revision;
  final FirebaseAuth auth;
  final String uid;
  final StaffInvitations service;
  final CafeWorkspace? workspace;
  final bool ownerMode;
  final StaffInvitationCreation? guard;
  _InvitationOperation(
    this.revision,
    this.auth,
    this.uid,
    this.service,
    this.workspace,
    this.ownerMode,
    this.guard,
  );
}

class _StaffInvitationPageState extends State<StaffInvitationPage> {
  late final _buildPolicy = AndroidPilotPolicy.fromBuildConfiguration(
    isWeb: kIsWeb,
    platform: defaultTargetPlatform,
    androidFlavor: appFlavor,
  );
  AndroidPilotPolicy get _policy {
    final inherited = AndroidPilotAuthScope.read(context)?.policy;
    if (inherited != null && inherited.state != AndroidPilotState.normal) {
      return inherited;
    }
    return widget.pilot?.policy ?? inherited ?? _buildPolicy;
  }

  AndroidPilotAuthDependencies? get _pilot =>
      widget.pilot ?? AndroidPilotAuthScope.read(context);
  bool get _allowed =>
      _policy.state == AndroidPilotState.normal ||
      _policy.permits(AndroidPilotCapability.teamCallables);
  bool _bound = false;
  AndroidPilotAuthDependencies? _boundPilot;
  final _entry = TextEditingController();
  final _revoke = TextEditingController();
  StaffInvitation? _invitation;
  bool _busy = false;
  String? _message;
  late FirebaseAuth _auth;
  late StaffInvitations _service;
  String? _uid;
  int _revision = 0;
  bool _identityTrusted = false;
  StreamSubscription<User?>? _authChanges;
  StaffInvitationCreation? _creationGuard;
  _InvitationOperation? _operation;
  http.Client? _client;
  StaffInvitationPageResult? _statuses;

  bool get _cannotCreate =>
      !_allowed ||
      !_bound ||
      (_creationGuard?.blocked ?? false) ||
      (_service is HttpsStaffInvitations &&
          ((_service as HttpsStaffInvitations).journal == null ||
              (_service as HttpsStaffInvitations).creationBlocked));

  static bool _sameWorkspace(CafeWorkspace? a, CafeWorkspace? b) =>
      a?.cafeId == b?.cafeId &&
      a?.uid == b?.uid &&
      a?.ownerUid == b?.ownerUid &&
      a?.role == b?.role &&
      a?.membershipGeneration == b?.membershipGeneration;

  static bool _validId(String? value) =>
      value != null &&
      value.isNotEmpty &&
      value.length <= 128 &&
      value.trim() == value &&
      value != '.' &&
      value != '..' &&
      !RegExp(r'[/\\\x00-\x1f]').hasMatch(value);

  bool get _validContext {
    if (!_allowed || !_bound) return false;
    if (!_identityTrusted ||
        !_validId(_uid) ||
        _auth.currentUser?.uid != _uid) {
      return false;
    }
    if (!widget.ownerMode) return true;
    if (widget.workspaceSession?.isActive == false) return false;
    final scope = widget.workspace;
    return scope != null &&
        _validId(scope.cafeId) &&
        scope.uid == _uid &&
        scope.ownerUid == _uid &&
        scope.role == CafeRole.owner &&
        scope.membershipGeneration >= 0 &&
        scope.membershipGeneration <= 9007199254740991;
  }

  @override
  void initState() {
    super.initState();
    _bindContext();
  }

  void _clearContext() {
    _bound = false;
    _revision++;
    _operation = null;
    _busy = false;
    _invitation = null;
    _statuses = null;
    _entry.clear();
    _revoke.clear();
    _message = null;
    _identityTrusted = false;
    _authChanges?.cancel();
    _authChanges = null;
    _client?.close();
    _client = null;
  }

  void _bindContext() {
    _clearContext();
    _boundPilot = _pilot;
    if (!_allowed) return;
    _auth = widget.auth ?? _pilot?.auth ?? FirebaseAuth.instance;
    _uid = _auth.currentUser?.uid;
    final injected = widget.invitations;
    if (injected != null) {
      _service = injected;
    } else {
      if (_auth.app.options.projectId != StaffHttpsService.realProject) return;
      final auth = _auth;
      final revision = _revision;
      final client = _client = http.Client();
      InvitationHttpsSession? current() {
        final user = auth.currentUser;
        if (!_validContext ||
            !identical(_client, client) ||
            revision != _revision ||
            user == null ||
            !user.emailVerified) {
          return null;
        }
        return InvitationHttpsSession(
          uid: user.uid,
          projectId: StaffHttpsService.realProject,
          revision: revision,
          emailVerified: true,
        );
      }

      _service = HttpsStaffInvitations(
        pilotPolicy: _policy,
        endpoint: Uri.parse(StaffHttpsService.canonicalOrigin),
        projectId: StaffHttpsService.realProject,
        endpointProjectId: StaffHttpsService.realProject,
        client: client,
        currentSession: current,
        sessionChanges: auth.authStateChanges().map((_) => current()),
        idToken: (captured) async {
          final user = auth.currentUser;
          if (user == null || !captured.matches(current())) return null;
          final token = await user.getIdTokenResult(true);
          return captured.matches(current()) &&
                  token.claims?['email_verified'] == true
              ? token.token
              : null;
        },
        sessionScope: auth,
        requestId: () {
          final random = Random.secure();
          return List.generate(
            32,
            (_) => random.nextInt(16).toRadixString(16),
          ).join();
        },
        clock: DateTime.now,
        journal: widget.ownerMode ? openStaffInvitationJournal() : null,
        timeout: const Duration(seconds: 30),
      );
    }
    _creationGuard = _uid == null
        ? null
        : StaffInvitationCreation.forSession(_auth, _uid!);
    _identityTrusted = true;
    _bound = true;
    final revision = _revision;
    var sawInitialIdentity = false;
    _authChanges = _auth.authStateChanges().listen(
      (user) {
        if (!mounted || revision != _revision) return;
        if ((sawInitialIdentity && widget.invitations == null) ||
            user?.uid != _uid ||
            _auth.currentUser?.uid != _uid) {
          setState(_bindContext);
        }
        sawInitialIdentity = true;
      },
      onError: (Object _) {
        if (!mounted || revision != _revision) return;
        setState(_clearContext);
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.dependOnInheritedWidgetOfExactType<AndroidPilotAuthScope>();
    if (!identical(_boundPilot, _pilot)) _bindContext();
  }

  @override
  void didUpdateWidget(covariant StaffInvitationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_bound ||
        !identical(oldWidget.pilot, widget.pilot) ||
        !identical(oldWidget.auth, widget.auth) ||
        !identical(oldWidget.invitations, widget.invitations) ||
        oldWidget.ownerMode != widget.ownerMode ||
        !identical(oldWidget.workspaceSession, widget.workspaceSession) ||
        !_sameWorkspace(oldWidget.workspace, widget.workspace) ||
        _auth.currentUser?.uid != _uid) {
      _bindContext();
    }
  }

  bool _current(_InvitationOperation operation) =>
      mounted &&
      identical(_operation, operation) &&
      operation.revision == _revision &&
      identical(operation.auth, _auth) &&
      operation.uid == _uid &&
      identical(operation.service, _service) &&
      operation.ownerMode == widget.ownerMode &&
      _sameWorkspace(operation.workspace, widget.workspace) &&
      _validContext;

  @override
  void dispose() {
    _revision++;
    _operation = null;
    _authChanges?.cancel();
    _client?.close();
    _entry.dispose();
    _revoke.dispose();
    _invitation = null;
    super.dispose();
  }

  Future<void> _run(Future<void> Function(_InvitationOperation) action) async {
    if (!mounted || !_allowed || _busy || !_validContext) return;
    final operation = _InvitationOperation(
      _revision,
      _auth,
      _uid!,
      _service,
      widget.workspace,
      widget.ownerMode,
      _creationGuard,
    );
    _operation = operation;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action(operation);
    } catch (error) {
      if (_current(operation)) {
        setState(
          () => _message = switch (error) {
            StaffInvitationFailure(outcomeUnknown: true) =>
              'Outcome unknown. The invitation action may have completed. Do not submit again blindly. Ask the owner or support to confirm the current state before another attempt.',
            StaffInvitationFailure(code: 'already-exists') =>
              'This invitation request or account already has a membership. Do not retry creation blindly.',
            StaffInvitationFailure(code: 'resource-exhausted') =>
              'Too many attempts. Please try later.',
            StaffInvitationFailure(code: 'failed-precondition') =>
              'Verify your email, or ask the owner for a new invitation. This code may be expired, revoked or used.',
            OwnerVerificationException() =>
              'Email verification could not be confirmed. Check your sign-in and verify the invited email.',
            _ =>
              'Unable to complete the invitation action. Check your account, email verification and invitation, then try again.',
          },
        );
      }
    } finally {
      if (_current(operation)) {
        setState(() {
          _busy = false;
          _operation = null;
        });
      }
    }
  }

  bool get _available => _validContext;

  @override
  Widget build(BuildContext context) => !_allowed
      ? const PilotAccessBlockedPage()
      : Scaffold(
          appBar: AppBar(
            title: Text(
              widget.ownerMode ? 'Staff invitation' : 'Join workspace',
            ),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    widget.ownerMode
                        ? 'Invite staff by email'
                        : 'Join with your verified email',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.ownerMode
                        ? 'The code is shown once. Share it privately with the intended staff member. It expires after 24 hours.'
                        : 'Sign in using the invited email address, verify it, then enter the one-time code. Existing workspace memberships cannot be replaced.',
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _entry,
                    enabled: !_busy,
                    obscureText: !widget.ownerMode,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: widget.ownerMode
                        ? TextInputType.emailAddress
                        : TextInputType.visiblePassword,
                    decoration: InputDecoration(
                      labelText: widget.ownerMode
                          ? 'Staff email'
                          : 'Invitation code',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed:
                        _busy ||
                            !_available ||
                            (widget.ownerMode && _cannotCreate)
                        ? null
                        : () => _run((operation) async {
                            if (widget.ownerMode) {
                              if (_cannotCreate) return;
                              late StaffInvitation result;
                              try {
                                result = await operation.service.create(
                                  _entry.text.trim(),
                                  workspace: operation.workspace!,
                                );
                              } on StaffInvitationFailure catch (error) {
                                if (error.outcomeUnknown) {
                                  operation.guard?.requireReconciliation();
                                }
                                rethrow;
                              }
                              if (!_current(operation)) {
                                // Issuance was acknowledged but its code cannot be delivered
                                // into the old context. Do not silently allow fresh issuance.
                                operation.guard?.requireReconciliation();
                                return;
                              }
                              setState(() {
                                _invitation = result;
                                _revoke.text = result.id;
                                _statuses = null;
                              });
                            } else {
                              final onJoined = widget.onJoined;
                              if (widget.invitations == null &&
                                  !await FirebaseOwnerEmailVerification(
                                    auth: operation.auth,
                                  ).refreshVerified()) {
                                if (_current(operation)) {
                                  setState(
                                    () => _message =
                                        'Verify your invited email before redeeming.',
                                  );
                                }
                                return;
                              }
                              if (!_current(operation)) return;
                              await operation.service.redeem(_entry.text);
                              if (!context.mounted || !_current(operation)) {
                                return;
                              }
                              _entry.clear();
                              if (onJoined != null) {
                                onJoined();
                              } else {
                                Navigator.of(context).pushAndRemoveUntil(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const WorkspaceGate(),
                                  ),
                                  (_) => false,
                                );
                              }
                            }
                          }),
                    child: Text(
                      widget.ownerMode
                          ? 'Create invitation'
                          : 'Redeem invitation',
                    ),
                  ),
                  if (!widget.ownerMode) ...[
                    TextButton(
                      onPressed: _busy || !_available
                          ? null
                          : () => _run((operation) async {
                              if (!(_pilot?.allows(
                                    AndroidPilotCapability.verificationEmail,
                                  ) ??
                                  true)) {
                                return;
                              }
                              final user = operation.auth.currentUser;
                              if (user == null) {
                                throw StateError('Sign in required.');
                              }
                              await user.sendEmailVerification();
                              if (_current(operation)) {
                                setState(
                                  () => _message =
                                      'Verification requested. Open the email verification link, then redeem again.',
                                );
                              }
                            }),
                      child: const Text('Send verification email'),
                    ),
                  ],
                  if (_invitation case final invite?) ...[
                    const SizedBox(height: 20),
                    SelectableText(invite.code),
                    Text('Expires: ${invite.expiresAt}'),
                    TextButton(
                      onPressed: () async {
                        if (!_validContext || !identical(_invitation, invite)) {
                          return;
                        }
                        await Clipboard.setData(
                          ClipboardData(text: invite.code),
                        );
                      },
                      child: const Text('Copy one-time code'),
                    ),
                    const Text(
                      'Clipboard contents are sensitive. Clear them after sharing. No code is saved by VELORA.',
                    ),
                  ],
                  if (widget.ownerMode) ...[
                    if (_bound && _service is HttpsStaffInvitations) ...[
                      OutlinedButton(
                        onPressed: _busy || !_available
                            ? null
                            : () => _loadStatuses(),
                        child: const Text('Refresh invitation statuses'),
                      ),
                      if (_statuses case final page?) ...[
                        if (page.invitations.isEmpty)
                          const Text('No invitations on this page.'),
                        for (final invitation in page.invitations)
                          ListTile(
                            title: Text(invitation.email),
                            subtitle: Text(
                              '${invitation.status} · Expires ${invitation.expiresAt.toLocal()}',
                            ),
                            trailing: invitation.status == 'pending'
                                ? TextButton(
                                    onPressed: _busy || !_available
                                        ? null
                                        : () => setState(
                                            () => _revoke.text = invitation.id,
                                          ),
                                    child: const Text('Select to revoke'),
                                  )
                                : null,
                          ),
                        if (page.nextCursor != null)
                          OutlinedButton(
                            onPressed: _busy || !_available
                                ? null
                                : () => _loadStatuses(page.nextCursor),
                            child: const Text('Next invitation page'),
                          ),
                      ],
                    ],
                    if (_bound &&
                        _service is HttpsStaffInvitations &&
                        (_service as HttpsStaffInvitations).journal != null)
                      OutlinedButton(
                        onPressed: _busy || !_available
                            ? null
                            : () => _run((operation) async {
                                final status =
                                    await (operation.service
                                            as HttpsStaffInvitations)
                                        .reconcile();
                                if (_current(operation)) {
                                  setState(
                                    () => _message =
                                        status.invitationState == null
                                        ? 'The server has not confirmed the last invitation.'
                                        : 'Last invitation status: ${status.invitationState}.',
                                  );
                                }
                              }),
                        child: const Text('Check last invitation status'),
                      ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _revoke,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: 'Invitation ID to revoke',
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _busy || !_available
                          ? null
                          : () => _run((operation) async {
                              final submittedId = _revoke.text.trim();
                              await operation.service.revoke(
                                submittedId,
                                workspace: operation.workspace!,
                              );
                              if (_current(operation)) {
                                setState(() {
                                  if (_invitation?.id == submittedId) {
                                    _invitation = null;
                                    _revoke.clear();
                                  }
                                  _message = 'Invitation revoked.';
                                  _statuses = null;
                                });
                              }
                            }),
                      child: const Text('Revoke invitation'),
                    ),
                  ],
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (_message != null)
                    Semantics(liveRegion: true, child: Text(_message!)),
                  if (!_validContext)
                    const Text(
                      'Invitation context could not be verified. Return and reopen this page from your current workspace.',
                    ),
                  if (widget.ownerMode && _cannotCreate)
                    const Text(
                      'Invitation creation requires recovery storage and a confirmed previous issuance.',
                    ),
                ],
              ),
            ),
          ),
        );

  Future<void> _loadStatuses([String? cursor]) => _run((operation) async {
    final page = await (operation.service as HttpsStaffInvitations)
        .listInvitations(operation.workspace!, cursor: cursor);
    if (_current(operation)) setState(() => _statuses = page);
  });
}
