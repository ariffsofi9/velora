import 'package:flutter/material.dart';
import '../../core/theme/app_tokens.dart';

import 'login_page.dart';

/// Signed-out entry. A local cafe photograph can replace the cream fallback
/// in a later asset-only phase; no remote or missing image is requested here.
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  static const _cream = AppColors.background;
  static const _coffee = AppColors.primary;
  static const _mocha = AppColors.textPrimary;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: _cream,
      body: DecoratedBox(
        decoration: const BoxDecoration(color: _cream),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - 48).clamp(
                    0,
                    double.infinity,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    SizedBox(
                      height: (constraints.maxHeight * .10).clamp(24, 90),
                    ),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Image.asset(
                              'assets/images/auth/logo_mark.png',
                              width: 64,
                              height: 64,
                              fit: BoxFit.contain,
                              semanticLabel: 'Velora leaf logo',
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Velora',
                              textAlign: TextAlign.center,
                              style: text.displayMedium?.copyWith(
                                fontFamily: 'Georgia',
                                fontSize: 52,
                                fontWeight: FontWeight.w600,
                                color: _mocha,
                                height: 1.1,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Your Caf\u00e9 Inventory Partner',
                              textAlign: TextAlign.center,
                              style: text.bodyMedium?.copyWith(color: _mocha),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 48),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Smarter Inventory\nfor a Better Caf\u00e9',
                            textAlign: TextAlign.center,
                            style: text.headlineSmall?.copyWith(
                              fontSize: 26,
                              fontWeight: FontWeight.w500,
                              color: _mocha,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 28),
                          FilledButton(
                            onPressed: () => Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const LoginPage(),
                              ),
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: _coffee,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(48, 56),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 16,
                              ),
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              textStyle: text.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            child: const Text(
                              'Get Started',
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
