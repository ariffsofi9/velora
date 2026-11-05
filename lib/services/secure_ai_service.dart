import 'dart:async';
import 'dart:convert';

import 'workspace_session.dart';

enum SecureAiFailure {
  signInRequired,
  emailUnverified,
  accountDisabled,
  ticketExpired,
  replayed,
  invalidRequest,
  workspaceBusy,
  outcomeUnknown,
  inventoryLimit,
  unavailable,
  quota,
  timeout,
  invalidResponse,
  workspaceChanged,
  busy,
  denied,
}

class SecureAiException implements Exception {
  final SecureAiFailure failure;
  const SecureAiException(this.failure);
  @override
  String toString() => 'AI suggestions are unavailable.';
}

/// Future callable adapter boundary. No callable name, Firebase implementation,
/// credentials or HTTP fallback is supplied in this mock-only phase.
abstract interface class SecureAiTransport {
  bool get available;
  bool get isDemo;
  Future<Object?> call(Map<String, Object> data);
}

class UnavailableSecureAiTransport implements SecureAiTransport {
  const UnavailableSecureAiTransport();
  @override
  bool get available => false;
  @override
  bool get isDemo => false;
  @override
  Future<Object?> call(Map<String, Object> data) async =>
      throw const SecureAiException(SecureAiFailure.unavailable);
}

class MockSecureAiTransport implements SecureAiTransport {
  final Future<Object?> Function(Map<String, Object>) respond;
  const MockSecureAiTransport(this.respond);
  @override
  bool get available => true;
  @override
  bool get isDemo => true;
  @override
  Future<Object?> call(Map<String, Object> data) =>
      respond(Map.unmodifiable(data));
}

/// Typed failures for a future adapter; raw backend messages must not reach UI.
class SecureAiTransportException implements Exception {
  final String code;
  final String? reason;
  const SecureAiTransportException(this.code, {this.reason});
}

const secureAiMaxResponseBytes = 65536;

/// Measures JSON data (SDK .data), not the HTTP protocol wrapper. Normalize safe
/// integral numbers so SDK doubles representing integer fields encode consistently.
int secureAiJsonBytes(Object? data) {
  Object? normalize(Object? value) {
    if (value == null || value is bool) return value;
    if (value is String) {
      for (var i = 0; i < value.length; i++) {
        final unit = value.codeUnitAt(i);
        if (unit >= 0xd800 && unit <= 0xdbff) {
          if (++i >= value.length ||
              value.codeUnitAt(i) < 0xdc00 ||
              value.codeUnitAt(i) > 0xdfff) {
            throw const SecureAiException(SecureAiFailure.invalidResponse);
          }
        } else if (unit >= 0xdc00 && unit <= 0xdfff) {
          throw const SecureAiException(SecureAiFailure.invalidResponse);
        }
      }
      return value;
    }
    if (value is num && value.isFinite) {
      return value == value.truncateToDouble() &&
              value.abs() <= 9007199254740991
          ? value.toInt()
          : value;
    }
    if (value is List) return value.map(normalize).toList();
    if (value is Map && value.keys.every((key) => key is String)) {
      return value.map(
        (key, entry) => MapEntry(normalize(key) as String, normalize(entry)),
      );
    }
    throw const SecureAiException(SecureAiFailure.invalidResponse);
  }

  try {
    return utf8.encode(jsonEncode(normalize(data))).length;
  } on SecureAiException {
    rethrow;
  } catch (_) {
    throw const SecureAiException(SecureAiFailure.invalidResponse);
  }
}

void validateSecureAiResponseBytes(Object? data) {
  if (secureAiJsonBytes(data) > secureAiMaxResponseBytes) {
    throw const SecureAiException(SecureAiFailure.invalidResponse);
  }
}

class SecureAiRequest {
  final String expectedCafeId;
  final int expectedMembershipGeneration;
  final int maxRecipes;
  SecureAiRequest(WorkspaceSession session, this.maxRecipes)
    : expectedCafeId = session.cafeId,
      expectedMembershipGeneration = session.membershipGeneration;
  Map<String, Object> issueData() => {
    'operation': 'issue',
    'expectedCafeId': expectedCafeId,
    'expectedMembershipGeneration': expectedMembershipGeneration,
    'maxRecipes': maxRecipes,
  };
  Map<String, Object> generateData(String ticketId) => {
    ...issueData(),
    'operation': 'generate',
    'ticketId': ticketId,
  };
}

