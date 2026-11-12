import 'package:flutter/material.dart';
import 'widgets_home/bottom_bar.dart';
import '../../widgets/dashboard/dashboard_style.dart';
import '../../services/workspace_session.dart';
import '../../repositories/workspace_activity_repository.dart';
import '../../repositories/workspace_inventory_repository.dart';

import '../dashboard/dashboard_page.dart';
import '../inventory/inventory_page.dart';
import '../suggestions/suggestions_page.dart';
import '../settings/settings_page.dart';
import '../alerts/alerts_page.dart';
import '../activity/activity_page.dart';

class HomePage extends StatefulWidget {
  final WorkspaceSession workspaceSession;

  const HomePage({super.key, required this.workspaceSession});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;

  late List<Widget> _pages;
  late WorkspaceInventoryRepository _inventoryRepository;

  @override
  void initState() {
    super.initState();
    _configurePages();
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspaceSession, widget.workspaceSession)) {
      _configurePages();
    }
  }

  void _configurePages() {
    _inventoryRepository = WorkspaceInventoryRepository(
      session: widget.workspaceSession,
    );
    _pages = [
      DashboardPage(
        workspaceSession: widget.workspaceSession,
        inventoryRepository: _inventoryRepository,
        activityRepository: WorkspaceActivityRepository(
          session: widget.workspaceSession,
        ),
        onAddTap: _openAddItem,
        onInventoryTap: () => setState(() => _selectedIndex = 1),
        onAlertTap: _openAlerts,
        onActivityTap: _openActivity,
      ),
      InventoryPage(
        workspaceSession: widget.workspaceSession,
        repository: _inventoryRepository,
      ),
      const SizedBox(),
      SuggestionsPage(
        workspaceSession: widget.workspaceSession,
        repository: _inventoryRepository,
      ),
      SettingsPage(workspaceSession: widget.workspaceSession),
    ];
  }

  void _changePage(int index) {
    if (index == 2) {
      _openAddItem();
      return;
    }

    setState(() => _selectedIndex = index);
  }

  void _openAddItem() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Inventory changes are unavailable until secure workspace updates are enabled.',
        ),
      ),
    );
  }

  void _openAlerts() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AlertsPage(
          workspaceSession: widget.workspaceSession,
          repository: _inventoryRepository,
        ),
      ),
    );
  }

  void _openActivity() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ActivityPage(workspaceSession: widget.workspaceSession),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DashboardStyle.background,
      body: widget.workspaceSession.isActive
          ? KeyedSubtree(
              key: ObjectKey(widget.workspaceSession),
              child: _pages[_selectedIndex],
            )
          : const Center(
              child: Text('Workspace access could not be verified.'),
            ),
      bottomNavigationBar: VeloraBottomBar(
        currentIndex: _selectedIndex,
        onTap: _changePage,
      ),
    );
  }
}
