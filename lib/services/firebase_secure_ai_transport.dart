import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'secure_ai_service.dart';

const issueWorkspaceAiTicket = 'issueWorkspaceAiTicket';
const generateWorkspaceAiRecipes = 'generateWorkspaceAiRecipes';
typedef SecureAiCallableInvoker =
    Future<HttpsCallableResult<dynamic>> Function(
      String name,
      Map<String, Object> data,
    );

/// Opt-in adapter. Default service/startup never selects this. Tests inject an
/// invoker returning SDK-shaped fakes; constructing it initializes no Firebase app.
class FirebaseSecureAiTransport implements SecureAiTransport {
  final SecureAiCallableInvoker invoke;
  final bool enabled;
  @override
  final bool isDemo;
  const FirebaseSecureAiTransport({
    required this.invoke,
    this.enabled = false,
    this.isDemo = true,
  });

  factory FirebaseSecureAiTransport.fromFunctions(
    FirebaseFunctions functions, {
    bool enabled = false,
  }) => FirebaseSecureAiTransport(
    enabled: enabled,
    isDemo: false,
    invoke: (name, data) => functions
        .httpsCallable(
          name,
          options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
        )
        .call<dynamic>(data),
  );

  @override
  bool get available => enabled;

  @override
  Future<Object?> call(Map<String, Object> data) async {
    if (!enabled) throw const SecureAiException(SecureAiFailure.unavailable);
    final operation = data['operation'];
    final fields = {
      'operation',
      'expectedCafeId',
      'expectedMembershipGeneration',
      'maxRecipes',
      if (operation == 'generate') 'ticketId',
    };
    final generation = data['expectedMembershipGeneration'];
    final max = data['maxRecipes'];
    final cafeId = data['expectedCafeId'];
    if (!['issue', 'generate'].contains(operation) ||
        data.length != fields.length ||
        !data.keys.every(fields.contains) ||
        cafeId is! String ||
        cafeId.isEmpty ||
        cafeId.length > 128 ||
        cafeId.trim() != cafeId ||
        ['.', '..'].contains(cafeId) ||
        RegExp(r'[\\/\x00-\x1f]').hasMatch(cafeId) ||
        generation is! int ||
        generation < 0 ||
        generation > 9007199254740991 ||
        max is! int ||
        max < 1 ||
        max > 3 ||
        secureAiJsonBytes(data) > 2048 ||
        (operation == 'generate' &&
            (data['ticketId'] is! String ||
                (data['ticketId'] as String).length != 64 ||
                !RegExp(
                  r'^[a-f0-9]{64}$',
                ).hasMatch(data['ticketId'] as String)))) {
      throw const SecureAiTransportException(
        'invalid-argument',
        reason: 'invalid-request',
      );
    }
    try {
      final envelope = await invoke(
        operation == 'issue'
            ? issueWorkspaceAiTicket
            : generateWorkspaceAiRecipes,
        Map.unmodifiable(data),
      );
      final result = envelope.data;
      if (result is! Map) {
        throw const SecureAiException(SecureAiFailure.invalidResponse);
      }
      validateSecureAiResponseBytes(result);
      return result;
    } on FirebaseFunctionsException catch (error) {
      const allowed = {
        'unauthenticated': {
          'sign-in-required',
          'email-unverified',
          'account-disabled',
        },
        'permission-denied': {'access-denied'},
        'aborted': {'workspace-changed'},
        'invalid-argument': {'invalid-request'},
        'resource-exhausted': {
          'quota-exhausted',
          'workspace-busy',
          'inventory-capacity',
          'invalid-response',
        },
        'failed-precondition': {'service-unavailable', 'ticket-expired'},
        'already-exists': {'ticket-replayed'},
        'unavailable': {'service-unavailable', 'outcome-unknown'},
        'deadline-exceeded': {'provider-timeout'},
        'internal': {'service-unavailable'},
        'data-loss': {'invalid-response'},
      };
      final code = allowed.containsKey(error.code) ? error.code : 'unavailable';
      final details = error.details;
      final reason =
          details is Map &&
              details.length == 1 &&
              details['reason'] is String &&
              (allowed[code]?.contains(details['reason']) ?? false)
          ? details['reason'] as String
          : null;
      throw SecureAiTransportException(code, reason: reason);
    } on TimeoutException {
      throw const SecureAiTransportException(
        'deadline-exceeded',
        reason: 'provider-timeout',
      );
    } on SecureAiException {
      rethrow;
    } catch (_) {
      throw const SecureAiTransportException('unavailable');
    }
  }
}
