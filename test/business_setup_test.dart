import 'dart:async';
import 'helpers/owner_verification_fake.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/core/theme/app_theme.dart';
import 'package:velora/main.dart' show VeloraApp;
import 'package:velora/models/cafe_workspace.dart';
import 'package:velora/screens/business_setup/business_setup_page.dart';
import 'package:velora/screens/auth/login_page.dart';
import 'package:velora/screens/auth/workspace_session_boundary.dart';
import 'package:velora/screens/business_setup/business_setup_widgets.dart';
import 'package:velora/services/workspace_provisioning_service.dart';
import 'package:velora/services/workspace_resolver.dart';
import 'package:velora/services/owner_email_verification.dart';

class _Provisioner implements WorkspaceProvisioner {
  final Future<WorkspaceCreationResult> Function(WorkspaceCreationRequest)
  callback;
  final requests = <WorkspaceCreationRequest>[];
  _Provisioner(this.callback);

  @override
  Future<WorkspaceCreationResult> createWorkspace(
    WorkspaceCreationRequest request,
  ) {
    requests.add(request);
    return callback(request);
  }
}

class _Resolver extends WorkspaceResolver {
  final Future<CafeWorkspace> Function() callback;
  int calls = 0;
  _Resolver(this.callback);

  @override
  Future<CafeWorkspace> resolve() {
    calls++;
    return callback();
  }
}

const _workspace = CafeWorkspace(
  cafeId: 'cafe-a',
  uid: 'owner-a',
  ownerUid: 'owner-a',
  role: CafeRole.owner,
);

Widget setupApp({
  double scale = 1,
  double keyboard = 0,
  WorkspaceProvisioner? provisioner,
  WorkspaceResolver? resolver,
  OwnerEmailVerification? verification,
}) => MaterialApp(
  theme: AppTheme.light,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      viewInsets: EdgeInsets.only(bottom: keyboard),
    ),
    child: child!,
  ),
  home: BusinessSetupPage(
    verification: verification ?? VerifiedOwnerFake(),
    provisioner: provisioner,
    resolver: resolver,
    sessionIdentities: Stream.value(_workspace.uid),
    sessionAuthority: Stream.value(true),
    homeBuilder: (_, session) =>
        Scaffold(body: Text('Verified Dashboard ${session.cafeId}')),
  ),
);

