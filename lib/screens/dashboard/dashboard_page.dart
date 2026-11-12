import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../models/inventory_item.dart';
import '../../repositories/workspace_activity_repository.dart';
import '../../logic/low_stock_policy.dart';
import '../../logic/inventory_expiry_policy.dart';
import '../../repositories/workspace_inventory_repository.dart';
import '../../services/workspace_session.dart';
import '../../widgets/dashboard/dashboard_content.dart';
import '../../widgets/dashboard/dashboard_style.dart';
import '../../widgets/dashboard/inventory_health_card.dart';
import '../home/widgets_home/notification_bell.dart';
import '../home/widgets_home/recent_activity_card.dart';
import '../suggestions/suggestions_page.dart';

class DashboardPage extends StatefulWidget {
  final WorkspaceSession workspaceSession;
  final WorkspaceInventoryRepository? inventoryRepository;
  final FirebaseFirestore? firestore;
  final WorkspaceActivityRepository? activityRepository;
  final VoidCallback? onCheckNotifications;
  final VoidCallback? onAddTap;
  final VoidCallback? onInventoryTap;
  final VoidCallback? onAlertTap;
  final VoidCallback? onActivityTap;

  const DashboardPage({
    super.key,
    required this.workspaceSession,
    this.inventoryRepository,
    this.firestore,
    this.activityRepository,
    this.onCheckNotifications,
    this.onAddTap,
    this.onInventoryTap,
    this.onAlertTap,
    this.onActivityTap,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late WorkspaceInventoryRepository _inventoryRepository;
  late Stream<List<InventoryItem>> _inventoryStream;

  late WorkspaceActivityRepository _activityRepository;

  @override
  void initState() {
    super.initState();
    _configure();
  }

  @override
  void didUpdateWidget(covariant DashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspaceSession, widget.workspaceSession) ||
        oldWidget.inventoryRepository != widget.inventoryRepository ||
        oldWidget.activityRepository != widget.activityRepository ||
        oldWidget.firestore != widget.firestore) {
      _configure();
    }
  }

  void _configure() {
    _activityRepository =
        widget.activityRepository ??
        WorkspaceActivityRepository(
          session: widget.workspaceSession,
          dataSource: FirestoreWorkspaceActivityDataSource(
            firestore: widget.firestore,
          ),
        );
    _inventoryRepository =
        widget.inventoryRepository ??
        WorkspaceInventoryRepository(session: widget.workspaceSession);
    _inventoryStream = _inventoryRepository.watchItems();
  }

  int _nearExpiryCount(List<InventoryItem> items) => items
      .where((item) => InventoryExpiryPolicy.isNearExpiry(item.expiryDate))
      .length;

  int _lowStockCount(List<InventoryItem> items) =>
      items.where(LowStockPolicy.isLowStock).length;

  void _openSuggestions(BuildContext context) {
    final session = widget.workspaceSession;
    if (!session.isActive ||
        !identical(_inventoryRepository.session, session)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Workspace access could not be verified.'),
        ),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SuggestionsPage(
          workspaceSession: session,
          repository: _inventoryRepository,
        ),
      ),
    );
  }

  void _showMutationsUnavailable(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Inventory changes are unavailable until secure workspace updates are enabled.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DashboardStyle.background,
      body: SafeArea(
        child: StreamBuilder<List<InventoryItem>>(
          key: ObjectKey(_inventoryStream),
          stream: _inventoryStream,
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

            final items = snapshot.data!;
            final user = widget.firestore == null
                ? FirebaseAuth.instance.currentUser
                : null;

            return DashboardContent(
              firstName: user?.displayName,
              photoUrl: user?.photoURL,
              totalItems: items.length,
              nearExpiry: _nearExpiryCount(items),
              lowStock: _lowStockCount(items),
              expired: items
                  .where(
                    (item) => InventoryExpiryPolicy.isExpired(item.expiryDate),
                  )
                  .length,
              notificationBell: NotificationBell(onTap: widget.onAlertTap),
              recentActivity: RecentActivityCard(
                workspaceSession: widget.workspaceSession,
                activityRepository: _activityRepository,
                onViewAll: widget.onActivityTap,
                inventoryItems: {
                  for (final item in items)
                    item.id: {'name': item.name, 'imageUrl': item.imageUrl},
                },
              ),
              onAddTap:
                  widget.onAddTap ?? () => _showMutationsUnavailable(context),
              onInventoryTap:
                  widget.onInventoryTap ??
                  () => _showMutationsUnavailable(context),
              onSuggestionTap: () => _openSuggestions(context),
              onAlertTap:
                  widget.onAlertTap ?? () => _showMutationsUnavailable(context),
            );
          },
        ),
      ),
    );
  }
}
