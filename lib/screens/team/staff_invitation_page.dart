import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/staff_invitation_service.dart';
import '../../services/firebase_emulator_config.dart';
import '../auth/workspace_gate.dart';
import '../../models/cafe_workspace.dart';

class StaffInvitationPage extends StatefulWidget {
  final bool ownerMode;
  final StaffInvitations? invitations;
  final FirebaseAuth? auth;
  final VoidCallback? onJoined;
  final CafeWorkspace? workspace;
  const StaffInvitationPage({
    super.key,
    this.ownerMode = false,
    this.invitations,
    this.auth,
    this.onJoined,
    this.workspace,
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
  _InvitationOperation(this.revision, this.auth, this.uid, this.service,
      this.workspace, this.ownerMode, this.guard);
}

class _StaffInvitationPageState extends State<StaffInvitationPage> {
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

  bool get _cannotCreate => (_creationGuard?.blocked ?? false) ||
      (_service is FirebaseStaffInvitations &&
          (_service as FirebaseStaffInvitations).creationBlocked);

  static bool _sameWorkspace(CafeWorkspace? a, CafeWorkspace? b) =>
      a?.cafeId == b?.cafeId && a?.uid == b?.uid &&
      a?.ownerUid == b?.ownerUid && a?.role == b?.role &&
      a?.membershipGeneration == b?.membershipGeneration;

  static bool _validId(String? value) => value != null && value.isNotEmpty &&
      value.length <= 128 && value.trim() == value && value != '.' && value != '..' &&
      !RegExp(r'[/\\\x00-\x1f]').hasMatch(value);

  bool get _validContext {
    if (!_identityTrusted || !_validId(_uid) || _auth.currentUser?.uid != _uid) return false;
    if (!widget.ownerMode) return true;
    final scope = widget.workspace;
    return scope != null && _validId(scope.cafeId) && scope.uid == _uid &&
        scope.ownerUid == _uid && scope.role == CafeRole.owner &&
        scope.membershipGeneration >= 0 && scope.membershipGeneration <= 9007199254740991;
  }

  @override
  void initState() {
    super.initState();
    _bindContext();
  }

  void _clearContext() {
    _revision++;
    _operation = null;
    _busy = false;
    _invitation = null;
    _entry.clear();
    _revoke.clear();
    _message = null;
    _identityTrusted = false;
    _authChanges?.cancel();
    _authChanges = null;
  }

  void _bindContext() {
    _clearContext();
    _auth = widget.auth ?? FirebaseAuth.instance;
    _uid = _auth.currentUser?.uid;
    _service = widget.invitations ?? FirebaseStaffInvitations(auth: _auth);
    _creationGuard = _uid == null ? null : StaffInvitationCreation.forSession(_auth, _uid!);
    _identityTrusted = true;
    final revision = _revision;
    _authChanges = _auth.authStateChanges().listen((user) {
      if (!mounted || revision != _revision) return;
      if (user?.uid != _uid || _auth.currentUser?.uid != _uid) {
        setState(_bindContext);
      }
    }, onError: (Object _) {
      if (!mounted || revision != _revision) return;
      setState(_clearContext);
    });
  }

  @override
  void didUpdateWidget(covariant StaffInvitationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.auth, widget.auth) ||
        !identical(oldWidget.invitations, widget.invitations) ||
        oldWidget.ownerMode != widget.ownerMode ||
        !_sameWorkspace(oldWidget.workspace, widget.workspace) ||
        _auth.currentUser?.uid != _uid) {
      _bindContext();
    }
  }

  bool _current(_InvitationOperation operation) => mounted &&
      identical(_operation, operation) && operation.revision == _revision &&
      identical(operation.auth, _auth) && operation.uid == _uid &&
      identical(operation.service, _service) && operation.ownerMode == widget.ownerMode &&
      _sameWorkspace(operation.workspace, widget.workspace) && _validContext;

  @override
  void dispose() {
    _revision++;
    _operation = null;
    _authChanges?.cancel();
    _entry.dispose();
    _revoke.dispose();
    _invitation = null;
    super.dispose();
  }

  Future<void> _run(Future<void> Function(_InvitationOperation) action) async {
    if (_busy || !_validContext) return;
    final operation = _InvitationOperation(_revision, _auth, _uid!, _service,
        widget.workspace, widget.ownerMode, _creationGuard);
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
            StaffInvitationFailure() =>
              '$error Check your sign-in and local emulator connection. If emailVerification is shown, verify your email and sign in again.',
            FirebaseFunctionsException(code: 'already-exists') =>
              'This invitation request or account already has a membership. Do not retry creation blindly.',
            FirebaseFunctionsException(code: 'resource-exhausted') =>
              'Too many attempts. Please try later.',
            FirebaseFunctionsException(code: 'failed-precondition') =>
              'Verify your email, or ask the owner for a new invitation. This code may be expired, revoked or used.',
            _ =>
              'Unable to complete the invitation action. Check your account, email verification and invitation, then try again.',
          },
        );
      }
    } finally {
      if (_current(operation)) setState(() {
        _busy = false;
        _operation = null;
      });
    }
  }

  bool get _available =>
      _validContext &&
      (widget.invitations != null || FirebaseEmulatorConfig.invitationsAvailable);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.ownerMode ? 'Staff invitation' : 'Join workspace'),
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
                labelText: widget.ownerMode ? 'Staff email' : 'Invitation code',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || !_available || (widget.ownerMode && _cannotCreate)
                  ? null
                  : () => _run((operation) async {
                      if (widget.ownerMode) {
                        if (_cannotCreate) return;
                        late StaffInvitation result;
                        try {
                          result = await operation.service.create(_entry.text.trim());
                        } on StaffInvitationFailure catch (error) {
                          if (error.outcomeUnknown) operation.guard?.requireReconciliation();
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
                        });
                      } else {
                        final onJoined = widget.onJoined;
                        await operation.service.redeem(_entry.text);
                        if (!_current(operation)) return;
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
                widget.ownerMode ? 'Create invitation' : 'Redeem invitation',
              ),
            ),
            if (!widget.ownerMode) ...[
              TextButton(
                onPressed: _busy || !_available
                    ? null
                    : () => _run((operation) async {
                        final user = operation.auth.currentUser;
                        if (user == null) throw StateError('Sign in required.');
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
                  if (!_validContext || !identical(_invitation, invite)) return;
                  await Clipboard.setData(ClipboardData(text: invite.code));
                },
                child: const Text('Copy one-time code'),
              ),
              const Text(
                'Clipboard contents are sensitive. Clear them after sharing. No code is saved by VELORA.',
              ),
            ],
            if (widget.ownerMode) ...[
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
                        await operation.service.revoke(submittedId);
                        if (_current(operation)) {
                          setState(() {
                            if (_invitation?.id == submittedId) {
                              _invitation = null;
                              _revoke.clear();
                            }
                            _message = 'Invitation revoked.';
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
              const Text('Invitation context could not be verified. Return and reopen this page from your current workspace.'),
            if (widget.ownerMode && _cannotCreate)
              const Text(
                'Creation is blocked because an earlier issuance is unconfirmed. '
                'An existing code does not rule out another issued invitation. '
                'Confirm the server state with the owner or support; do not restart '
                'the app to retry. This protection is in memory only.',
              ),
          ],
        ),
      ),
    ),
  );
}
