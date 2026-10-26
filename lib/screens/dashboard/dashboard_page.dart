import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../widgets/dashboard/inventory_health_card.dart';

import '../../services/auto_notification_trigger_service.dart';
import '../../widgets/dashboard/dashboard_content.dart';
import '../../widgets/dashboard/dashboard_style.dart';
import '../home/widgets_home/notification_bell.dart';
import '../home/widgets_home/recent_activity_card.dart';
import '../inventory/add_item/add_item_page.dart';
import '../inventory/inventory_page.dart';
import '../notifications/notification_page.dart';
import '../suggestions/suggestions_page.dart';

class DashboardPage extends StatelessWidget {
  final FirebaseFirestore? firestore;
  final VoidCallback? onCheckNotifications;
  const DashboardPage({super.key, this.firestore, this.onCheckNotifications});

  FirebaseFirestore get _firestore => firestore ?? FirebaseFirestore.instance;

  static const Color bg = DashboardStyle.background;
  static const Color orange = Color(0xFFF59E0B);
  static const Color red = Color(0xFFEF4444);

  int _daysLeft(DateTime expiryDate) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime(expiryDate.year, expiryDate.month, expiryDate.day);

    return expiry.difference(today).inDays;
  }

  int _nearExpiryCount(List<QueryDocumentSnapshot> docs) {
    int count = 0;

    for (final doc in docs) {
      final data = doc.data() as Map<String, dynamic>;
      final expiryRaw = data['expiryDate'];

      if (expiryRaw is Timestamp) {
        final days = _daysLeft(expiryRaw.toDate());
        if (days >= 0 && days <= 4) count++;
      }
    }

    return count;
  }

  int _lowStockCount(List<QueryDocumentSnapshot> docs) {
    int count = 0;

    for (final doc in docs) {
      final data = doc.data() as Map<String, dynamic>;
      final quantity = data['quantity'] ?? 0;

      if (quantity <= 2) count++;
    }

    return count;
  }

  void _goTo(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  void _triggerAutoNotification() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (onCheckNotifications != null) {
        onCheckNotifications!();
      } else {
        AutoNotificationTriggerService.checkAndTriggerUnreadAlerts();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: StreamBuilder<QuerySnapshot>(
          stream: _firestore.collection('inventory').snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: InventoryHealthCard(unavailable: true),
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final docs = snapshot.data!.docs;
            final totalItems = docs.length;
            final nearExpiry = _nearExpiryCount(docs);
            final lowStock = _lowStockCount(docs);

            _triggerAutoNotification();

            return DashboardContent(
              firstName: firestore == null
                  ? FirebaseAuth.instance.currentUser?.displayName
                  : null,
              totalItems: totalItems,
              nearExpiry: nearExpiry,
              lowStock: lowStock,
              notificationBell: NotificationBell(firestore: firestore),
              recentActivity: RecentActivityCard(
                firestore: firestore,
                inventoryItems: {
                  for (final doc in docs)
                    doc.id: doc.data() as Map<String, dynamic>,
                },
              ),
              onAddTap: () => _goTo(context, const AddItemPage()),
              onInventoryTap: () => _goTo(context, const InventoryPage()),
              onSuggestionTap: () => _goTo(context, const SuggestionsPage()),
              onAlertTap: () => _goTo(context, const NotificationPage()),
            );
          },
        ),
      ),
    );
  }
}
