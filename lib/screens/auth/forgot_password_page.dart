import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../services/auth_service.dart';
import 'login_page.dart';

const _ivory = Color(0xFFFAF9F6);
const _sage = Color(0xFF55745B);
const _forest = Color(0xFF203B30);

class ForgotPasswordPage extends StatefulWidget {
  static const confirmationMessage =
      'If an account exists for this email, a password reset link will be sent.';
  final String initialEmail;
  final AuthService? authService;

  const ForgotPasswordPage({
    super.key,
    this.initialEmail = '',
    this.authService,
  });

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _email;
  bool _loading = false;
  bool _feedbackError = false;
  String? _feedback;
  int _cooldown = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _email = TextEditingController(text: widget.initialEmail.trim());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    super.dispose();
  }

  void _showFeedback(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _feedback = message;
      _feedbackError = error;
    });
  }

  Future<void> _send() async {
    if (_loading || _cooldown > 0 || !_form.currentState!.validate()) return;
    final address = _email.text.trim();
    setState(() {
      _loading = true;
      _feedback = null;
    });
    try {
      await (widget.authService ?? AuthService()).sendPasswordResetEmail(
        email: address,
      );
      if (!mounted) return;
      setState(() => _cooldown = 60);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _cooldown = (60 - timer.tick).clamp(0, 60));
        if (_cooldown == 0) timer.cancel();
      });
      _showFeedback(ForgotPasswordPage.confirmationMessage);
    } on FirebaseAuthException catch (error) {
      _showFeedback(switch (error.code) {
        'invalid-email' => 'Please enter a valid email address.',
        'network-request-failed' =>
          'Check your internet connection and try again.',
        'too-many-requests' =>
          'Too many requests. Please wait a while before trying again.',
        _ =>
          'Unable to request a reset link right now. Please try again later.',
      }, error: true);
    } catch (_) {
      _showFeedback(
        'Unable to request a reset link right now. Please try again later.',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _backToLogin() {
    if (_loading) return;
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => LoginPage(authService: widget.authService),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: AppColors.border),
    );
    return Scaffold(
      backgroundColor: _ivory,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: EdgeInsets.all(constraints.maxWidth < 360 ? 16 : 24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Form(
                    key: _form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton(
                            tooltip: 'Back to Login',
                            onPressed: _loading ? null : _backToLogin,
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            icon: const Icon(Icons.arrow_back, color: _forest),
                          ),
                        ),
                        const SizedBox(height: 32),
                        const Icon(Icons.lock_outline, size: 36, color: _sage),
                        const SizedBox(height: 24),
                        Semantics(
                          header: true,
                          child: Text(
                            'Forgot password?',
                            textAlign: TextAlign.center,
                            style: text.headlineSmall?.copyWith(
                              color: _forest,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          "Enter your email and we'll send you a password reset link.",
                          textAlign: TextAlign.center,
                          style: text.bodyMedium?.copyWith(
                            color: const Color(0xFF6B7280),
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 32),
                        TextFormField(
                          controller: _email,
                          enabled: !_loading,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.done,
                          autofillHints: const [AutofillHints.email],
                          autocorrect: false,
                          enableSuggestions: false,
                          validator: (value) =>
                              AuthService.isValidResetEmail(value ?? '')
                              ? null
                              : 'Please enter a valid email address.',
                          onFieldSubmitted: (_) {
                            _send();
                          },
                          onChanged: (_) {
                            if (_feedback != null) {
                              setState(() => _feedback = null);
                            }
                          },
                          decoration: InputDecoration(
                            labelText: 'Email address',
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.all(16),
                            constraints: const BoxConstraints(minHeight: 52),
                            prefixIcon: const Icon(
                              Icons.mail_outline,
                              color: _sage,
                            ),
                            border: border,
                            enabledBorder: border,
                            focusedBorder: border.copyWith(
                              borderSide: const BorderSide(
                                color: _sage,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _sage,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: AppColors.border,
                            disabledForegroundColor: _forest,
                            minimumSize: const Size.fromHeight(52),
                            padding: const EdgeInsets.all(16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: _loading || _cooldown > 0 ? null : _send,
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (_loading)
                                const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _sage,
                                  ),
                                ),
                              Text(
                                _loading
                                    ? 'Sending Reset Link'
                                    : _cooldown > 0
                                    ? 'Send again in ${_cooldown}s'
                                    : 'Send Reset Link',
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                        if (_feedback != null) ...[
                          const SizedBox(height: 16),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _feedback!,
                              textAlign: TextAlign.center,
                              style: text.bodyMedium?.copyWith(
                                color: _feedbackError
                                    ? AppColors.danger
                                    : _forest,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          'Check your inbox and spam folder.',
                          textAlign: TextAlign.center,
                          style: text.bodySmall?.copyWith(
                            color: const Color(0xFF6B7280),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: _loading ? null : _backToLogin,
                          style: TextButton.styleFrom(
                            foregroundColor: _sage,
                            minimumSize: const Size(48, 48),
                          ),
                          child: const Text('Back to Login'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
