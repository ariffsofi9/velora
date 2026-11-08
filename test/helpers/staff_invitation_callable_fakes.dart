// Network-free doubles for the installed cloud_functions public interfaces.
import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

class StaffCallableFunctions extends Fake implements FirebaseFunctions {
  StaffCallableFunctions(this.app);
  @override
  final FirebaseApp app;
  final names = <String>[];
  final payloads = <Map<String, dynamic>>[];
  final routes = <({String host, int port, bool automaticHostMapping})>[];
  Future<Object?> Function() respond = () async => throw StateError('No response configured');
  Object? configurationError;

  @override
  void useFunctionsEmulator(String host, int port,
      {bool automaticHostMapping = true}) {
    if (configurationError case final Object error) throw error;
    routes.add((host: host, port: port, automaticHostMapping: automaticHostMapping));
  }

  @override
  HttpsCallable httpsCallable(String name, {HttpsCallableOptions? options}) {
    names.add(name);
    return _StaffCallable(this);
  }
}

class _StaffCallable extends Fake implements HttpsCallable {
  _StaffCallable(this.owner);
  final StaffCallableFunctions owner;
  @override
  Future<HttpsCallableResult<T>> call<T>([dynamic parameters]) async {
    // Fail locally before invoking a response if routing was omitted or changed.
    final route = owner.routes.last;
    if (route.host != '127.0.0.1' || route.automaticHostMapping ||
        !{25001, 15001}.contains(route.port)) {
      throw StateError('Unexpected route');
    }
    owner.payloads.add(Map<String, dynamic>.unmodifiable(parameters as Map<String, dynamic>));
    return _StaffResult<T>((await owner.respond()) as T);
  }
}

class _StaffResult<T> extends Fake implements HttpsCallableResult<T> {
  _StaffResult(this.data);
  @override
  final T data;
}
