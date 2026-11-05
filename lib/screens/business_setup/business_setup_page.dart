import '../team/staff_invitation_page.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../models/cafe_workspace.dart';
import '../../services/workspace_provisioning_service.dart';
import '../../services/workspace_resolver.dart';
import '../../services/workspace_session.dart';
import '../home/home_page.dart';
import '../auth/workspace_session_boundary.dart';
import '../auth/login_page.dart';
import 'business_information_step.dart';
import 'business_setup_draft.dart';
import 'business_setup_widgets.dart';
import 'inventory_preferences_step.dart';
import 'setup_complete_step.dart';
import '../../services/owner_email_verification.dart';
import '../auth/owner_email_verification_page.dart';

class BusinessSetupPage extends StatefulWidget {
  final WorkspaceProvisioner? provisioner;
  final WorkspaceResolver? resolver;
  final OwnerEmailVerification? verification;
  final Stream<String?>? sessionIdentities;
  final Stream<bool>? sessionAuthority;
  final Widget Function(BuildContext context, WorkspaceSession session)?
  homeBuilder;

  const BusinessSetupPage({
    super.key,
    this.provisioner,
    this.resolver,
    this.verification,
    this.sessionIdentities,
    this.sessionAuthority,
    this.homeBuilder,
  });
  @override
  State<BusinessSetupPage> createState() => _BusinessSetupPageState();
}

