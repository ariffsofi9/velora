// Offline SDK boundary doubles, with no Firebase initialization or network.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/services/android_pilot_policy.dart';
import 'package:velora/services/auth_service.dart';
import 'package:velora/services/user_profile_service.dart';

AndroidPilotPolicy policy(AndroidPilotState state) => AndroidPilotPolicy.parse(
  state == AndroidPilotState.normal
      ? {}
      : {
          AndroidPilotPolicy.modeKey: state == AndroidPilotState.invalid
              ? 'false'
              : 'true',
          AndroidPilotPolicy.projectKey: AndroidPilotPolicy.approvedProject,
          AndroidPilotPolicy.bindingsKey: jsonEncode([
            ['synthetic-owner', 'synthetic-cafe-a'],
            ['synthetic-staff', 'synthetic-cafe-b'],
          ]),
        },
  isWeb: false,
  platform: TargetPlatform.android,
);

class _User extends Fake implements User {
  @override
  final String uid;
  @override
  final String? email;
  @override
  bool emailVerified;
  @override
  String? displayName = 'Synthetic Owner';
  @override
  String? get photoURL => null;
  int displayNameUpdates = 0;
  int verificationEmails = 0;
  _User({
    this.uid = 'synthetic-owner',
    this.email = 'synthetic@example.test',
    this.emailVerified = true,
  });
  @override
  Future<void> updateDisplayName(String? name) async {
    displayNameUpdates++;
    displayName = name;
  }

  @override
  Future<void> sendEmailVerification([ActionCodeSettings? settings]) async {
    verificationEmails++;
  }
}

class _Credential extends Fake implements UserCredential {
  @override
  final User? user;
  _Credential(this.user);
}

class _Auth extends Fake implements FirebaseAuth {
  User? user;
  User? resultUser;
  User? signedInUser;
  bool nullCredential = false;
  bool failSignOut = false;
  int signIns = 0;
  int registrations = 0;
  int resetEmails = 0;
  int signOuts = 0;
  int listeners = 0;
  final changes = StreamController<User?>.broadcast(sync: true);
  @override
  User? get currentUser => user;
  void replace(User? next) {
    user = next;
    changes.add(next);
  }

  @override
  Stream<User?> authStateChanges() => Stream<User?>.multi((controller) {
    listeners++;
    final sub = changes.stream.listen(
      controller.addSync,
      onError: controller.addErrorSync,
      onDone: controller.closeSync,
    );
    controller.onCancel = () async {
      listeners--;
      await sub.cancel();
    };
    controller.addSync(currentUser);
  });

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    signIns++;
    replace(signedInUser);
    return _Credential(nullCredential ? null : resultUser ?? signedInUser);
  }

  @override
  Future<UserCredential> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    registrations++;
    replace(signedInUser);
    return _Credential(signedInUser);
  }

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    ActionCodeSettings? actionCodeSettings,
  }) async {
    resetEmails++;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    if (failSignOut) {
      throw FirebaseAuthException(code: 'network-request-failed');
    }
    replace(null);
  }
}

class _Metadata extends Fake implements SnapshotMetadata {
  @override
  final bool isFromCache;
  @override
  final bool hasPendingWrites;
  _Metadata(this.isFromCache, this.hasPendingWrites);
}

class _Snapshot extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  @override
  final String id;
  final Map<String, dynamic>? value;
  @override
  final SnapshotMetadata metadata;
  _Snapshot(this.id, this.value, this.metadata);
  @override
  bool get exists => value != null;
  @override
  Map<String, dynamic>? data() => value;
}

class _DocumentData {
  String pathUid = '';
  String? snapshotUid;
  Map<String, dynamic>? value = {
    'username': 'Synthetic Owner',
    'email': 'synthetic@example.test',
    'photoUrl': '',
    // Display metadata deliberately does not establish workspace authority.
    'role': 'owner',
    'createdAt': Timestamp.fromMillisecondsSinceEpoch(1000),
    'updatedAt': Timestamp.fromMillisecondsSinceEpoch(2000),
  };
  bool cached = false;
  bool pendingWrites = false;
  Object? error;
  Completer<void>? pending;
  final started = Completer<void>();
  final sources = <Source?>[];
  final writes = <Map<Object, Object?>>[];
  int snapshotReads = 0;
}

