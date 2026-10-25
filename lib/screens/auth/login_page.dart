import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../widgets/velora_logo.dart';

import 'signup_page.dart';
import 'forgot_password_page.dart';
import '../home/home_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool hidePassword = true;
  bool isLoading = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> loginUser() async {
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      showMessage('Please enter email and password.', true);
      return;
    }

    setState(() => isLoading = true);

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomePage()),
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
    } catch (_) {
      showMessage('Something went wrong. Please try again.', true);
    }

    if (mounted) {
      setState(() => isLoading = false);
    }
  }

  void showMessage(String message, bool isError) {
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

  Widget _brand() {
    // Keyboard height must not change the brand's proportions.
    final logoSize = MediaQuery.sizeOf(context).width < 375 ? 144.0 : 160.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        VeloraLogo(size: logoSize),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'SMART CAFÉ INVENTORY',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            letterSpacing: 2.4,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: TextField(
        controller: controller,
        enabled: enabled,
        obscureText: obscure,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          floatingLabelBehavior: FloatingLabelBehavior.never,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: 18,
          ),
          prefixIcon: Icon(
            keyboardType == TextInputType.emailAddress
                ? Icons.mail_outline
                : label == 'Full name'
                ? Icons.person_outline
                : Icons.lock_outline,
            size: 20,
            color: AppColors.textSecondary,
          ),
          suffixIcon: suffix,
        ),
      ),
    );
  }

  Widget _submit(String label, VoidCallback action) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: isLoading ? null : action,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          textStyle: Theme.of(context).textTheme.titleMedium,
        ),
        child: isLoading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.primaryDark,
                  semanticsLabel: 'Please wait',
                ),
              )
            : Text('$label  →', textAlign: TextAlign.center),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final media = MediaQuery.of(context);
    final compact =
        media.size.width < 375 ||
        media.size.height - media.viewInsets.bottom < 650;
    final sectionGap = compact ? AppSpacing.xl : AppSpacing.xxl;
    return ColoredBox(
      color: AppColors.background,
      child: _BotanicalFrame(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: _FormViewport(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: compact ? 40 : 72),
                      _brand(),
                      SizedBox(height: sectionGap),
                      Text(
                        'Welcome back',
                        style: text.headlineMedium?.copyWith(
                          fontSize: 34,
                          fontFamily: 'Georgia',
                          fontFamilyFallback: const [
                            'Georgia',
                            'Times New Roman',
                            'serif',
                          ],
                          fontWeight: FontWeight.w400,
                        ),
                        textAlign: TextAlign.left,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'A calmer day at your café starts here.',
                        style: text.bodyMedium?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                        textAlign: TextAlign.left,
                      ),
                      SizedBox(height: sectionGap),
                      _field(
                        label: 'Email address',
                        controller: emailController,
                        keyboardType: TextInputType.emailAddress,
                      ),
                      _field(
                        label: 'Password',
                        controller: passwordController,
                        obscure: hidePassword,
                        suffix: IconButton(
                          tooltip: hidePassword
                              ? 'Show password'
                              : 'Hide password',
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
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: isLoading
                              ? null
                              : () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          const ForgotPasswordPage(),
                                    ),
                                  );
                                },
                          child: const Text('Forgot Password?'),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      _submit('Sign In', loginUser),
                      const SizedBox(height: AppSpacing.xl),
                      Text(
                        "Don't have an account?",
                        textAlign: TextAlign.center,
                        style: text.bodyMedium,
                      ),
                      TextButton(
                        onPressed: isLoading
                            ? null
                            : () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const SignUpPage(),
                                  ),
                                );
                              },
                        child: const Text('Register'),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Text(
                        'Google sign-in is currently unavailable.',
                        textAlign: TextAlign.center,
                        style: text.bodySmall?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Size the viewport, not the text: system text scaling remains unchanged.
class _FormViewport extends StatelessWidget {
  final Widget child;
  const _FormViewport({required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < 375 || constraints.maxHeight < 650;
        final padding = compact ? AppSpacing.lg : AppSpacing.xl;
        return SingleChildScrollView(
          padding: EdgeInsets.all(padding),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (constraints.maxHeight - padding * 2).clamp(
                0.0,
                double.infinity,
              ),
            ),
            child: Align(alignment: Alignment.topCenter, child: child),
          ),
        );
      },
    );
  }
}

