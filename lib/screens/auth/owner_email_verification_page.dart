import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/theme/app_tokens.dart';
import '../../services/owner_email_verification.dart';
import 'login_page.dart';

class OwnerEmailVerificationPage extends StatefulWidget {
  final OwnerEmailVerification verification;
  final WidgetBuilder? verifiedBuilder;
  final WidgetBuilder? loginBuilder;
  const OwnerEmailVerificationPage({
    super.key,
    required this.verification,
    this.verifiedBuilder,
    this.loginBuilder,
  });
  @override
  State<OwnerEmailVerificationPage> createState() =>
      _OwnerEmailVerificationPageState();
}

class _OwnerEmailVerificationPageState
    extends State<OwnerEmailVerificationPage> {
  bool _busy = false;
  bool _routed = false;
  String _message = 'Verify your email before creating a workspace.';
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _check(); // Refresh only: never sends an email or creates a workspace automatically.
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_busy || _routed) return;
    setState(() => _busy = true);
    try {
      final verified = await widget.verification.refreshVerified();
      if (!mounted || _routed) return;
      if (verified) {
        _routed = true;
        if (widget.verifiedBuilder == null) {
          Navigator.of(context).pop(true);
        } else {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: widget.verifiedBuilder!),
          );
        }
      } else {
        setState(
          () => _message =
              'Verification is still pending. Open your email link, then check again.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'Verification could not be checked. Check your connection or sign in again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    if (_busy || _routed) return;
    setState(() => _busy = true);
    try {
      await widget.verification.sendVerification();
      if (mounted) {
        setState(
          () => _message =
              'Verification email requested. Check your inbox and spam folder.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'Verification email could not be confirmed. Check your inbox, wait before retrying or sign in again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy || _routed) return;
    setState(() => _busy = true);
    try {
      await widget.verification.signOut();
      if (!mounted) return;
      _routed = true;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: widget.loginBuilder ?? (_) => const LoginPage(),
        ),
        (_) => false,
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Sign-out could not be confirmed. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wait = (widget.verification.resendRemaining.inMilliseconds / 1000)
        .ceil();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Sign out and return to Login',
            onPressed: _busy ? null : _leave,
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Verify your email',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(_message),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton(
                    key: const ValueKey('owner-check-verification'),
                    onPressed: _busy ? null : _check,
                    child: const Text('I have verified my email'),
                  ),
                  OutlinedButton(
                    key: const ValueKey('owner-send-verification'),
                    onPressed: _busy || wait > 0 ? null : _send,
                    child: Text(
                      wait > 0
                          ? 'Resend available in ${wait}s'
                          : 'Send / resend verification email',
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _leave,
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