class _Document extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final _DocumentData fixture;
  _Document(this.fixture);
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async {
    fixture.sources.add(options?.source);
    if (!fixture.started.isCompleted) fixture.started.complete();
    await fixture.pending?.future;
    if (fixture.error != null) throw fixture.error!;
    return _Snapshot(
      fixture.snapshotUid ?? fixture.pathUid,
      fixture.value,
      _Metadata(fixture.cached, fixture.pendingWrites),
    );
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    fixture.writes.add(data);
    fixture.value = data;
  }

  @override
  Future<void> update(Map<Object, Object?> data) async {
    fixture.writes.add(data);
  }

  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) {
    fixture.snapshotReads++;
    return Stream.value(
      _Snapshot(
        fixture.pathUid,
        fixture.value,
        _Metadata(fixture.cached, fixture.pendingWrites),
      ),
    );
  }
}

class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final _DocumentData document;
  _Collection(this.document);
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    document.pathUid = path!;
    return _Document(document);
  }
}

class _Database extends Fake implements FirebaseFirestore {
  final document = _DocumentData();
  final collections = <String>[];
  int accesses = 0;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    collections.add(path);
    accesses++;
    return _Collection(document);
  }
}

class _Profiles extends UserProfileService {
  int createCalls = 0;
  _Profiles(_Database db, AndroidPilotPolicy? policy)
    : super(firestore: db, pilotPolicy: policy);
  @override
  Future<void> createUserProfileIfNeeded(
    User user, {
    String? initialUsername,
  }) async {
    createCalls++;
    await super.createUserProfileIfNeeded(
      user,
      initialUsername: initialUsername,
    );
  }
}

