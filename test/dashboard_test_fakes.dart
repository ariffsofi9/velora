// Offline Firestore doubles intentionally implement plugin snapshot/query interfaces.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

class DashboardDocument extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  final Map<String, dynamic> value;
  DashboardDocument(this.value);
  @override
  Map<String, dynamic> data() => value;
  @override
  String get id => (value['id'] ?? identityHashCode(this)).toString();
}

class DashboardSnapshot extends Fake
    implements QuerySnapshot<Map<String, dynamic>> {
  final List<Map<String, dynamic>> values;
  DashboardSnapshot(this.values);
  @override
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get docs =>
      values.map(DashboardDocument.new).toList();
}

class DashboardCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final Stream<QuerySnapshot<Map<String, dynamic>>> stream;
  final Map<String, Object?> calls = {};
  Object? get orderedField => calls['field'];
  bool? get descending => calls['descending'] as bool?;
  int? get queryLimit => calls['limit'] as int?;
  DashboardCollection(this.stream);
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #snapshots) return stream;
    if (invocation.memberName == #orderBy) {
      calls['field'] = invocation.positionalArguments.first;
      calls['descending'] = invocation.namedArguments[#descending] as bool?;
      return this;
    }
    if (invocation.memberName == #limit) {
      calls['limit'] = invocation.positionalArguments.first as int;
      return this;
    }
    return super.noSuchMethod(invocation);
  }
}

class DashboardFirestore extends Fake implements FirebaseFirestore {
  final Map<String, DashboardCollection> collections;
  DashboardFirestore(this.collections);
  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) =>
      collections[collectionPath]!;
}

DashboardCollection dashboardCollection(List<Map<String, dynamic>> values) =>
    DashboardCollection(Stream.value(DashboardSnapshot(values)));

DashboardFirestore dashboardFirestore() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  Map<String, dynamic> item(int quantity, int days) => {
    'quantity': quantity,
    'expiryDate': Timestamp.fromDate(today.add(Duration(days: days))),
  };
  return DashboardFirestore({
    'inventory': dashboardCollection([
      item(2, 4),
      item(3, 5),
      item(0, -1),
      item(1, 0),
      {'quantity': 8},
      item(1, 1),
    ]),
    'notifications': dashboardCollection([
      {},
      {'isRead': true},
      {'isDismissed': true},
      {'isRead': false, 'isDismissed': false},
    ]),
    'inventory_records': dashboardCollection([
      {
        'type': 'stock_in',
        'itemName': 'Milk',
        'quantity': 4,
        'createdAt': Timestamp.fromDate(
          now.subtract(const Duration(minutes: 5)),
        ),
      },
      {
        'type': 'stock_out',
        'itemName': 'Egg',
        'usedQuantity': 2,
        'createdAt': Timestamp.fromDate(now.subtract(const Duration(hours: 2))),
      },
    ]),
  });
}
