import 'package:flutter/material.dart';
import 'widgets_home/bottom_bar.dart';
import '../../widgets/dashboard/dashboard_style.dart';
import '../../services/workspace_session.dart';
import '../../repositories/workspace_inventory_repository.dart';

import '../dashboard/dashboard_page.dart';
import '../inventory/inventory_page.dart';
import '../suggestions/suggestions_page.dart';
import '../settings/settings_page.dart';
import '../alerts/alerts_page.dart';
import '../inventory/add_item/add_item_page.dart';

class HomePage extends StatefulWidget {
  final WorkspaceSession workspaceSession;

  const HomePage({super.key, required this.workspaceSession});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;

  late final List<Widget> _pages;
  late final WorkspaceInventoryRepository _inventoryRepository;

  @override
  void initState() {
    super.initState();
    _inventoryRepository = WorkspaceInventoryRepository(
      session: widget.workspaceSession,
    );
    _pages = [
      DashboardPage(
        workspaceSession: widget.workspaceSession,
        inventoryRepository: _inventoryRepository,
        onAddTap: _openAddItem,
        onInventoryTap: () => setState(() => _selectedIndex = 1),
        onAlertTap: _openAlerts,
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
      const SettingsPage(),
    ];
  }

  void _changePage(int index) {
    if (index == 2) {
      _openAddItem();
      return;
    }

    setState(() => _selectedIndex = index);
  }

  Future<void> _openAddItem() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AddItemPage(workspaceSession: widget.workspaceSession),
      ),
    );
    if (created == true && mounted) {
      setState(() => _selectedIndex = 1);
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DashboardStyle.background,
      body: _pages[_selectedIndex],
      bottomNavigationBar: VeloraBottomBar(
        currentIndex: _selectedIndex,
        onTap: _changePage,
      ),
    );
  }
}
