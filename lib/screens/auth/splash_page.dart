import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../widgets/velora_logo.dart';

import '../home/home_page.dart';
import 'login_page.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

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

    final user = FirebaseAuth.instance.currentUser;

    if (user != null) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomePage()),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _BotanicalFrame(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact =
                  constraints.maxWidth < 375 || constraints.maxHeight < 650;
              final logoSize = compact ? 196.0 : 216.0;
              final sectionGap = compact ? AppSpacing.xl : AppSpacing.xxl;
              return SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - AppSpacing.xl * 2)
                        .clamp(0.0, double.infinity),
                  ),
                  child: Center(
                    child: SizedBox(
                      width: 440,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          VeloraLogo(size: logoSize),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            'SMART CAFÉ INVENTORY',
                            textAlign: TextAlign.center,
                            style: text.labelSmall?.copyWith(
                              letterSpacing: compact ? 2 : 3,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          SizedBox(height: sectionGap),
                          Container(
                            width: 28,
                            height: 1,
                            color: AppColors.primaryDark,
                          ),
                          const SizedBox(height: AppSpacing.xl),
                          Text(
                            'Smarter Food,\nBetter Business',
                            textAlign: TextAlign.center,
                            style: text.bodyLarge?.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                          SizedBox(height: sectionGap),
                          const SizedBox(
                            width: 38,
                            height: 38,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: AppColors.primaryDark,
                              semanticsLabel: 'Loading Velora',
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          Text(
                            'Preparing your caf\u00e9 space...',
                            style: text.bodySmall,
                            textAlign: TextAlign.center,
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
      ),
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
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              top: -12,
              left: -28,
              child: _art(
                'bg_top_left.png',
                (width * .8).clamp(0.0, 420.0),
                .85,
              ),
            ),
            Positioned(
              bottom: 0,
              right: -12,
              child: _art(
                'bg_bottom_right.png',
                (width * 1.05).clamp(0.0, 680.0),
                .85,
              ),
            ),
            Positioned(
              bottom: 70,
              left: -35,
              child: _art(
                'leaf_small_2.png',
                (width * .4).clamp(0.0, 200.0),
                .8,
              ),
            ),
            child,
          ],
        );
      },
    );
  }
}
