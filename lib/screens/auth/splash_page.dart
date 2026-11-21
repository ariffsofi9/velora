import 'dart:async';
import 'dart:math' as math;

import '../../services/auth_service.dart';
import '../../services/workspace_resolver.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';

import 'welcome_page.dart';
import 'workspace_gate.dart';

class SplashPage extends StatefulWidget {
  final AndroidPilotAuthDependencies? pilot;
  final AuthService? authService;
  final WorkspaceResolver? workspaceResolver;
  const SplashPage({
    super.key,
    this.authService,
    this.workspaceResolver,
    this.pilot,
  });

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  AndroidPilotAuthDependencies? get _pilot =>
      widget.pilot ?? AndroidPilotAuthScope.read(context);
  @override
  void initState() {
    super.initState();
    checkLoginStatus();
  }

  Future<void> checkLoginStatus() async {
    await Future.delayed(const Duration(seconds: 3));

    if (!mounted) return;

    final pilot = _pilot;
    final authService =
        pilot?.authService ?? widget.authService ?? AuthService();
    var restoreSession = false;
    try {
      restoreSession = await authService.canRestoreSession();
    } catch (_) {
      // Storage/auth recovery failures must never grant automatic access.
    }
    if (!mounted || !identical(pilot, _pilot)) return;
    if (restoreSession) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => WorkspaceGate(
            pilot: pilot,
            authService: authService,
            resolver: widget.workspaceResolver,
          ),
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => WelcomePage(pilot: pilot)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => _pilot?.policy.isValid == false
      ? const PilotAccessBlockedPage()
      : Scaffold(
          backgroundColor: _ivory,
          body: Stack(
            fit: StackFit.expand,
            children: [
              const IgnorePointer(child: CustomPaint(painter: _CornerLines())),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxHeight < 420;
                      return SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                            minWidth: constraints.maxWidth,
                          ),
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: _SplashBrand(compact: compact),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
}

const _ivory = Color(0xFFFBF7F0);
const _deepBrown = Color(0xFF604936);
const _lineBrown = Color(0xFFCAB596);

class _SplashBrand extends StatelessWidget {
  const _SplashBrand({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: compact ? 58 : 80,
        height: compact ? 46 : 64,
        child: const CustomPaint(painter: _LeafEmblem()),
      ),
      SizedBox(height: compact ? 8 : 16),
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Semantics(
          header: true,
          child: Text(
            'VELORA',
            semanticsLabel: 'Velora',
            style: TextStyle(
              fontFamily: 'Georgia',
              fontFamilyFallback: const ['Noto Serif', 'serif'],
              fontSize: compact ? 44 : 60,
              fontWeight: FontWeight.w400,
              height: 1.1,
              letterSpacing: compact ? 6 : 9,
              color: _deepBrown,
            ),
          ),
        ),
      ),
      SizedBox(height: compact ? 12 : 20),
      const SizedBox(
        width: 140,
        child: Row(
          children: [
            Expanded(child: Divider(color: _lineBrown, thickness: 1)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CustomPaint(painter: _LeafEmblem(single: true)),
              ),
            ),
            Expanded(child: Divider(color: _lineBrown, thickness: 1)),
          ],
        ),
      ),
      SizedBox(height: compact ? 10 : 16),
      Text(
        'AI SMART INVENTORY\nFOR F&B BUSINESSES',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: compact ? 10 : 11,
          color: _deepBrown,
          fontWeight: FontWeight.w600,
          height: 1.7,
          letterSpacing: compact ? 1.5 : 2,
        ),
      ),
      SizedBox(height: compact ? 18 : 28),
      const SizedBox(
        width: 48,
        child: LinearProgressIndicator(
          color: AppColors.primary,
          backgroundColor: AppColors.secondary,
          minHeight: 2,
          semanticsLabel: 'Loading Velora',
        ),
      ),
    ],
  );
}

class _LeafEmblem extends CustomPainter {
  const _LeafEmblem({this.single = false});

  final bool single;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 80, size.height / 64);
    if (single) {
      _leaf(canvas, const Offset(23, 55), .72, 1.13, AppColors.primary);
    } else {
      _leaf(canvas, const Offset(39, 58), -0.62, .82, AppColors.primary);
      _leaf(canvas, const Offset(40, 56), .13, 1.2, _deepBrown);
      _leaf(canvas, const Offset(42, 58), .83, .86, AppColors.primary);
    }
    canvas.restore();
  }

  void _leaf(
    Canvas canvas,
    Offset origin,
    double angle,
    double scale,
    Color color,
  ) {
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.rotate(angle);
    canvas.scale(scale);
    final shape = Path()
      ..moveTo(0, 0)
      ..cubicTo(-24, -19, -9, -41, 0, -46)
      ..cubicTo(13, -34, 17, -12, 0, 0)
      ..close();
    canvas.drawPath(shape, Paint()..color = color);
    final vein = Path()
      ..moveTo(0, -4)
      ..quadraticBezierTo(-3, -18, 0, -36);
    canvas.drawPath(
      vein,
      Paint()
        ..color = _ivory.withValues(alpha: .75)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LeafEmblem oldDelegate) =>
      oldDelegate.single != single;
}

class _CornerLines extends CustomPainter {
  const _CornerLines();

  @override
  void paint(Canvas canvas, Size size) {
    final extent = (size.shortestSide * .45).clamp(0.0, 240.0);
    final paint = Paint()
      ..color = _lineBrown.withValues(alpha: .58)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .9;

    void drawCorner() {
      for (final offset in [0.0, .16, .32]) {
        final curve = Path()
          ..moveTo(0, extent * (.83 - offset))
          ..cubicTo(
            extent * .40,
            extent * (.88 - offset),
            extent * (.53 + offset),
            extent * .34,
            extent * (1.12 + offset),
            0,
          );
        canvas.drawPath(curve, paint);
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
  bool shouldRepaint(covariant _CornerLines oldDelegate) => false;
}