void main() {
  late _User user;
  late _Auth auth;
  late _Database db;
  late _Profiles profiles;
  late AuthService service;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    user = _User();
    auth = _Auth()..signedInUser = user;
    db = _Database();
    final restricted = policy(AndroidPilotState.restricted);
    profiles = _Profiles(db, restricted);
    service = AuthService(
      auth: auth,
      profiles: profiles,
      pilotPolicy: restricted,
    );
  });
  tearDown(() async {
    expect(auth.listeners, 0);
    await auth.changes.close();
  });
  Future<void> login() => service.signIn(
    email: 'synthetic@example.test',
    password: 'synthetic-password',
  );
  void expectNoWrites() {
    expect(db.collections, everyElement('users'));
    expect(db.document.writes, isEmpty);
    expect(profiles.createCalls, 0);
    expect(auth.registrations, 0);
    expect(auth.resetEmails, 0);
    expect(user.displayNameUpdates, 0);
    expect(user.verificationEmails, 0);
  }

  for (final uid in ['synthetic-owner', 'synthetic-staff']) {
    test(
      'existing-profile sign-in for approved $uid uses only server read',
      () async {
        user = _User(uid: uid);
        auth.signedInUser = user;
        await login();
        expect(auth.currentUser?.uid, uid);
        expect(auth.signIns, 1);
        expect(auth.signOuts, 0);
        expect(db.document.pathUid, uid);
        expect(db.document.sources, [Source.server]);
        expectNoWrites();
      },
    );
  }

  test(
    'restricted auth cannot accidentally invoke a normal profile repair',
    () async {
      profiles = _Profiles(db, null);
      service = AuthService(
        auth: auth,
        profiles: profiles,
        pilotPolicy: policy(AndroidPilotState.restricted),
      );
      db.document.value = null;
      await expectLater(login(), throwsA(isA<AuthFlowException>()));
      expect(auth.currentUser, isNull);
      expect(db.document.sources, [Source.server]);
      expectNoWrites();
    },
  );

  test('unverified account is rejected before any profile read', () async {
    user.emailVerified = false;
    await expectLater(login(), throwsA(isA<AuthFlowException>()));
    expect(auth.currentUser, isNull);
    expect(db.accesses, 0);
    expectNoWrites();
  });
  test('missing Auth email cannot qualify against a server profile', () async {
    auth.signedInUser = _User(email: null);
    await expectLater(login(), throwsA(isA<AuthFlowException>()));
    expect(db.document.sources, [Source.server]);
    expect(auth.currentUser, isNull);
    expectNoWrites();
  });
  test('unapproved UID cannot dispatch a profile read', () async {
    auth.signedInUser = _User(uid: 'synthetic-unapproved');
    await expectLater(login(), throwsA(isA<AuthFlowException>()));
    expect(db.accesses, 0);
    expect(auth.currentUser, isNull);
    expectNoWrites();
  });
  test(
    'credential/current UID mismatch rejects without signing out replacement',
    () async {
      auth.resultUser = _User(uid: 'synthetic-staff');
      await expectLater(login(), throwsA(isA<AuthFlowException>()));
      expect(auth.currentUser, same(user));
      expect(auth.signOuts, 0);
      expect(db.accesses, 0);
      expectNoWrites();
    },
  );
  test('null credential never claims successful sign-in', () async {
    auth.nullCredential = true;
    await expectLater(login(), throwsA(isA<AuthFlowException>()));
    expect(db.accesses, 0);
    expectNoWrites();
  });

  for (final scenario in [
    'missing',
    'unavailable',
    'null-username',
    'blank-username',
    'long-username',
    'wrong-email',
    'missing-email',
    'missing-photo',
    'long-photo',
    'invalid-role',
    'missing-created',
    'invalid-updated',
    'cached',
    'pending-write',
    'wrong-document',
  ]) {
    test('server profile $scenario fails closed without repair', () async {
      switch (scenario) {
        case 'missing':
          db.document.value = null;
        case 'unavailable':
          db.document.error = FirebaseException(
            plugin: 'cloud_firestore',
            code: 'unavailable',
            message: 'synthetic-private-upstream',
          );
        case 'null-username':
          db.document.value!['username'] = null;
        case 'blank-username':
          db.document.value!['username'] = '  ';
        case 'long-username':
          db.document.value!['username'] = 'x' * 81;
        case 'wrong-email':
          db.document.value!['email'] = 'other@example.test';
        case 'missing-email':
          db.document.value!.remove('email');
        case 'missing-photo':
          db.document.value!.remove('photoUrl');
        case 'long-photo':
          db.document.value!['photoUrl'] = 'x' * 2049;
        case 'invalid-role':
          db.document.value!['role'] = 'administrator';
        case 'missing-created':
          db.document.value!.remove('createdAt');
        case 'invalid-updated':
          db.document.value!['updatedAt'] = 'not-a-timestamp';
        case 'cached':
          db.document.cached = true;
        case 'pending-write':
          db.document.pendingWrites = true;
        case 'wrong-document':
          db.document.snapshotUid = 'synthetic-other';
      }
      await expectLater(
        login(),
        throwsA(
          isA<AuthFlowException>().having(
            (e) => e.message,
            'sanitized',
            isNot(contains('synthetic-private-upstream')),
          ),
        ),
      );
      expect(db.document.sources, [Source.server]);
      expect(auth.currentUser, isNull);
      expectNoWrites();
    });
  }

  for (final replacement in [
    'other-uid',
    'same-uid',
    'signed-out',
    'ABA',
    'unverified',
    'stream-error',
  ]) {
    test('delayed sign-in rejects session change: $replacement', () async {
      db.document.pending = Completer<void>();
      final pending = expectLater(login(), throwsA(isA<AuthFlowException>()));
      await db.document.started.future;
      switch (replacement) {
        case 'other-uid':
          auth.replace(_User(uid: 'synthetic-staff'));
        case 'same-uid':
          auth.replace(_User());
        case 'signed-out':
          auth.replace(null);
        case 'ABA':
          auth.replace(null);
          auth.replace(user);
        case 'unverified':
          user.emailVerified = false;
        case 'stream-error':
          auth.changes.addError(StateError('synthetic-stream-failure'));
      }
      final replacementUser = auth.currentUser;
      db.document.pending!.complete();
      await pending;
      if (replacement != 'unverified') {
        expect(auth.signOuts, 0);
        expect(auth.currentUser, same(replacementUser));
      }
      expectNoWrites();
    });
  }

  test(
    'failed cleanup never converts a missing profile into success',
    () async {
      db.document.value = null;
      auth.failSignOut = true;
      await expectLater(login(), throwsA(isA<AuthFlowException>()));
      expect(await service.canRestoreSession(), isFalse);
      expectNoWrites();
    },
  );

  test(
    'restored eligibility requires a server profile and exact optional cafe binding',
    () async {
      auth.user = user;
      await service.requirePilotProfileEligibility(cafeId: 'synthetic-cafe-a');
      expect(await service.canRestoreSession(), isTrue);
      expect(db.document.sources, [Source.server, Source.server]);
      await expectLater(
        service.requirePilotProfileEligibility(cafeId: 'synthetic-cafe-b'),
        throwsA(isA<AuthFlowException>()),
      );
      expect(db.document.sources, hasLength(2));
      expect(auth.signIns, 0);
      expectNoWrites();
    },
  );
  for (final scenario in [
    'signed-out',
    'unverified',
    'unapproved',
    'missing',
    'unavailable',
  ]) {
    test('restored session rejects $scenario', () async {
      auth.user = user;
      switch (scenario) {
        case 'signed-out':
          auth.user = null;
        case 'unverified':
          user.emailVerified = false;
        case 'unapproved':
          auth.user = _User(uid: 'synthetic-other');
        case 'missing':
          db.document.value = null;
        case 'unavailable':
          db.document.error = StateError('synthetic-offline');
      }
      await expectLater(
        service.requirePilotProfileEligibility(),
        throwsA(isA<AuthFlowException>()),
      );
      expect(await service.canRestoreSession(), isFalse);
      expect(auth.signOuts, 0);
      expectNoWrites();
    });
  }
  test(
    'replacement during restored read rejects the obsolete result',
    () async {
      auth.user = user;
      db.document.pending = Completer<void>();
      final pending = expectLater(
        service.requirePilotProfileEligibility(),
        throwsA(isA<AuthFlowException>()),
      );
      await db.document.started.future;
      final replacement = _User(uid: 'synthetic-staff');
      auth.replace(replacement);
      db.document.pending!.complete();
      await pending;
      expect(auth.currentUser, same(replacement));
      expect(auth.signOuts, 0);
      expectNoWrites();
    },
  );

  for (final state in [
    AndroidPilotState.restricted,
    AndroidPilotState.invalid,
  ]) {
    test(
      '$state rejects registration/reset/create/update/stream before dispatch',
      () async {
        final configuration = policy(state);
        final guarded = UserProfileService(
          firestore: db,
          pilotPolicy: configuration,
        );
        service = AuthService(
          auth: auth,
          profiles: guarded,
          pilotPolicy: configuration,
        );
        await expectLater(
          service.register(
            name: 'Synthetic Owner',
            email: 'synthetic@example.test',
            password: 'synthetic-password',
          ),
          throwsA(isA<AuthFlowException>()),
        );
        await expectLater(
          service.sendPasswordResetEmail(email: 'synthetic@example.test'),
          throwsA(isA<AuthFlowException>()),
        );
        await expectLater(
          guarded.createUserProfileIfNeeded(user),
          throwsA(isA<ProfileValidationException>()),
        );
        await expectLater(
          guarded.updateUserProfile(
            uid: user.uid,
            username: 'Synthetic Owner',
            photoUrl: '',
          ),
          throwsA(isA<ProfileValidationException>()),
        );
        expect(
          () => guarded.getUserProfileStream(user.uid),
          throwsA(isA<ProfileValidationException>()),
        );
        expect(db.accesses, 0);
        expect(db.document.snapshotReads, 0);
        expect(auth.signIns, 0);
        expectNoWrites();
      },
    );
    test('$state preserves explicit logout', () async {
      auth.user = user;
      await AuthService(auth: auth, pilotPolicy: policy(state)).signOut();
      expect(auth.currentUser, isNull);
      expect(auth.signOuts, 1);
      expect(db.accesses, 0);
    });
  }

  test(
    'invalid policy rejects sign-in/restoration/eligibility/read without fallback',
    () async {
      final invalid = policy(AndroidPilotState.invalid);
      service = AuthService(
        auth: auth,
        profiles: profiles,
        pilotPolicy: invalid,
      );
      await expectLater(login(), throwsA(isA<AuthFlowException>()));
      await expectLater(
        service.canRestoreSession(),
        throwsA(isA<AuthFlowException>()),
      );
      await expectLater(
        service.requirePilotProfileEligibility(),
        throwsA(isA<AuthFlowException>()),
      );
      await expectLater(
        UserProfileService(
          firestore: db,
          pilotPolicy: invalid,
        ).readExistingServerProfile(user),
        throwsA(isA<ProfileValidationException>()),
      );
      // Even without injected SDK dependencies, guards run before singleton access.
      await expectLater(
        AuthService(pilotPolicy: invalid).signIn(email: 'x', password: 'x'),
        throwsA(isA<AuthFlowException>()),
      );
      expect(auth.signIns, 0);
      expect(db.accesses, 0);
      expectNoWrites();
    },
  );

  test(
    'standalone profile read rejects restricted unapproved/unverified users',
    () async {
      for (final account in [
        _User(uid: 'synthetic-other'),
        _User(emailVerified: false),
      ]) {
        await expectLater(
          profiles.readExistingServerProfile(account),
          throwsA(isA<ProfileValidationException>()),
        );
      }
      expect(db.accesses, 0);
      expectNoWrites();
    },
  );

  test(
    'manual sign-in clears the existing registration guard only after eligibility',
    () async {
      SharedPreferences.setMockInitialValues({
        'velora_registration_requires_login': true,
      });
      db.document.pending = Completer<void>();
      final pending = login();
      await db.document.started.future;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('velora_registration_requires_login'), isTrue);
      db.document.pending!.complete();
      await pending;
      expect(prefs.getBool('velora_registration_requires_login'), isFalse);
      expectNoWrites();
    },
  );
  test(
    'failed profile check preserves the manual-login registration guard',
    () async {
      SharedPreferences.setMockInitialValues({
        'velora_registration_requires_login': true,
      });
      db.document.value = null;
      await expectLater(login(), throwsA(isA<AuthFlowException>()));
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'velora_registration_requires_login',
        ),
        isTrue,
      );
      expectNoWrites();
    },
  );
  test('unfinished registration cannot restore in pilot mode', () async {
    SharedPreferences.setMockInitialValues({
      'velora_registration_requires_login': true,
    });
    auth.user = user;
    expect(await service.canRestoreSession(), isFalse);
    expect(auth.currentUser, isNull);
    expect(db.accesses, 0);
    expectNoWrites();
  });

  for (final configuration in <AndroidPilotPolicy?>[
    null,
    policy(AndroidPilotState.normal),
  ]) {
    test(
      'normal policy ${configuration?.state} retains unverified login and profile recovery',
      () async {
        user.emailVerified = false;
        db.document.value = null;
        profiles = _Profiles(db, configuration);
        service = AuthService(
          auth: auth,
          profiles: profiles,
          pilotPolicy: configuration,
        );
        await login();
        expect(profiles.createCalls, 1);
        expect(db.document.writes, hasLength(1));
        expect(db.document.sources, [null]);
        expect(await service.canRestoreSession(), isTrue);
        await service.requirePilotProfileEligibility();
        expect(db.document.sources, hasLength(1));
        await service.sendPasswordResetEmail(email: 'synthetic@example.test');
        expect(auth.resetEmails, 1);
      },
    );
  }

  test(
    'explicit normal policy retains registration, updates and profile streams',
    () async {
      final normal = policy(AndroidPilotState.normal);
      profiles = _Profiles(db, normal);
      service = AuthService(
        auth: auth,
        profiles: profiles,
        pilotPolicy: normal,
      );
      db.document.value = null;
      await service.register(
        name: 'Synthetic Owner',
        email: 'synthetic@example.test',
        password: 'synthetic-password',
      );
      expect(auth.registrations, 1);
      expect(user.displayNameUpdates, 1);
      expect(profiles.createCalls, 1);
      expect(db.document.writes, hasLength(1));
      expect(auth.currentUser, isNull);
      await profiles.updateUserProfile(
        uid: user.uid,
        username: 'Synthetic New Name',
        photoUrl: '',
      );
      expect(db.document.writes, hasLength(2));
      expect(await profiles.getUserProfileStream(user.uid).first, isNotNull);
      expect(db.document.snapshotReads, 1);
    },
  );

  test(
    'server-read timeout rejects and late completion cannot repair or succeed',
    () async {
      db.document.pending = Completer<void>();
      final rejected = expectLater(login(), throwsA(isA<AuthFlowException>()));
      await db.document.started.future;
      expect(db.document.sources, [Source.server]);
      // Await the service's actual bounded deadline, without sleeps, pumping
      // or cross-zone cancellation of SDK stream doubles.
      await rejected;
      expect(auth.currentUser, isNull);
      db.document.pending!.complete();
      await db.document.pending!.future;
      expectNoWrites();
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