class _BusinessSetupPageState extends State<BusinessSetupPage> {
  final _draft = BusinessSetupDraft();
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  int _step = 0;
  bool _submitting = false;
  bool _leaving = false;
  bool _creationAccepted = false;
  bool _creationUncertain = false;
  String? _submissionError;
  late final OwnerEmailVerification _verification =
      widget.verification ?? FirebaseOwnerEmailVerification();
  bool _needsVerification = false;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _goToStep(int step) {
    FocusScope.of(context).unfocus();
    setState(() => _step = step);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _back() {
    if (_submitting || _leaving) return;
    FocusScope.of(context).unfocus();
    if (_step > 0) {
      _goToStep(_step - 1);
      return;
    }
    _leaving = true;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      // Setup replaces WorkspaceGate on normal entry. Login is the existing
      // safe entry screen; returning to the gate would redirect back to setup.
      navigator.pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => const LoginPage(),
          settings: const RouteSettings(name: '/login'),
        ),
        (_) => false,
      );
    }
  }

  void _next() {
    if (_step == 0) {
      if (!_form.currentState!.validate()) return;
      _draft.businessName = _name.text.trim();
      _draft.address = _address.text.trim();
    }
    _goToStep(_step + 1);
  }

  WorkspaceCreationRequest get _request => WorkspaceCreationRequest(
    businessName: _draft.businessName,
    businessType: _draft.businessType!,
    address: _draft.address,
    inventoryUnit: _draft.unit,
    lowStockAlerts: _draft.lowStockAlerts,
    expiryReminders: _draft.expiryReminders,
    reminderDays: _draft.reminderDays,
  );

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _submissionError = null;
    });
    try {
      if (!_creationAccepted && !_creationUncertain) {
        _request.normalized();
        if (!await _verification.refreshVerified()) {
          throw const WorkspaceProvisioningException(
            WorkspaceProvisioningFailure.emailUnverified,
          );
        }
        if (!mounted) return;
        await (widget.provisioner ?? FirebaseWorkspaceProvisioner())
            .createWorkspace(_request.normalized());
        if (!mounted) return;
        setState(() => _creationAccepted = true);
      }
      final workspace = await (widget.resolver ?? WorkspaceResolver())
          .resolve();
      if (!mounted) return;
      final session = WorkspaceSession.fromVerified(workspace);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => WorkspaceSessionBoundary(
            session: session,
            identities: widget.sessionIdentities,
            authority: widget.sessionAuthority,
            resolve: widget.resolver?.resolve,
            child:
                widget.homeBuilder?.call(context, session) ??
                HomePage(workspaceSession: session),
          ),
          settings: const RouteSettings(name: '/workspace-home'),
        ),
      );
    } on WorkspaceProvisioningException catch (error) {
      if (!mounted) return;
      setState(() {
        // A lost/invalid response does not establish that the transaction failed.
        _creationUncertain = switch (error.failure) {
          WorkspaceProvisioningFailure.unavailable ||
          WorkspaceProvisioningFailure.timedOut ||
          WorkspaceProvisioningFailure.internal => true,
          _ => false,
        };
        _submissionError = _provisioningMessage(error.failure);
        _needsVerification =
            error.failure == WorkspaceProvisioningFailure.emailUnverified;
      });
    } on OwnerVerificationException catch (error) {
      if (!mounted) return;
      setState(
        () => _submissionError =
            error.failure == OwnerVerificationFailure.signedOut ||
                error.failure == OwnerVerificationFailure.changed
            ? 'Your session could not be verified. Please sign in again.'
            : 'Email verification is unavailable. Check your connection and try again.',
      );
    } on WorkspaceResolutionException {
      if (!mounted) return;
      setState(() {
        _submissionError = _creationUncertain
            ? 'The creation outcome is still unknown. Recheck access or contact support before submitting another creation request.'
            : _creationAccepted
            ? 'Workspace creation was accepted, but secure access could not yet be verified. Recheck without creating another workspace.'
            : 'Workspace access could not be verified. Please try again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submissionError =
            'Secure workspace setup is temporarily unavailable. Please try again.';
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _openVerification() async {
    final verified = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => OwnerEmailVerificationPage(verification: _verification),
      ),
    );
    if (mounted && verified == true) {
      setState(() {
        _needsVerification = false;
        _submissionError = null;
      });
    }
  }

  String _provisioningMessage(
    WorkspaceProvisioningFailure failure,
  ) => switch (failure) {
    WorkspaceProvisioningFailure.callableNotFound =>
      'Workspace creation service was not found. Ask the administrator to verify createWorkspace in asia-southeast1 for velora-73222.',
    WorkspaceProvisioningFailure.permissionDenied =>
      'Workspace creation was denied. Check your account access or contact support.',
    WorkspaceProvisioningFailure.timedOut =>
      'The request timed out; creation may have completed. Recheck Workspace before another creation attempt.',

    WorkspaceProvisioningFailure.invalidProfile =>
      'Workspace setup requires a valid explicitly selected Firebase profile.',
    WorkspaceProvisioningFailure.emailUnverified =>
      'Verify your email, then sign in again before creating a workspace.',
    WorkspaceProvisioningFailure.unauthenticated =>
      'Your session could not be verified. Please sign in again.',
    WorkspaceProvisioningFailure.invalidInput =>
      'Some setup details were not accepted. Review them and try again.',
    WorkspaceProvisioningFailure.existingMembership =>
      'An existing workspace membership could not be safely confirmed. Recheck access or contact support.',
    WorkspaceProvisioningFailure.unavailable =>
      'The workspace service could not be reached. Creation may have completed. Recheck Workspace before another creation attempt.',
    WorkspaceProvisioningFailure.internal =>
      'The workspace service returned an unexpected result. Creation may have completed. Recheck Workspace or contact support.',
  };

  Widget _stepBody() => switch (_step) {
    0 => BusinessInformationStep(
      formKey: _form,
      name: _name,
      address: _address,
      draft: _draft,
      onTypeChanged: (value) => setState(() => _draft.businessType = value),
    ),
    1 => InventoryPreferencesStep(
      draft: _draft,
      onUnitChanged: (value) => setState(() => _draft.unit = value),
      onAlertsChanged: (value) => setState(() => _draft.lowStockAlerts = value),
      onRemindersChanged: (value) =>
          setState(() => _draft.expiryReminders = value),
      onTimingChanged: (value) => setState(() => _draft.reminderDays = value),
    ),
    _ => SetupCompleteStep(
      draft: _draft,
      onEditBusiness: (_creationAccepted || _creationUncertain)
          ? null
          : () => _goToStep(0),
      onEditPreferences: (_creationAccepted || _creationUncertain)
          ? null
          : () => _goToStep(1),
    ),
  };

  Widget _footer() => switch (_step) {
    0 => FilledButton(
      key: const ValueKey('setup-next'),
      onPressed: _next,
      child: const Text('Next'),
    ),
    1 => Row(
      children: [
        Expanded(
          child: OutlinedButton(
            key: const ValueKey('setup-back'),
            onPressed: () => _goToStep(0),
            child: const Text('Back'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            key: const ValueKey('setup-next'),
            onPressed: _next,
            child: const Text('Next'),
          ),
        ),
      ],
    ),
    _ => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          key: const ValueKey('setup-dashboard'),
          onPressed: _submitting || _needsVerification ? null : _submit,
          child: _submitting
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  (_creationAccepted || _creationUncertain)
                      ? 'Recheck Workspace'
                      : 'Create Workspace',
                ),
        ),
        if (_submissionError != null) ...[
          const SizedBox(height: 10),
          Semantics(
            liveRegion: true,
            child: Text(
              _submissionError!,
              key: const ValueKey('setup-submission-error'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w400,
                color: AppColors.danger,
                fontSize: 12,
              ),
            ),
          ),
          if (_needsVerification)
            TextButton(
              onPressed: _submitting ? null : _openVerification,
              child: const Text('Verify email'),
            ),
        ],
      ],
    ),
  };

  @override
  Widget build(BuildContext context) => PopScope(
    canPop:
        !_submitting && !_leaving && _step == 0 && Navigator.canPop(context),
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) _back();
    },
    child: Scaffold(
      backgroundColor: AppColors.background,
      bottomNavigationBar: _step == 2
          ? SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: _footer(),
                ),
              ),
            )
          : null,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, size) => SingleChildScrollView(
            controller: _scroll,
            padding: EdgeInsets.all(size.maxWidth < 360 ? 20 : 24),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 480,
                  minHeight: (size.maxHeight - (size.maxWidth < 360 ? 40 : 48))
                      .clamp(0, double.infinity),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: 48,
                              height: 48,
                              child: IconButton(
                                key: const ValueKey('setup-header-back'),
                                tooltip: 'Back',
                                icon: const Icon(Icons.arrow_back),
                                onPressed: _submitting || _leaving
                                    ? null
                                    : _back,
                              ),
                            ),
                            Expanded(child: SetupProgress(step: _step)),
                            SizedBox(
                              width: 48,
                              height: 48,
                              child: IconButton(
                                tooltip: 'Join with invite',
                                icon: const Icon(Icons.group_add_outlined),
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const StaffInvitationPage(),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        _stepBody(),
                      ],
                    ),
                    if (_step < 2)
                      Padding(
                        padding: const EdgeInsets.only(top: 28),
                        child: SizedBox(
                          width: double.infinity,
                          child: _footer(),
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
