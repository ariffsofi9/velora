import 'package:flutter_test/flutter_test.dart';
import 'package:velora/services/workspace_provisioning_service.dart';

void main() {
  test('Callable request maps the complete trusted backend contract', () {
    const request = WorkspaceCreationRequest(
      businessName: 'Sunrise Cafe',
      businessType: 'Café',
      address: '12 Market Street',
      inventoryUnit: 'L',
      lowStockAlerts: false,
      expiryReminders: true,
      reminderDays: 7,
    );

    expect(request.toCallableData(), {
      'businessName': 'Sunrise Cafe',
      'businessType': 'Café',
      'address': '12 Market Street',
      'inventoryUnit': 'L',
      'lowStockAlerts': false,
      'expiryReminders': true,
      'reminderDays': 7,
    });
    expect(request.toCallableData(), isNot(contains('uid')));
    expect(request.toCallableData(), isNot(contains('role')));
    expect(request.toCallableData(), isNot(contains('cafeId')));
  });

  test('Production callable execution is blocked for this phase', () async {
    await expectLater(
      FirebaseWorkspaceProvisioner().createWorkspace(
        const WorkspaceCreationRequest(
          businessName: 'Sunrise Cafe',
          businessType: 'Bakery',
          address: '',
          inventoryUnit: 'kg',
          lowStockAlerts: true,
          expiryReminders: true,
          reminderDays: 3,
        ),
      ),
      throwsA(
        isA<WorkspaceProvisioningException>().having(
          (error) => error.failure,
          'failure',
          WorkspaceProvisioningFailure.emulatorRequired,
        ),
      ),
    );
  });
}
