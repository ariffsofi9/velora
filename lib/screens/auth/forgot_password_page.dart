import 'package:flutter/material.dart';
import 'login_page.dart';
import '../../core/theme/app_tokens.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final emailController = TextEditingController();

  @override
  void dispose() {
    emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ColoredBox(
      color: AppColors.background,
      child: CustomPaint(
        painter: _BotanicalPainter(),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          tooltip: 'Back to login',
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () {
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const LoginPage(),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      Center(
                        child: Container(
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: .2),
                            borderRadius: BorderRadius.circular(AppRadius.card),
                          ),
                          child: const Stack(
                            alignment: Alignment.center,
                            children: [
                              Icon(
                                Icons.lock_outline,
                                size: 40,
                                color: AppColors.primaryDark,
                              ),
                              Positioned(
                                top: 8,
                                right: 8,
                                child: Icon(
                                  Icons.eco_outlined,
                                  size: 24,
                                  color: AppColors.primaryDark,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      Text(
                        'Velora',
                        textAlign: TextAlign.center,
                        style: text.headlineLarge?.copyWith(
                          fontFamily: 'Georgia',
                          fontFamilyFallback: const [
                            'Georgia',
                            'Times New Roman',
                            'serif',
                          ],
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'SMART CAFÉ INVENTORY',
                        textAlign: TextAlign.center,
                        style: text.labelSmall?.copyWith(letterSpacing: 3),
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      Text(
                        'Forgot password?',
                        textAlign: TextAlign.center,
                        style: text.headlineMedium?.copyWith(
                          fontFamily: 'Georgia',
                          fontFamilyFallback: const [
                            'Georgia',
                            'Times New Roman',
                            'serif',
                          ],
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        "No worries, we'll send reset instructions to your email.",
                        textAlign: TextAlign.center,
                        style: text.bodyMedium?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      TextField(
                        controller: emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email address',
                          prefixIcon: Icon(
                            Icons.mail_outline,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      FilledButton(
                        onPressed: () {},
                        child: const Text('Send Reset Link'),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      TextButton(
                        onPressed: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const LoginPage(),
                            ),
                          );
                        },
                        child: const Text('Back to Login'),
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

// Decorative painting stays behind content and has no hit-testing widgets.
class _BotanicalPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final wash = Paint()..color = AppColors.primary.withValues(alpha: .13);
    canvas.drawOval(Rect.fromLTWH(-90, -100, size.width * .55, 190), wash);
    canvas.drawOval(
      Rect.fromLTWH(size.width * .65, size.height - 75, size.width * .6, 170),
      wash,
    );
    final curve = Paint()
      ..color = AppColors.primaryDark.withValues(alpha: .18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawPath(
      Path()
        ..moveTo(0, 160)
        ..cubicTo(
          size.width * .1,
          110,
          size.width * .35,
          100,
          size.width * .38,
          0,
        ),
      curve,
    );
    canvas.drawPath(
      Path()
        ..moveTo(size.width * .35, size.height)
        ..cubicTo(
          size.width * .6,
          size.height - 95,
          size.width * .85,
          size.height - 10,
          size.width,
          size.height - 130,
        ),
      curve,
    );
    void sprig(double x, double y, double rotation) {
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(rotation);
      final stem = Paint()
        ..color = AppColors.primaryDark.withValues(alpha: .55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawPath(
        Path()
          ..moveTo(0, 0)
          ..quadraticBezierTo(12, 45, 0, 100),
        stem,
      );
      for (var i = 0; i < 4; i++) {
        final y = 15.0 + i * 20;
        final side = i.isEven ? 1.0 : -1.0;
        final leaf = Path()
          ..moveTo(5, y)
          ..quadraticBezierTo(side * 36, y - 28, side * 32, y - 3)
          ..quadraticBezierTo(side * 22, y + 12, 5, y);
        canvas.drawPath(
          leaf,
          Paint()
            ..color = AppColors.primaryDark.withValues(alpha: .24 + i * .04),
        );
        canvas.drawLine(Offset(5, y), Offset(side * 29, y - 3), stem);
      }
      canvas.restore();
    }

    sprig(size.width - 8, -10, .35);
    sprig(8, size.height - 10, 3.4);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BotanicalPainter oldDelegate) => false;
}
