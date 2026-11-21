// Web target only. This entry never imports or launches the production app.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:velora/services/firebase_startup_config.dart';

import 'spark_test_owner_email_flow.dart';
import 'spark_test_owner_email_verification.dart';

@JS('window')
external _BrowserWindow get _window;

extension type _BrowserWindow(JSObject _) implements JSObject {
  external _BrowserDocument get document;
  external _BrowserStorage get localStorage;
  external _BrowserStorage get sessionStorage;
  external _DatabaseFactory get indexedDB;
}

extension type _BrowserStorage(JSObject _) implements JSObject {
  external int get length;
}

extension type _DatabaseFactory(JSObject _) implements JSObject {
  external JSPromise<JSArray<JSObject>> databases();
}

extension type _BrowserDocument(JSObject _) implements JSObject {
  external _OwnerFileInput createElement(String tag);
}

extension type _OwnerFileInput(JSObject _) implements JSObject {
  external set type(String value);
  external set accept(String value);
  external set value(String value);
  external set onchange(JSFunction? handler);
  external set oncancel(JSFunction? handler);
  external set onerror(JSFunction? handler);
  external _OwnerFileList? get files;
  external void click();
}

extension type _OwnerFileList(JSObject _) implements JSObject {
  external int get length;
  external _OwnerFile? item(int index);
}

extension type _OwnerFile(JSObject _) implements JSObject {
  external int get size;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

bool _isLoopback() {
  final uri = Uri.base;
  return uri.scheme == 'http' && uri.host == '127.0.0.1';
}

Future<String?> _readApprovedOwnerFile() async {
  if (!_isLoopback()) return null;

  final input = _window.document.createElement('input')
    ..type = 'file'
    ..accept = 'text/plain,.txt';
  final selection = Completer<_OwnerFile?>();
  void complete(_OwnerFile? file) {
    if (!selection.isCompleted) selection.complete(file);
  }

  input.onchange = () {
    final files = input.files;
    complete(files?.length == 1 ? files?.item(0) : null);
  }.toJS;
  input.oncancel = (() => complete(null)).toJS;
  input.onerror = (() => complete(null)).toJS;

  final _OwnerFile? file;
  try {
    input.click();
    file = await selection.future;
  } finally {
    input.onchange = null;
    input.oncancel = null;
    input.onerror = null;
    input.value = '';
  }
  if (file == null || file.size == 0 || file.size > 512) return null;
  final bytes = await file.arrayBuffer().toDart;
  return utf8.decode(bytes.toDart.asUint8List());
}

Future<bool> _cleanLoopbackBrowser() async {
  if (!_isLoopback()) return false;

  // FlutterFire Web initializes Auth with browser-backed persistence first.
  // A clean origin prevents restoring a saved user before setting NONE.
  final databases = await _window.indexedDB.databases().toDart;
  return databases.toDart.isEmpty &&
      _window.localStorage.length == 0 &&
      _window.sessionStorage.length == 0 &&
      Firebase.apps.isEmpty;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      home: SparkTestOwnerEmailEntry(
        readApprovedOwnerFile: _readApprovedOwnerFile,
        flow: SparkTestOwnerEmailFlow(
          startup: FirebaseStartupConfig.current,
          isWeb: kIsWeb,
          cleanBrowser: _cleanLoopbackBrowser,
          initializeNamedApp: (options) => Firebase.initializeApp(
            name: SparkTestOwnerEmailVerification.appName,
            options: options,
          ),
          authForApp: (app) => FirebaseAuth.instanceFor(app: app),
        ),
      ),
    ),
  );
}