Future<void> tapSetup(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> enterBusiness(WidgetTester tester, {bool address = true}) async {
  await tester.enterText(
    find.byKey(const ValueKey('business-name')),
    '  Sunrise Cafe  ',
  );
  if (address) {
    await tester.enterText(
      find.byKey(const ValueKey('business-address')),
      '12 Market Street',
    );
  }
  await tapSetup(tester, find.byKey(const ValueKey('type-Bakery')));
  await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
}

SetupChoices choices(WidgetTester tester, String group) =>
    tester.widget<SetupChoices>(
      find.byWidgetPredicate(
        (widget) => widget is SetupChoices && widget.group == group,
      ),
    );

void main() {
  testWidgets(
    'verification round trip preserves draft and requires explicit Create tap',
    (tester) async {
      final verification = VerifiedOwnerFake(verified: false);
      final provisioner = _Provisioner(
        (_) async => const WorkspaceCreationResult(created: true),
      );
      await tester.pumpWidget(
        setupApp(
          verification: verification,
          provisioner: provisioner,
          resolver: _Resolver(() async => _workspace),
        ),
      );
      await enterBusiness(tester);
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      await tester.tap(find.byKey(const ValueKey('setup-dashboard')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('setup-dashboard')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Verify email'));
      await tester.pumpAndSettle();
      verification.verified = true;
      await tester.tap(find.byKey(const ValueKey('owner-check-verification')));
      await tester.pumpAndSettle();
      expect(provisioner.requests, isEmpty);
      await tester.tap(find.byKey(const ValueKey('setup-dashboard')));
      await tester.pumpAndSettle();
      expect(provisioner.requests.single.businessName, 'Sunrise Cafe');
    },
  );
  testWidgets('unverified Owner cannot submit even an injected provisioner', (
    tester,
  ) async {
    final provisioner = _Provisioner(
      (_) async => const WorkspaceCreationResult(created: true),
    );
    await tester.pumpWidget(
      setupApp(
        provisioner: provisioner,
        verification: VerifiedOwnerFake(verified: false),
      ),
    );
    await enterBusiness(tester);
    await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
    await tester.tap(find.byKey(const ValueKey('setup-dashboard')));
    await tester.pumpAndSettle();
    expect(provisioner.requests, isEmpty);
    expect(find.text('Verify email'), findsOneWidget);
    expect(
      find.textContaining('Verify your email, then sign in again'),
      findsOneWidget,
    );
  });
  testWidgets(
    'backend-invalid form bounds reject before navigation and preserve text',
    (tester) async {
      await tester.pumpWidget(setupApp());
      await tester.enterText(find.byKey(const ValueKey('business-name')), 'a');
      await tapSetup(tester, find.byKey(const ValueKey('type-Bakery')));
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      expect(
        find.text('Business name must be between 2 and 80 characters.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('business-name')))
            .controller!
            .text,
        'a',
      );
      await tester.enterText(
        find.byKey(const ValueKey('business-name')),
        'Valid Cafe',
      );
      await tester.enterText(
        find.byKey(const ValueKey('business-address')),
        'x' * 201,
      );
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      expect(
        find.text('Business address must be 200 characters or fewer.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('business-address')),
            )
            .controller!
            .text,
        'x' * 201,
      );
    },
  );
  testWidgets(
    'Root setup Back is visible and exits to Login without provisioning',
    (tester) async {
      final provisioner = _Provisioner(
        (_) async => throw StateError('must not create'),
      );
      await tester.pumpWidget(setupApp(provisioner: provisioner));
      final back = find.byKey(const ValueKey('setup-header-back'));
      expect(back, findsOneWidget);
      expect(tester.getSize(back).width, greaterThanOrEqualTo(48));
      expect(tester.widget<IconButton>(back).tooltip, 'Back');
      await tapSetup(tester, back);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(BusinessSetupPage), findsNothing);
      expect(provisioner.requests, isEmpty);
    },
  );
  testWidgets('Step one Back pops existing onboarding route once', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const BusinessSetupPage(),
                ),
              ),
              child: const Text('Previous onboarding'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Previous onboarding'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('setup-header-back')));
    await tester.tap(
      find.byKey(const ValueKey('setup-header-back')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(find.text('Previous onboarding'), findsOneWidget);
    expect(find.byType(BusinessSetupPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Visible Back returns through steps preserving entered values', (
    tester,
  ) async {
    final provisioner = _Provisioner(
      (_) async => throw StateError('must not create'),
    );
    await tester.pumpWidget(setupApp(provisioner: provisioner));
    await enterBusiness(tester);
    await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
    await tapSetup(tester, find.byKey(const ValueKey('setup-header-back')));
    expect(find.text('Set Up Your Inventory'), findsOneWidget);
    await tapSetup(tester, find.byKey(const ValueKey('setup-header-back')));
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('business-name')))
          .controller!
          .text
          .trim(),
      'Sunrise Cafe',
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('business-address')))
          .controller!
          .text,
      '12 Market Street',
    );
    expect(choices(tester, 'type').selected, 'Bakery');
    expect(provisioner.requests, isEmpty);
  });
  testWidgets('Back is disabled during a pending creation', (tester) async {
    final pending = Completer<WorkspaceCreationResult>();
    await tester.pumpWidget(
      setupApp(
        provisioner: _Provisioner((_) => pending.future),
        resolver: _Resolver(() async => _workspace),
      ),
    );
    await enterBusiness(tester);
    await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
    await tester.tap(find.byKey(const ValueKey('setup-dashboard')));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('setup-header-back')))
          .onPressed,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(BusinessSetupPage), findsOneWidget);
    pending.complete(const WorkspaceCreationResult(created: true));
    await tester.pumpAndSettle();
  });

  testWidgets('Successful creation verifies membership before Dashboard', (
    tester,
  ) async {
    final provisioner = _Provisioner(
      (_) async => const WorkspaceCreationResult(created: true),
    );
    final resolver = _Resolver(() async => _workspace);
    await tester.pumpWidget(
      setupApp(provisioner: provisioner, resolver: resolver),
    );
    await enterBusiness(tester);
    await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
    await tapSetup(tester, find.byKey(const ValueKey('setup-dashboard')));

    expect(provisioner.requests, hasLength(1));
    final request = provisioner.requests.single;
    expect(request.businessName, 'Sunrise Cafe');
    expect(request.businessType, 'Bakery');
    expect(request.address, '12 Market Street');
    expect(request.inventoryUnit, 'kg');
    expect(resolver.calls, greaterThanOrEqualTo(1));
    expect(find.text('Verified Dashboard cafe-a'), findsOneWidget);
    expect(find.byType(WorkspaceSessionBoundary), findsOneWidget);
  });

  testWidgets('Duplicate submit taps create only one callable request', (
    tester,
  ) async {
    final completion = Completer<WorkspaceCreationResult>();
    final provisioner = _Provisioner((_) => completion.future);
    final resolver = _Resolver(() async => _workspace);
    await tester.pumpWidget(
      setupApp(provisioner: provisioner, resolver: resolver),
    );
    await enterBusiness(tester);
    await tapSetup(tester, find.byKey(const ValueKey('setup-next')));

    final submit = find.byKey(const ValueKey('setup-dashboard'));
    await tester.tap(submit);
    await tester.tap(submit);
    await tester.pump();
    expect(provisioner.requests, hasLength(1));
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);

    completion.complete(const WorkspaceCreationResult(created: true));
    await tester.pumpAndSettle();
    expect(find.text('Verified Dashboard cafe-a'), findsOneWidget);
    expect(find.byType(WorkspaceSessionBoundary), findsOneWidget);
  });

  for (final entry in {
    WorkspaceProvisioningFailure.emailUnverified: 'Verify your email',
    WorkspaceProvisioningFailure.existingMembership:
        'existing workspace membership',
  }.entries) {
    testWidgets('setup feedback distinguishes ${entry.key}', (tester) async {
      await tester.pumpWidget(
        setupApp(
          provisioner: _Provisioner(
            (_) async => throw WorkspaceProvisioningException(entry.key),
          ),
          resolver: _Resolver(() async => _workspace),
        ),
      );
      await enterBusiness(tester);
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      await tapSetup(tester, find.byKey(const ValueKey('setup-dashboard')));
      expect(find.textContaining(entry.value), findsOneWidget);
      expect(find.textContaining('Verified Dashboard'), findsNothing);
    });
  }
  testWidgets('newly provisioned home is removed on authority revocation', (
    tester,
  ) async {
    final authority = StreamController<bool>.broadcast();
    await tester.pumpWidget(
      MaterialApp(
        home: BusinessSetupPage(
          verification: VerifiedOwnerFake(),
          provisioner: _Provisioner(
            (_) async => const WorkspaceCreationResult(created: true),
          ),
          resolver: _Resolver(() async => _workspace),
          sessionIdentities: Stream.value(_workspace.uid),
          sessionAuthority: authority.stream,
          homeBuilder: (_, session) =>
              const Scaffold(body: Text('Protected created home')),
        ),
      ),
    );
    await enterBusiness(tester);
    await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
    await tester.tap(find.byKey(const ValueKey('setup-dashboard')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Protected created home'), findsNothing);
    authority.add(true);
    await tester.pumpAndSettle();
    expect(find.text('Protected created home'), findsOneWidget);
    authority.add(false);
    await tester.pumpAndSettle();
    expect(find.text('Protected created home'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await authority.close();
  });

  for (final failure in [
    WorkspaceProvisioningFailure.unavailable,
    WorkspaceProvisioningFailure.timedOut,
    WorkspaceProvisioningFailure.internal,
  ]) {
    testWidgets(
      'uncertain $failure permits resolution only, never reprovisions',
      (tester) async {
        final provisioner = _Provisioner(
          (_) async => throw WorkspaceProvisioningException(failure),
        );
        final resolver = _Resolver(
          () async => throw const WorkspaceResolutionException(
            WorkspaceFailure.missingMembership,
          ),
        );
        await tester.pumpWidget(
          setupApp(provisioner: provisioner, resolver: resolver),
        );
        await enterBusiness(tester);
        await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
        await tapSetup(tester, find.byKey(const ValueKey('setup-dashboard')));
        expect(find.text('Recheck Workspace'), findsOneWidget);
        expect(provisioner.requests, hasLength(1));
        await tapSetup(tester, find.byKey(const ValueKey('setup-dashboard')));
        await tapSetup(tester, find.byKey(const ValueKey('setup-dashboard')));
        expect(provisioner.requests, hasLength(1));
        expect(resolver.calls, 2);
        expect(find.textContaining('outcome is still unknown'), findsOneWidget);
        expect(find.textContaining('Verified Dashboard'), findsNothing);
      },
    );
  }
  for (final entry in {
    WorkspaceProvisioningFailure.callableNotFound:
        'creation service was not found',
    WorkspaceProvisioningFailure.permissionDenied: 'creation was denied',
    WorkspaceProvisioningFailure.unauthenticated: 'Please sign in again',
  }.entries) {
    testWidgets('classified feedback ${entry.key}', (tester) async {
      await tester.pumpWidget(
        setupApp(
          provisioner: _Provisioner(
            (_) async => throw WorkspaceProvisioningException(entry.key),
          ),
          resolver: _Resolver(() async => _workspace),
        ),
      );
      await enterBusiness(tester);
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      await tapSetup(tester, find.byKey(const ValueKey('setup-dashboard')));
      expect(find.textContaining(entry.value), findsOneWidget);
    });
  }
  testWidgets('Callable error stays fail-closed and allows retry', (
    tester,
  ) async {
    final provisioner = _Provisioner(
      (_) async => throw const WorkspaceProvisioningException(
        WorkspaceProvisioningFailure.unavailable,
      ),
    );
    final resolver = _Resolver(() async => _workspace);
    await tester.pumpWidget(
      setupApp(provisioner: provisioner, resolver: resolver),
    );
    await enterBusiness(tester);
    await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
    await tapSetup(tester, find.byKey(const ValueKey('setup-dashboard')));

    expect(find.textContaining('Verified Dashboard'), findsNothing);
    expect(
      find.byKey(const ValueKey('setup-submission-error')),
      findsOneWidget,
    );
    expect(provisioner.requests, hasLength(1));
    expect(resolver.calls, 0);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('setup-dashboard')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('Verification retry never creates a second workspace', (
    tester,
  ) async {
    final provisioner = _Provisioner(
      (_) async => const WorkspaceCreationResult(created: true),
    );
    var failVerification = true;
    final resolver = _Resolver(() async {
      if (failVerification) {
        throw const WorkspaceResolutionException(WorkspaceFailure.unavailable);
      }
      return _workspace;
    });
    await tester.pumpWidget(
      setupApp(provisioner: provisioner, resolver: resolver),
    );
    await enterBusiness(tester);
    await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
    await tapSetup(tester, find.byKey(const ValueKey('setup-dashboard')));

    expect(find.text('Recheck Workspace'), findsOneWidget);
    expect(find.textContaining('Verified Dashboard'), findsNothing);
    expect(provisioner.requests, hasLength(1));

    failVerification = false;
    await tapSetup(tester, find.byKey(const ValueKey('setup-dashboard')));
    expect(provisioner.requests, hasLength(1));
    expect(resolver.calls, greaterThanOrEqualTo(2));
    expect(find.text('Verified Dashboard cafe-a'), findsOneWidget);
    expect(find.byType(WorkspaceSessionBoundary), findsOneWidget);
  });

  testWidgets('Disabled reminders are accurately reported in the summary', (
    tester,
  ) async {
    await tester.pumpWidget(setupApp());
    await enterBusiness(tester, address: false);
    await tapSetup(tester, find.byKey(const ValueKey('expiry-reminders')));
    await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('summary-Expiry Reminders')))
          .data,
      'Disabled',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('summary-Reminder Timing')))
          .data,
      'Disabled',
    );
    expect(
      find.byKey(const ValueKey('summary-Business Address')),
      findsNothing,
    );
  });

  testWidgets(
    'Leaving the preview does not persist or reuse a business draft',
    (tester) async {
      await tester.pumpWidget(setupApp());
      await enterBusiness(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(setupApp());
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('business-name')))
            .controller!
            .text,
        isEmpty,
      );
      expect(choices(tester, 'type').selected, isNull);
    },
  );
  testWidgets('Step 1 validates name and type, while address stays optional', (
    tester,
  ) async {
    await tester.pumpWidget(setupApp());
    await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
    expect(
      find.text('Business name must be between 2 and 80 characters.'),
      findsOneWidget,
    );
    expect(find.text('Please select a business type.'), findsOneWidget);
    await enterBusiness(tester, address: false);
    expect(find.text('Set Up Your Inventory'), findsOneWidget);
  });

  testWidgets('Business type chips offer only the three supported new types', (
    tester,
  ) async {
    await tester.pumpWidget(setupApp());
    final group = find.byWidgetPredicate(
      (widget) => widget is SetupChoices && widget.group == 'type',
    );
    expect(
      find.descendant(of: group, matching: find.byType(Icon)),
      findsNothing,
    );
    final positions = [
      for (final value in ['Restaurant', 'Caf\u00e9', 'Bakery'])
        tester.getTopLeft(find.byKey(ValueKey('type-$value'))),
    ];
    expect(positions[0].dy, positions[1].dy);
    expect(positions[1].dy, positions[2].dy);
    expect(find.byKey(const ValueKey('type-Catering')), findsNothing);
    expect(find.byKey(const ValueKey('type-Cloud Kitchen')), findsNothing);
    expect(find.byKey(const ValueKey('type-Other')), findsNothing);
    expect(positions[0].dx, lessThan(positions[1].dx));
    expect(positions[1].dx, lessThan(positions[2].dx));
  });

  testWidgets(
    'Defaults, disabled timing and back navigation preserve entered state',
    (tester) async {
      await tester.pumpWidget(setupApp());
      await enterBusiness(tester);
      expect(choices(tester, 'unit').selected, 'kg');
      expect(choices(tester, 'timing').selected, '3');
      expect(
        tester
            .widget<Switch>(find.byKey(const ValueKey('low-stock-alerts')))
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<Switch>(find.byKey(const ValueKey('expiry-reminders')))
            .value,
        isTrue,
      );
      await tapSetup(tester, find.byKey(const ValueKey('unit-L')));
      await tapSetup(tester, find.byKey(const ValueKey('timing-7')));
      await tapSetup(tester, find.byKey(const ValueKey('low-stock-alerts')));
      await tapSetup(tester, find.byKey(const ValueKey('expiry-reminders')));
      expect(choices(tester, 'timing').onSelected, isNull);
      expect(
        tester.widget<InkWell>(find.byKey(const ValueKey('timing-1'))).onTap,
        isNull,
      );
      await tapSetup(tester, find.byKey(const ValueKey('setup-back')));
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('business-name')))
            .controller!
            .text,
        '  Sunrise Cafe  ',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('business-address')),
            )
            .controller!
            .text,
        '12 Market Street',
      );
      expect(choices(tester, 'type').selected, 'Bakery');
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      expect(choices(tester, 'unit').selected, 'L');
      expect(choices(tester, 'timing').selected, '7');
      expect(choices(tester, 'timing').onSelected, isNull);
      await tapSetup(tester, find.byKey(const ValueKey('expiry-reminders')));
      expect(choices(tester, 'timing').selected, '7');
      expect(choices(tester, 'timing').onSelected, isNotNull);
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      expect(find.text('Your setup preview is ready'), findsOneWidget);
      expect(
        tester.getBottomRight(find.byKey(const ValueKey('setup-dashboard'))).dy,
        lessThanOrEqualTo(
          tester.view.physicalSize.height / tester.view.devicePixelRatio,
        ),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('summary-Business Name')))
            .data,
        'Sunrise Cafe',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('summary-Business Type')))
            .data,
        'Bakery',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('summary-Default Inventory Unit')),
            )
            .data,
        'L',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('summary-Low Stock Alerts')),
            )
            .data,
        'Disabled',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('summary-Reminder Timing')))
            .data,
        '7 days before',
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('setup-dashboard')))
            .onPressed,
        isNotNull,
      );
      await tapSetup(tester, find.text('Edit inventory preferences'));
      expect(find.text('Set Up Your Inventory'), findsOneWidget);
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      await tapSetup(tester, find.text('Edit Setup'));
      expect(find.text('Set Up Your Business'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('business-name')),
        'Updated Cafe',
      );
      await tapSetup(tester, find.byKey(const ValueKey('type-Bakery')));
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('summary-Business Name')))
            .data,
        'Updated Cafe',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('summary-Business Type')))
            .data,
        'Bakery',
      );
    },
  );

  testWidgets('System Back returns to previous step and retains form values', (
    tester,
  ) async {
    await tester.pumpWidget(setupApp());
    await enterBusiness(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Set Up Your Business'), findsOneWidget);
    expect(choices(tester, 'type').selected, 'Bakery');
  });

  testWidgets(
    'Production named preview route opens without Firebase initialization',
    (tester) async {
      await tester.pumpWidget(const VeloraApp());
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .pushNamed('/business-setup');
      await tester.pumpAndSettle();
      expect(find.byType(BusinessSetupPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    },
  );

  for (final width in [320.0, 393.0, 768.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('All steps fit $width with text scale $scale and keyboard', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, width == 320 ? 568 : 852);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(setupApp(scale: scale, keyboard: 220));
        await enterBusiness(tester, address: false);
        expect(tester.takeException(), isNull);
        await tapSetup(tester, find.byKey(const ValueKey('setup-next')));
        await tester.ensureVisible(
          find.byKey(const ValueKey('setup-dashboard')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byKey(const ValueKey('setup-dashboard'))).height,
          greaterThanOrEqualTo(48),
        );
      });
    }
  }
}
