import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../widgets/auth/auth_layout.dart';
import '../../services/auth_service.dart';
import '../../services/workspace_resolver.dart';
import '../../services/android_pilot_policy.dart';
import '../../services/firebase_startup_config.dart';
import '../team/staff_invitation_page.dart';

import 'signup_page.dart';
import 'forgot_password_page.dart';
import 'welcome_page.dart';
import 'workspace_gate.dart';

class LoginPage extends StatefulWidget {
  final AndroidPilotAuthDependencies? pilot;
  final String? message;
  final AuthService? authService;
  final WorkspaceResolver? workspaceResolver;
  const LoginPage({
    super.key,
    this.pilot,
    this.message,
    this.authService,
    this.workspaceResolver,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  AndroidPilotAuthDependencies? get _pilot =>
      widget.pilot ?? AndroidPilotAuthScope.read(context);
  bool _allows(AndroidPilotCapability capability) =>
      _pilot?.allows(capability) ?? true;
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool hidePassword = true;
  bool isLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.message != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showMessage(widget.message!, false);
      });
    }
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> loginUser({bool joinWithInvitation = false}) async {
    if (isLoading) return;
    if (joinWithInvitation && !_canJoinWithInvitation) return;
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      showMessage('Please enter email and password.', true);
      return;
    }

    setState(() => isLoading = true);

    try {
      final pilot = _pilot;
      final authService =
          pilot?.authService ?? widget.authService ?? AuthService();
      await authService.signIn(email: email, password: password);

      if (!mounted || !identical(pilot, _pilot)) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => joinWithInvitation
              ? StaffInvitationPage(auth: authService.firebaseAuth)
              : WorkspaceGate(
                  pilot: pilot,
                  authService: authService,
                  resolver: widget.workspaceResolver,
                ),
        ),
      );
    } on FirebaseAuthException catch (e) {
      String message = 'Login failed. Please try again.';

      if (e.code == 'user-not-found') {
        message = 'No account found for this email.';
      } else if (e.code == 'wrong-password') {
        message = 'Incorrect password.';
      } else if (e.code == 'invalid-email') {
        message = 'Invalid email address.';
      } else if (e.code == 'invalid-credential') {
        message = 'Invalid email or password.';
      }

      showMessage(message, true);
    } on AuthFlowException catch (error) {
      showMessage(error.message, true);
    } catch (_) {
      showMessage('Something went wrong. Please try again.', true);
    }

    if (mounted) {
      setState(() => isLoading = false);
    }
  }

  bool get _canJoinWithInvitation =>
      _allows(AndroidPilotCapability.teamCallables) &&
      FirebaseStartupProfile.read(context)?.projectId ==
          AndroidPilotPolicy.approvedProject;

  void showMessage(String message, bool isError) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: isError ? AppColors.danger : AppColors.success,
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _pilot?.policy.isValid == false
      ? const PilotAccessBlockedPage()
      : _LoginLayout(
          onBack: isLoading
              ? null
              : () {
                  final navigator = Navigator.of(context);
                  if (navigator.canPop()) {
                    navigator.maybePop();
                  } else {
                    final pilot = _pilot;
                    navigator.pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => WelcomePage(pilot: pilot),
                      ),
                    );
                  }
                },
          children: [
            AuthField(
              label: 'Email address',
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
            ),
            AuthField(
              label: 'Password',
              controller: passwordController,
              obscure: hidePassword,
              suffix: IconButton(
                tooltip: hidePassword ? 'Show password' : 'Hide password',
                icon: Icon(
                  hidePassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: () {
                  setState(() {
                    hidePassword = !hidePassword;
                  });
                },
              ),
            ),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Tooltip(
                  message: 'Remember Me is currently unavailable.',
                  child: MergeSemantics(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(value: false, onChanged: null),
                        Flexible(child: Text('Remember Me')),
                      ],
                    ),
                  ),
                ),
                TextButton(
                  onPressed:
                      isLoading ||
                          !_allows(AndroidPilotCapability.passwordResetEmail)
                      ? null
                      : () {
                          if (!_allows(
                            AndroidPilotCapability.passwordResetEmail,
                          )) {
                            return;
                          }
                          final pilot = _pilot;
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ForgotPasswordPage(
                                initialEmail: emailController.text.trim(),
                                authService:
                                    pilot?.authService ?? widget.authService,
                              ),
                            ),
                          );
                        },
                  child: const Text('Forgot Password?'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            AuthSubmit(label: 'Log In', busy: isLoading, onPressed: loginUser),
            if (_canJoinWithInvitation)
              TextButton(
                onPressed: isLoading
                    ? null
                    : () => loginUser(joinWithInvitation: true),
                child: const Text('Sign in to join with an invitation'),
              ),
            const SizedBox(height: 16),
            const Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('or'),
                ),
                Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 12),
            const OutlinedButton(
              onPressed: null,
              child: Text('Continue with Google', textAlign: TextAlign.center),
            ),
            const SizedBox(height: 6),
            const Text(
              'Google sign-in is currently unavailable.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),
            AuthAccountLink(
              prompt: 'Starting a new workspace?',
              label: 'Owner sign-up',
              onPressed:
                  isLoading || !_allows(AndroidPilotCapability.registration)
                  ? null
                  : () {
                      if (!_allows(AndroidPilotCapability.registration)) return;
                      final pilot = _pilot;
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SignUpPage(
                            pilot: pilot,
                            authService: widget.authService,
                          ),
                        ),
                      );
                    },
            ),
          ],
        );
}

class _LoginLayout extends StatelessWidget {
  const _LoginLayout({required this.onBack, required this.children});

  final VoidCallback? onBack;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const IgnorePointer(child: CustomPaint(painter: _LoginCurves())),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: math.max(0.0, constraints.maxHeight - 36),
                  ),
                  child: Align(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: IconButton(
                              tooltip: 'Back',
                              icon: const BackButtonIcon(),
                              onPressed: onBack,
                            ),
                          ),
                          Center(
                            child: Image.asset(
                              'assets/images/auth/logo_mark.png',
                              width: 48,
                              height: 48,
                              fit: BoxFit.contain,
                              excludeFromSemantics: true,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'VELORA',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontFamily: 'Georgia',
                              fontFamilyFallback: ['Noto Serif', 'serif'],
                              fontSize: 22,
                              letterSpacing: 4,
                              color: Color(0xFF604936),
                            ),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            'Welcome Back',
                            textAlign: TextAlign.center,
                            style: text.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Log in to continue to Velora',
                            textAlign: TextAlign.center,
                            style: text.bodyMedium?.copyWith(
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                          const SizedBox(height: 24),
                          ...children,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoginCurves extends CustomPainter {
  const _LoginCurves();

  @override
  void paint(Canvas canvas, Size size) {
    final extent = math.min(size.shortestSide * .34, 180.0);
    final paint = Paint()
      ..color = AppColors.secondary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    void drawCorner() {
      for (final sweep in [.42, .63]) {
        final path = Path()
          ..moveTo(0, extent * sweep)
          ..cubicTo(
            extent * .42,
            extent * sweep,
            extent * .69,
            extent * .13,
            extent * (1 + sweep),
            0,
          );
        canvas.drawPath(path, paint);
      }
    }

    drawCorner();
    canvas.save();
    canvas.translate(size.width, size.height);
    canvas.rotate(math.pi);
    drawCorner();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LoginCurves oldDelegate) => false;
}
