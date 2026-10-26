import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../widgets/velora_logo.dart';

import 'login_page.dart';
import '../../services/auth_service.dart';

class SignUpPage extends StatefulWidget {
  final AuthService? authService;
  const SignUpPage({super.key, this.authService});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();

  bool hidePassword = true;
  bool hideConfirmPassword = true;
  bool agreeTerms = true;
  bool isLoading = false;

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> createAccount() async {
    if (isLoading) return;
    final name = nameController.text.trim();
    final email = emailController.text.trim();
    final password = passwordController.text.trim();
    final confirmPassword = confirmPasswordController.text.trim();

    if (name.isEmpty ||
        email.isEmpty ||
        password.isEmpty ||
        confirmPassword.isEmpty) {
      showMessage('Please complete all fields.', true);
      return;
    }

    if (!email.contains('@')) {
      showMessage('Please enter a valid email address.', true);
      return;
    }

    if (password.length < 6) {
      showMessage('Password must be at least 6 characters.', true);
      return;
    }

    if (password != confirmPassword) {
      showMessage('Password and confirm password do not match.', true);
      return;
    }

    if (!agreeTerms) {
      showMessage('Please agree to the Terms & Conditions.', true);
      return;
    }

    setState(() => isLoading = true);

    try {
      await (widget.authService ?? AuthService()).register(
        name: name,
        email: email,
        password: password,
      );
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => LoginPage(
            authService: widget.authService,
            message: 'Account created successfully! Please log in.',
          ),
        ),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      String message = 'Sign up failed. Please try again.';

      if (e.code == 'email-already-in-use') {
        message = 'This email is already registered.';
      } else if (e.code == 'invalid-email') {
        message = 'Invalid email address.';
      } else if (e.code == 'weak-password') {
        message = 'Password is too weak.';
      }

      showMessage(message, true);
    } on AuthFlowException catch (error) {
      showMessage(error.message, true);
    } catch (_) {
      showMessage('Something went wrong. Please try again.', true);
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

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

  Widget _brand() {
    // Keyboard height must not change the brand's proportions.
    final logoSize = MediaQuery.sizeOf(context).width < 375 ? 128.0 : 144.0;
    return Column(
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
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          tooltip: 'Back to login',
                          onPressed: isLoading
                              ? null
                              : () {
                                  Navigator.pushReplacement(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => const LoginPage(),
                                    ),
                                  );
                                },
                          icon: const Icon(Icons.arrow_back),
                        ),
                      ),
                      _brand(),
                      const SizedBox(height: AppSpacing.xl),
                      Text(
                        'Create your account',
                        style: text.headlineMedium?.copyWith(
                          fontSize: 28,
                          fontFamily: 'Georgia',
                          fontFamilyFallback: const [
                            'Georgia',
                            'Times New Roman',
                            'serif',
                          ],
                          fontWeight: FontWeight.w400,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Less waste. More room to grow.',
                        textAlign: TextAlign.center,
                        style: text.bodyMedium?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      SizedBox(height: sectionGap),
                      _field(
                        label: 'Full name',
                        controller: nameController,
                        enabled: !isLoading,
                      ),
                      _field(
                        label: 'Email address',
                        controller: emailController,
                        enabled: !isLoading,
                        keyboardType: TextInputType.emailAddress,
                      ),
                      _field(
                        label: 'Password',
                        controller: passwordController,
                        enabled: !isLoading,
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
                          onPressed: isLoading
                              ? null
                              : () {
                                  setState(() => hidePassword = !hidePassword);
                                },
                        ),
                      ),
                      _field(
                        label: 'Confirm password',
                        controller: confirmPasswordController,
                        enabled: !isLoading,
                        obscure: hideConfirmPassword,
                        suffix: IconButton(
                          tooltip: hideConfirmPassword
                              ? 'Show confirmation password'
                              : 'Hide confirmation password',
                          icon: Icon(
                            hideConfirmPassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                          onPressed: isLoading
                              ? null
                              : () {
                                  setState(() {
                                    hideConfirmPassword = !hideConfirmPassword;
                                  });
                                },
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Checkbox(
                            value: agreeTerms,
                            activeColor: AppColors.primaryDark,
                            materialTapTargetSize: MaterialTapTargetSize.padded,
                            onChanged: isLoading
                                ? null
                                : (value) {
                                    setState(() => agreeTerms = value ?? false);
                                  },
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: AppSpacing.md,
                              ),
                              child: Text(
                                'I agree to the Terms & Conditions.',
                                style: text.bodyMedium,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          border: Border.all(color: AppColors.border),
                          borderRadius: BorderRadius.circular(AppRadius.card),
                        ),
                        child: Text(
                          'Create your account, then log in to get started.',
                          style: text.bodyMedium,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      _submit('Create account', createAccount),
                      const SizedBox(height: AppSpacing.xl),
                      Text(
                        'Already have an account?',
                        style: text.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                      TextButton(
                        onPressed: isLoading
                            ? null
                            : () {
                                Navigator.pushReplacement(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const LoginPage(),
                                  ),
                                );
                              },
                        child: const Text('Login'),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Text(
                        'Google and Apple sign-in are currently unavailable.',
                        style: text.bodySmall?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                        textAlign: TextAlign.center,
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
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              top: -20,
              right: -20,
              child: _art(
                'leaf_small_1.png',
                (width * .34).clamp(0.0, 180.0),
                .8,
              ),
            ),
            if (MediaQuery.viewInsetsOf(context).bottom == 0)
              Positioned(
                bottom: 0,
                left: -20,
                child: _art(
                  'bg_bottom_left.png',
                  (width * .8).clamp(0.0, 460.0),
                  .5,
                ),
              ),
            child,
          ],
        );
      },
    );
  }
}