Map<String, Object?> _map(Object? value, Set<String> fields) {
  if (value is! Map ||
      value.keys.any((key) => key is! String) ||
      value.length != fields.length ||
      !value.keys.every(fields.contains)) {
    throw const SecureAiException(SecureAiFailure.invalidResponse);
  }
  return Map<String, Object?>.from(value);
}

bool _integer(Object? value) =>
    value is num &&
    value.isFinite &&
    value >= 0 &&
    value <= 9007199254740991 &&
    value == value.truncateToDouble();
bool _id(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 128 &&
    value.trim() == value &&
    value != '.' &&
    value != '..' &&
    !RegExp(r'[\\/\x00-\x1f]').hasMatch(value);
String _text(Object? value, int limit) {
  if (value is! String ||
      value.isEmpty ||
      value.length > limit ||
      value.trim() != value ||
      RegExp(
        r'[\x00-\x1f\x7f]|gsk_[A-Za-z0-9]{20,}|-----BEGIN .*PRIVATE KEY-----',
      ).hasMatch(value)) {
    throw const SecureAiException(SecureAiFailure.invalidResponse);
  }
  return value;
}

class SecureAiIngredient {
  final String itemId;
  final double quantity;
  final String unit;
  const SecureAiIngredient(this.itemId, this.quantity, this.unit);
}

class SecureAiRecipe {
  final String title;
  final List<SecureAiIngredient> ingredients;
  final List<String> steps;
  final String whyRecommended;
  const SecureAiRecipe(
    this.title,
    this.ingredients,
    this.steps,
    this.whyRecommended,
  );
}

class SecureAiResult {
  final String ticketId;
  final List<SecureAiRecipe> recipes;
  final int eligibleCount;
  final int usedCount;
  final bool isDemo;
  const SecureAiResult(
    this.ticketId,
    this.recipes,
    this.eligibleCount,
    this.usedCount,
    this.isDemo,
  );

  factory SecureAiResult.parse(
    Object? raw,
    String ticketId,
    int maxRecipes, {
    required bool isDemo,
  }) {
    final data = _map(raw, {
      'schemaVersion',
      'provider',
      'ticketId',
      'status',
      'recipes',
      'inventorySelection',
    });
    final selection = _map(data['inventorySelection'], {
      'eligibleCount',
      'usedCount',
    });
    if (data['schemaVersion'] != 2 ||
        data['provider'] != 'groq' ||
        data['ticketId'] != ticketId ||
        !['ok', 'no_suggestions'].contains(data['status']) ||
        data['recipes'] is! List ||
        !_integer(selection['eligibleCount']) ||
        !_integer(selection['usedCount']) ||
        (selection['eligibleCount'] as num) > 100 ||
        (selection['usedCount'] as num) > 20 ||
        (selection['usedCount'] as num) > (selection['eligibleCount'] as num)) {
      throw const SecureAiException(SecureAiFailure.invalidResponse);
    }
    final values = data['recipes'] as List;
    if (values.length > maxRecipes ||
        (data['status'] == 'ok') != values.isNotEmpty) {
      throw const SecureAiException(SecureAiFailure.invalidResponse);
    }
    final recipes = values
        .map((rawRecipe) {
          final recipe = _map(rawRecipe, {
            'title',
            'ingredients',
            'steps',
            'whyRecommended',
          });
          if (recipe['ingredients'] is! List || recipe['steps'] is! List) {
            throw const SecureAiException(SecureAiFailure.invalidResponse);
          }
          final ingredients = recipe['ingredients'] as List;
          final steps = recipe['steps'] as List;
          if (ingredients.isEmpty ||
              ingredients.length > 10 ||
              steps.isEmpty ||
              steps.length > 8) {
            throw const SecureAiException(SecureAiFailure.invalidResponse);
          }
          final ids = <String>{};
          final parsed = ingredients
              .map((rawIngredient) {
                final ingredient = _map(rawIngredient, {
                  'itemId',
                  'quantity',
                  'unit',
                });
                final quantity = ingredient['quantity'];
                if (!_id(ingredient['itemId']) ||
                    !ids.add(ingredient['itemId'] as String) ||
                    quantity is! num ||
                    !quantity.isFinite ||
                    quantity <= 0 ||
                    quantity > 1000000 ||
                    ![
                      'kg',
                      'g',
                      'L',
                      'ml',
                      'pcs',
                    ].contains(ingredient['unit']) ||
                    (ingredient['unit'] == 'pcs' &&
                        quantity != quantity.truncateToDouble())) {
                  throw const SecureAiException(
                    SecureAiFailure.invalidResponse,
                  );
                }
                return SecureAiIngredient(
                  ingredient['itemId'] as String,
                  quantity.toDouble(),
                  ingredient['unit'] as String,
                );
              })
              .toList(growable: false);
          return SecureAiRecipe(
            _text(recipe['title'], 100),
            List.unmodifiable(parsed),
            List.unmodifiable(steps.map((step) => _text(step, 300))),
            _text(recipe['whyRecommended'], 300),
          );
        })
        .toList(growable: false);
    return SecureAiResult(
      ticketId,
      List.unmodifiable(recipes),
      (selection['eligibleCount'] as num).toInt(),
      (selection['usedCount'] as num).toInt(),
      isDemo,
    );
  }
}

class SecureAiService {
  final WorkspaceSession? Function() currentSession;
  final SecureAiTransport transport;
  final Duration timeout;
  bool _busy = false;
  bool get available => transport.available;
  bool get isDemo => transport.isDemo;
  SecureAiService({
    required this.currentSession,
    this.transport = const UnavailableSecureAiTransport(),
    this.timeout = const Duration(seconds: 30),
  });

  void _check(WorkspaceSession captured) {
    final current = currentSession();
    if (!captured.isActive ||
        !identical(current, captured) ||
        !current!.isActive) {
      throw const SecureAiException(SecureAiFailure.workspaceChanged);
    }
  }

  Future<SecureAiResult> generate({int maxRecipes = 1}) async {
    if (_busy) throw const SecureAiException(SecureAiFailure.busy);
    final session = currentSession();
    if (session == null ||
        !session.isActive ||
        !_id(session.cafeId) ||
        !_integer(session.membershipGeneration)) {
      throw const SecureAiException(SecureAiFailure.workspaceChanged);
    }
    if (maxRecipes < 1 || maxRecipes > 3) {
      throw const SecureAiException(SecureAiFailure.invalidResponse);
    }
    if (!available) throw const SecureAiException(SecureAiFailure.unavailable);
    _busy = true;
    try {
      final request = SecureAiRequest(session, maxRecipes);
      final issued = _map(
        await transport.call(request.issueData()).timeout(timeout),
        {'schemaVersion', 'ticketId', 'expiresAt'},
      );
      _check(session);
      final ticketId = issued['ticketId'];
      if (issued['schemaVersion'] != 2 ||
          ticketId is! String ||
          ticketId.length != 64 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(ticketId) ||
          !_integer(issued['expiresAt']) ||
          (issued['expiresAt'] as num) <= 0) {
        throw const SecureAiException(SecureAiFailure.invalidResponse);
      }
      final raw = await transport
          .call(request.generateData(ticketId))
          .timeout(timeout);
      _check(session);
      validateSecureAiResponseBytes(raw);
      return SecureAiResult.parse(raw, ticketId, maxRecipes, isDemo: isDemo);
    } on SecureAiException {
      rethrow;
    } on TimeoutException {
      throw const SecureAiException(SecureAiFailure.timeout);
    } on SecureAiTransportException catch (error) {
      const reasons = {
        'sign-in-required': SecureAiFailure.signInRequired,
        'email-unverified': SecureAiFailure.emailUnverified,
        'account-disabled': SecureAiFailure.accountDisabled,
        'ticket-expired': SecureAiFailure.ticketExpired,
        'ticket-replayed': SecureAiFailure.replayed,
        'invalid-request': SecureAiFailure.invalidRequest,
        'workspace-busy': SecureAiFailure.workspaceBusy,
        'outcome-unknown': SecureAiFailure.outcomeUnknown,
        'inventory-capacity': SecureAiFailure.inventoryLimit,
        'invalid-response': SecureAiFailure.invalidResponse,
      };
      if (reasons.containsKey(error.reason)) {
        throw SecureAiException(reasons[error.reason]!);
      }
      throw SecureAiException(switch (error.code) {
        'resource-exhausted' => SecureAiFailure.quota,
        'deadline-exceeded' => SecureAiFailure.timeout,
        'unauthenticated' => SecureAiFailure.signInRequired,
        'already-exists' => SecureAiFailure.replayed,
        'invalid-argument' => SecureAiFailure.invalidRequest,
        'data-loss' => SecureAiFailure.invalidResponse,
        'permission-denied' || 'aborted' => SecureAiFailure.denied,
        _ => SecureAiFailure.unavailable,
      });
    } catch (_) {
      throw const SecureAiException(SecureAiFailure.invalidResponse);
    } finally {
      _busy = false;
    }
  }
}
