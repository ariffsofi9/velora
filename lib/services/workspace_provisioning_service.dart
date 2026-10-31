import 'package:cloud_functions/cloud_functions.dart';

import 'firebase_emulator_config.dart';

class WorkspaceCreationRequest {
  final String businessName;
  final String businessType;
  final String address;
  final String inventoryUnit;
  final bool lowStockAlerts;
  final bool expiryReminders;
  final int reminderDays;

  const WorkspaceCreationRequest({
    required this.businessName,
    required this.businessType,
    required this.address,
    required this.inventoryUnit,
    required this.lowStockAlerts,
    required this.expiryReminders,
    required this.reminderDays,
  });

  Map<String, Object> toCallableData() => {
    'businessName': businessName,
    'businessType': businessType,
    'address': address,
    'inventoryUnit': inventoryUnit,
    'lowStockAlerts': lowStockAlerts,
    'expiryReminders': expiryReminders,
    'reminderDays': reminderDays,
  };
}

class WorkspaceCreationResult {
  final bool created;
  const WorkspaceCreationResult({required this.created});
}

enum WorkspaceProvisioningFailure {
  emulatorRequired,
  unauthenticated,
  invalidInput,
  existingMembership,
  unavailable,
  internal,
}

class WorkspaceProvisioningException implements Exception {
  final WorkspaceProvisioningFailure failure;
  const WorkspaceProvisioningException(this.failure);
}

abstract interface class WorkspaceProvisioner {
  Future<WorkspaceCreationResult> createWorkspace(
    WorkspaceCreationRequest request,
  );
}

class FirebaseWorkspaceProvisioner implements WorkspaceProvisioner {
  final FirebaseFunctions? _functions;
  FirebaseWorkspaceProvisioner({FirebaseFunctions? functions})
    : _functions = functions;

  @override
  Future<WorkspaceCreationResult> createWorkspace(
    WorkspaceCreationRequest request,
  ) async {
    if (!FirebaseEmulatorConfig.enabled) {
      throw const WorkspaceProvisioningException(
        WorkspaceProvisioningFailure.emulatorRequired,
      );
    }
    try {
      final callable =
          (_functions ??
                  FirebaseFunctions.instanceFor(region: 'asia-southeast1'))
              .httpsCallable('createWorkspace');
      final response = await callable.call<Map<String, dynamic>>(
        request.toCallableData(),
      );
      final data = response.data;
      if (data['created'] is! bool || data['cafeId'] is! String) {
        throw const WorkspaceProvisioningException(
          WorkspaceProvisioningFailure.internal,
        );
      }
      return WorkspaceCreationResult(created: data['created'] as bool);
    } on FirebaseFunctionsException catch (error) {
      throw WorkspaceProvisioningException(_mapCode(error.code));
    } on WorkspaceProvisioningException {
      rethrow;
    } catch (_) {
      throw const WorkspaceProvisioningException(
        WorkspaceProvisioningFailure.unavailable,
      );
    }
  }

  static WorkspaceProvisioningFailure _mapCode(String code) => switch (code) {
    'unauthenticated' => WorkspaceProvisioningFailure.unauthenticated,
    'invalid-argument' => WorkspaceProvisioningFailure.invalidInput,
    'already-exists' ||
    'failed-precondition' => WorkspaceProvisioningFailure.existingMembership,
    'unavailable' ||
    'deadline-exceeded' => WorkspaceProvisioningFailure.unavailable,
    _ => WorkspaceProvisioningFailure.internal,
  };
}
