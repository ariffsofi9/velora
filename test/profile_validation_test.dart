// Offline boundary doubles; no Firebase initialization or network.
// ignore_for_file: subtype_of_sealed_class
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/screens/auth/signup_page.dart';
import 'package:velora/services/auth_service.dart';
import 'package:velora/services/user_profile_service.dart';

class Snapshot extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  @override
  final bool exists;
  Snapshot(this.exists);
}

class Document extends Fake implements DocumentReference<Map<String, dynamic>> {
  final _existence = [false];
  bool get exists => _existence.single;
  set exists(bool value) => _existence[0] = value;
  final writes = <Map<String, dynamic>>[];
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async => Snapshot(exists);
  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    writes.add(data);
  }

  @override
  Future<void> update(Map<Object, Object?> data) async {
    writes.add(Map<String, dynamic>.from(data));
  }
}

class Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final Document document;
  Collection(this.document);
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) => document;
}

class Database extends Fake implements FirebaseFirestore {
  final document = Document();
  int accesses = 0;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    accesses++;
    expect(path, 'users');
    return Collection(document);
  }
}

class Account extends Fake implements User {
  @override
  String get uid => 'owner';
  @override
  final String? displayName;
  @override
  final String? photoURL;
  @override
  final String? email;
  Account({this.displayName, this.photoURL, this.email = 'owner@example.test'});
}

class Registration extends AuthService {
  final names = <String>[];
  @override
  Future<void> register({
    required String name,
    required String email,
    required String password,
  }) async {
    names.add(name);
    throw const AuthFlowException('Offline registration reached.');
  }
}

void main() {
  test(
    'submitted registration name wins over stale cached displayName',
    () async {
      final db = Database();
      await UserProfileService(firestore: db).createUserProfileIfNeeded(
        Account(displayName: null),
        initialUsername: 'Entered Owner',
      );
      expect(db.document.writes.single['username'], 'Entered Owner');
      expect(db.document.writes.single['role'], 'owner');
      db.document.exists = true;
      await UserProfileService(firestore: db).createUserProfileIfNeeded(
        Account(displayName: null),
        initialUsername: 'Another Name',
      );
      expect(db.document.writes.length, 1);
    },
  );
  for (final length in [80, 81]) {
    testWidgets('signup $length-character trimmed name before registration', (
      tester,
    ) async {
      final auth = Registration();
      await tester.pumpWidget(MaterialApp(home: SignUpPage(authService: auth)));
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '  ${'a' * length}  ');
      await tester.enterText(fields.at(1), 'owner@example.test');
      await tester.enterText(fields.at(2), 'password');
      await tester.enterText(fields.at(3), 'password');
      await tester.ensureVisible(find.text('Create Account'));
      await tester.tap(find.text('Create Account'));
      await tester.pump();
      expect(auth.names.length, length == 80 ? 1 : 0);
      expect(
        find.text(
          length == 80
              ? 'Offline registration reached.'
              : 'Full name must be 80 characters or fewer.',
        ),
        findsOneWidget,
      );
    });
  }
  for (final (name, photo) in [
    ('', ''),
    ('   ', ''),
    ('a' * 81, ''),
    ('Owner', 'x' * 2049),
  ]) {
    test('invalid update rejects before even acquiring Firestore', () async {
      final db = Database();
      await expectLater(
        UserProfileService(
          firestore: db,
        ).updateUserProfile(uid: 'owner', username: name, photoUrl: photo),
        throwsA(isA<ProfileValidationException>()),
      );
      expect(db.accesses, 0);
      expect(db.document.writes, isEmpty);
    });
  }
  test(
    'valid boundary update preserves exact input and server timestamp',
    () async {
      final db = Database();
      await UserProfileService(firestore: db).updateUserProfile(
        uid: 'owner',
        username: 'a' * 80,
        photoUrl: 'x' * 2048,
      );
      final data = db.document.writes.single;
      expect(data.keys.toSet(), {'username', 'photoUrl', 'updatedAt'});
      expect(data['username'], 'a' * 80);
      expect(data['photoUrl'], 'x' * 2048);
      expect(data['updatedAt'], isA<FieldValue>());
    },
  );
  for (final name in <String?>[null, '', '  ']) {
    test('missing/blank display name defaults safely: $name', () async {
      final db = Database();
      await UserProfileService(
        firestore: db,
      ).createUserProfileIfNeeded(Account(displayName: name));
      final data = db.document.writes.single;
      expect(data['username'], 'Velora User');
      expect(data['email'], 'owner@example.test');
      expect(data['role'], 'owner');
      expect(data['photoUrl'], '');
      expect(data['createdAt'], isA<FieldValue>());
      expect(data['updatedAt'], isA<FieldValue>());
    });
  }
  for (final user in [
    Account(displayName: 'a' * 81),
    Account(photoURL: 'x' * 2049),
    Account(email: null),
  ]) {
    test('invalid create never writes', () async {
      final db = Database();
      await expectLater(
        UserProfileService(firestore: db).createUserProfileIfNeeded(user),
        throwsA(isA<ProfileValidationException>()),
      );
      expect(db.document.writes, isEmpty);
    });
  }
  test(
    'existing profile remains untouched even if Auth display metadata is invalid',
    () async {
      final db = Database();
      db.document.exists = true;
      await UserProfileService(
        firestore: db,
      ).createUserProfileIfNeeded(Account(displayName: 'a' * 81));
      expect(db.document.writes, isEmpty);
    },
  );
  test('valid boundary profile creation retains exact metadata', () async {
    final db = Database();
    await UserProfileService(firestore: db).createUserProfileIfNeeded(
      Account(displayName: 'a' * 80, photoURL: 'x' * 2048),
    );
    expect(db.document.writes.single['username'], 'a' * 80);
    expect(db.document.writes.single['photoUrl'], 'x' * 2048);
  });
}
