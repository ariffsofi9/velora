import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../widgets/auth/auth_layout.dart';

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

  Widget _visibility(bool hidden, VoidCallback toggle, String tooltip) =>
      IconButton(
        tooltip: hidden ? 'Show $tooltip' : 'Hide $tooltip',
        icon: Icon(
          hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
        onPressed: toggle,
      );

  @override
  Widget build(BuildContext context) => AuthLayout(
    title: 'Create an Account',
    subtitle: "Let's get started with Velora.",
    onBack: isLoading
        ? null
        : () {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const LoginPage()),
            );
          },
    children: [
      AuthField(
        label: 'Full name',
        controller: nameController,
        enabled: !isLoading,
      ),
      AuthField(
        label: 'Email address',
        controller: emailController,
        enabled: !isLoading,
        keyboardType: TextInputType.emailAddress,
      ),
      AuthField(
        label: 'Password',
        controller: passwordController,
        enabled: !isLoading,
        obscure: hidePassword,
        suffix: _visibility(hidePassword, () {
          setState(() {
            hidePassword = !hidePassword;
          });
        }, 'password'),
      ),
      AuthField(
        label: 'Confirm password',
        controller: confirmPasswordController,
        enabled: !isLoading,
        obscure: hideConfirmPassword,
        suffix: _visibility(hideConfirmPassword, () {
          setState(() {
            hideConfirmPassword = !hideConfirmPassword;
          });
        }, 'confirm password'),
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: agreeTerms,
        onChanged: isLoading
            ? null
            : (value) {
                setState(() {
                  agreeTerms = value ?? false;
                });
              },
        title: const Text(
          'I agree to the Terms & Conditions.',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(height: 16),
      AuthSubmit(
        label: 'Create Account',
        busy: isLoading,
        onPressed: createAccount,
      ),
      const SizedBox(height: 24),
      AuthAccountLink(
        prompt: 'Already have an account?',
        label: 'Log in',
        onPressed: isLoading
            ? null
            : () {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                );
              },
      ),
      const Text(
        'Google sign-in is currently unavailable.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
      ),
    ],
  );
}