// Artwork is decorative, excluded from semantics, and never handles taps.
class _BotanicalFrame extends StatelessWidget {
  final Widget child;

  const _BotanicalFrame({required this.child});

  Widget _art(String filename, double width, double opacity) {
    return IgnorePointer(
      child: Opacity(
        opacity: opacity,
        child: Image.asset(
          'assets/images/auth/$filename',
          width: width,
          fit: BoxFit.contain,
          excludeFromSemantics: true,
          // Omit unavailable or undecodable decoration without blocking the form.
          errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // The cup occupies only part of this transparent corner composition.
        // Enlarge the sheet and crop its edge, rather than distorting the cup.
        final coffeeWidth = (width * .92)
            .clamp(0.0, 480.0)
            .clamp(0.0, constraints.maxHeight * .52);
        return Stack(
          fit: StackFit.expand,
          children: [
            const Positioned(
              top: 24,
              left: 4,
              child: IgnorePointer(
                child: CustomPaint(
                  size: Size(36, 60),
                  painter: _CornerDetailPainter(),
                ),
              ),
            ),
            Positioned(
              top: -coffeeWidth * .18,
              right: -coffeeWidth * .17,
              child: _art('bg_top_right.png', coffeeWidth, 1),
            ),
            if (MediaQuery.viewInsetsOf(context).bottom == 0)
              Positioned(
                bottom: -12,
                right: -20,
                child: IgnorePointer(
                  child: CustomPaint(
                    size: Size(
                      (width * .8).clamp(0.0, 440.0),
                      (constraints.maxHeight * .16).clamp(0.0, 150.0),
                    ),
                    painter: const _CornerDetailPainter(bottom: true),
                  ),
                ),
              ),
            if (MediaQuery.viewInsetsOf(context).bottom == 0)
              Positioned(
                bottom: 0,
                left: 0,
                child: _art(
                  'bg_bottom_left.png',
                  (width * .65).clamp(0.0, 360.0),
                  .24,
                ),
              ),
            child,
          ],
        );
      },
    );
  }
}

class _CornerDetailPainter extends CustomPainter {
  final bool bottom;
  const _CornerDetailPainter({this.bottom = false});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (bottom) {
      Path wave(double crest) => Path()
        ..moveTo(0, size.height)
        ..cubicTo(
          size.width * .4,
          size.height * .88,
          size.width * .63,
          size.height * crest,
          size.width,
          size.height * .08,
        )
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(
        wave(.62),
        Paint()..color = AppColors.primary.withValues(alpha: .12),
      );
      canvas.drawPath(
        wave(.92),
        Paint()..color = AppColors.primary.withValues(alpha: .16),
      );
      canvas.drawPath(
        Path()
          ..moveTo(size.width * .08, size.height)
          ..cubicTo(
            size.width * .52,
            size.height * .78,
            size.width * .64,
            size.height * .3,
            size.width,
            size.height * .02,
          ),
        Paint()
          ..color = const Color(0xFFB7A276).withValues(alpha: .48)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8,
      );
    } else {
      final dots = Paint()
        ..color = AppColors.primaryDark.withValues(alpha: .45);
      for (final point in const [
        Offset(9, 5),
        Offset(21, 17),
        Offset(9, 30),
        Offset(21, 43),
        Offset(9, 55),
      ]) {
        canvas.drawCircle(point, 2.1, dots);
      }
      canvas.drawPath(
        Path()
          ..moveTo(0, 58)
          ..quadraticBezierTo(34, 37, 30, 0),
        Paint()
          ..color = AppColors.primary.withValues(alpha: .16)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CornerDetailPainter oldDelegate) =>
      oldDelegate.bottom != bottom;
}
