import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../models/cafe_workspace.dart';
import '../../services/workspace_resolver.dart';
import '../business_setup/business_setup_page.dart';
import '../home/home_page.dart';

/// Resolves trusted membership before exposing any workspace-backed home UI.
class WorkspaceGate extends StatefulWidget {
  final WorkspaceResolver? resolver;
  final WidgetBuilder? homeBuilder;
  final WidgetBuilder? setupBuilder;

  const WorkspaceGate({
    super.key,
    this.resolver,
    this.homeBuilder,
    this.setupBuilder,
  });

  @override
  State<WorkspaceGate> createState() => _WorkspaceGateState();
}

class _WorkspaceGateState extends State<WorkspaceGate> {
  WorkspaceResolutionException? _failure;
  bool _loading = true;
  bool _routing = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    if (_routing) return;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      await (widget.resolver ?? WorkspaceResolver()).resolve();
      if (!mounted) return;
      _replace(
        widget.homeBuilder ?? (_) => const HomePage(),
        '/workspace-home',
      );
    } on WorkspaceResolutionException catch (error) {
      if (!mounted) return;
      if (error.failure == WorkspaceFailure.missingMembership) {
        _replace(
          widget.setupBuilder ?? (_) => const BusinessSetupPage(),
          '/business-setup',
        );
        return;
      }
      setState(() {
        _loading = false;
        _failure = error;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = const WorkspaceResolutionException(
          WorkspaceFailure.unavailable,
        );
      });
    }
  }

  void _replace(WidgetBuilder builder, String name) {
    _routing = true;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: builder,
        settings: RouteSettings(name: name),
      ),
    );
  }

  String get _title => switch (_failure?.failure) {
    WorkspaceFailure.inconsistentMembership => 'Workspace access not verified',
    WorkspaceFailure.sessionChanged ||
    WorkspaceFailure.unauthenticated => 'Session could not be verified',
    _ => 'Workspace unavailable',
  };

  String get _message => switch (_failure?.failure) {
    WorkspaceFailure.inconsistentMembership =>
      'Your workspace membership is incomplete or inconsistent. Please contact your business owner or support.',
    WorkspaceFailure.sessionChanged || WorkspaceFailure.unauthenticated =>
      'Your sign-in session changed while Velora was checking access. Please sign in again or retry.',
    _ =>
      'Velora could not securely verify your workspace. Check your connection and try again.',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _loading
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: AppColors.primary),
                      SizedBox(height: 18),
                      Text(
                        'Verifying your workspace…',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: const BoxDecoration(
                          color: AppColors.nude,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.lock_outline_rounded,
                          color: AppColors.primary,
                          size: 30,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          height: 1.45,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: FilledButton.icon(
                          key: const ValueKey('workspace-retry'),
                          onPressed: _resolve,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Try Again'),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    ),
  );
}
