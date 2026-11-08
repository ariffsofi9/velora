import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/staff_invitation_service.dart';
import '../../services/firebase_emulator_config.dart';
import '../auth/workspace_gate.dart';

class StaffInvitationPage extends StatefulWidget {
  final bool ownerMode;
  final StaffInvitations? invitations;
  final FirebaseAuth? auth;
  final VoidCallback? onJoined;
  const StaffInvitationPage({
    super.key,
    this.ownerMode = false,
    this.invitations,
    this.auth,
    this.onJoined,
  });
  @override
  State<StaffInvitationPage> createState() => _StaffInvitationPageState();
}

class _StaffInvitationPageState extends State<StaffInvitationPage> {
  final _entry = TextEditingController();
  final _revoke = TextEditingController();
  StaffInvitation? _invitation;
  bool _busy = false;
  String? _message;
  StaffInvitations get _service =>
      widget.invitations ?? FirebaseStaffInvitations(auth: widget.auth);

  @override
  void dispose() {
    _entry.dispose();
    _revoke.dispose();
    _invitation = null;
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
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
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _available =>
      widget.invitations != null || FirebaseEmulatorConfig.invitationsAvailable;

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
              onPressed: _busy || !_available
                  ? null
                  : () => _run(() async {
                      if (widget.ownerMode) {
                        setState(() => _invitation = null);
                        final result = await _service.create(
                          _entry.text.trim(),
                        );
                        if (!mounted) return;
                        setState(() {
                          _invitation = result;
                          _revoke.text = result.id;
                        });
                      } else {
                        await _service.redeem(_entry.text);
                        if (!context.mounted) return;
                        _entry.clear();
                        if (widget.onJoined != null) {
                          widget.onJoined!();
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
                    : () => _run(() async {
                        final user =
                            (widget.auth ?? FirebaseAuth.instance).currentUser;
                        if (user == null) throw StateError('Sign in required.');
                        await user.sendEmailVerification();
                        if (mounted) {
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
                    : () => _run(() async {
                        await _service.revoke(_revoke.text.trim());
                        if (mounted) {
                          setState(() {
                            _invitation = null;
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
          ],
        ),
      ),
    ),
  );
}
