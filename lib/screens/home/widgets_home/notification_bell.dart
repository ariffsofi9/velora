import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../notifications/notification_page.dart';
import '../../../widgets/dashboard/dashboard_style.dart';

class NotificationBell extends StatelessWidget {
  final FirebaseFirestore? firestore;
  const NotificationBell({super.key, this.firestore});

  int _unreadCount(QuerySnapshot snapshot) {
    int count = 0;

    for (final doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>;

      final isRead = data['isRead'] == true;
      final isDismissed = data['isDismissed'] == true;

      if (!isRead && !isDismissed) {
        count++;
      }
    }

    return count;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: (firestore ?? FirebaseFirestore.instance)
          .collection('notifications')
          .snapshots(),
      builder: (context, snapshot) {
        final count = snapshot.hasData ? _unreadCount(snapshot.data!) : 0;

        return InkWell(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotificationPage()),
            );
          },
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                height: 48,
                width: 48,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: DashboardStyle.border),
                ),
                child: const Icon(
                  Icons.notifications_rounded,
                  color: DashboardStyle.primary,
                ),
              ),
              if (count > 0)
                Positioned(
                  top: -4,
                  right: -4,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 19),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: DashboardStyle.danger,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Center(
                      child: Text(
                        count > 9 ? '9+' : count.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
