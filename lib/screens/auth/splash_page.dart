import 'dart:async';

import '../../services/auth_service.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

import '../home/home_page.dart';
import 'welcome_page.dart';

class SplashPage extends StatefulWidget {
  final AuthService? authService;
  const SplashPage({super.key, this.authService});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    checkLoginStatus();
  }

  Future<void> checkLoginStatus() async {
    await Future.delayed(const Duration(seconds: 3));

    if (!mounted) return;

    var restoreSession = false;
    try {
      restoreSession = await (widget.authService ?? AuthService())
          .canRestoreSession();
    } catch (_) {
      // Storage/auth recovery failures must never grant automatic access.
    }
    if (!mounted) return;
    if (restoreSession) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomePage()),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const WelcomePage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    body: Stack(
      children: [
        const Positioned.fill(
          child: IgnorePointer(child: CustomPaint(painter: _EntryCurves())),
        ),
        SafeArea(
          child: LayoutBuilder(
            builder: (context, size) => SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (size.maxHeight - 56).clamp(0, double.infinity),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    SizedBox(height: (size.maxHeight * .08).clamp(24, 72)),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Velora',
                                style: Theme.of(context).textTheme.displayLarge
                                    ?.copyWith(
                                      fontFamily: 'Georgia',
                                      color: AppColors.textPrimary,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                              const SizedBox(width: 8),
                              Image.asset(
                                'assets/images/auth/logo_mark.png',
                                width: 48,
                                height: 48,
                                fit: BoxFit.contain,
                                semanticLabel: 'Velora leaf logo',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'AI Smart Inventory\nfor F&B Businesses',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w400),
                        ),
                      ],
                    ),
                    const SizedBox(height: 48),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Manage ingredients.\nReduce waste.\nCreate more possibilities.',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w400),
                        ),
                        const SizedBox(height: 24),
                        const LinearProgressIndicator(
                          color: AppColors.primary,
                          backgroundColor: AppColors.nude,
                          minHeight: 2,
                          semanticsLabel: 'Loading Velora',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _EntryCurves extends CustomPainter {
  const _EntryCurves();
  @override
  void paint(Canvas canvas, Size size) {
    final wash = Paint()..color = AppColors.nude.withValues(alpha: .38);
    final top = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width * .68, 0)
      ..quadraticBezierTo(
        size.width * .34,
        size.height * .20,
        0,
        size.height * .18,
      )
      ..close();
    canvas.drawPath(top, wash);
    final bottom = Path()
      ..moveTo(0, size.height * .66)
      ..quadraticBezierTo(
        size.width * .25,
        size.height * .80,
        size.width,
        size.height * .68,
      )
      ..quadraticBezierTo(
        size.width * .45,
        size.height * .98,
        0,
        size.height * .82,
      )
      ..close();
    canvas.drawPath(
      bottom,
      Paint()..color = AppColors.nude.withValues(alpha: .20),
    );
  }

  @override
  bool shouldRepaint(covariant _EntryCurves oldDelegate) => false;
}
