import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../widgets/auth/auth_layout.dart';
import '../../services/auth_service.dart';
import '../../services/workspace_resolver.dart';

import 'signup_page.dart';
import 'forgot_password_page.dart';
import 'workspace_gate.dart';

class LoginPage extends StatefulWidget {
  final String? message;
  final AuthService? authService;
  final WorkspaceResolver? workspaceResolver;
  const LoginPage({
    super.key,
    this.message,
    this.authService,
    this.workspaceResolver,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
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

  Future<void> loginUser() async {
    if (isLoading) return;
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      showMessage('Please enter email and password.', true);
      return;
    }

    setState(() => isLoading = true);

    try {
      await (widget.authService ?? AuthService()).signIn(
        email: email,
        password: password,
      );

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => WorkspaceGate(resolver: widget.workspaceResolver),
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
  Widget build(BuildContext context) => AuthLayout(
    title: 'Welcome Back',
    subtitle: 'Log in to continue to Velora',
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
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: isLoading
              ? null
              : () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ForgotPasswordPage(
                        initialEmail: emailController.text.trim(),
                        authService: widget.authService,
                      ),
                    ),
                  );
                },
          child: const Text('Forgot Password?'),
        ),
      ),
      const SizedBox(height: 8),
      AuthSubmit(label: 'Log In', busy: isLoading, onPressed: loginUser),
      const SizedBox(height: 24),
      AuthAccountLink(
        prompt: "Don't have an account?",
        label: 'Sign up',
        onPressed: isLoading
            ? null
            : () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SignUpPage()),
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
