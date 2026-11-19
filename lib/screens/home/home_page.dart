import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'widgets_home/bottom_bar.dart';
import '../../widgets/dashboard/dashboard_style.dart';
import '../../services/android_pilot_policy.dart';
import '../../services/mutation_recovery_service.dart';
import '../../services/workspace_inventory_https_transport.dart';
import '../../services/workspace_session.dart';
import '../../repositories/workspace_activity_repository.dart';
import '../../repositories/workspace_inventory_repository.dart';
import '../../repositories/workspace_saved_recipe_repository.dart';

import '../dashboard/dashboard_page.dart';
import '../inventory/inventory_page.dart';
import '../suggestions/suggestions_page.dart';
import '../settings/settings_page.dart';
import '../alerts/alerts_page.dart';
import '../activity/activity_page.dart';
import '../auth/workspace_gate.dart';
import '../inventory/add_item/add_item_page.dart';

/// Explicit offline composition. The handler receives only synthetic requests.
/// An HTTP client, live origin and authentication provider cannot be supplied.
final class OfflineInventoryRest {
  static const projectId = 'velora-spark-test';

  final InventoryHttpsSession session;
  final Future<http.Response> Function(http.Request) respond;
  final MutationRecoveryJournal? journal;

  const OfflineInventoryRest({
    required this.session,
    required this.respond,
    this.journal,
  });

  bool _matches(WorkspaceSession workspace) =>
      identical(session.workspace, workspace) &&
      workspace.isActive &&
      workspace.uid.isNotEmpty &&
      session.uid == workspace.uid &&
      session.projectId == projectId &&
      session.emailVerified &&
      session.revision >= 0;
}

class HomePage extends StatefulWidget {
  final WorkspaceSession workspaceSession;
  final WorkspaceSavedRecipeRepository? savedRecipesRepository;
  final OfflineInventoryRest? offlineInventoryRest;

  const HomePage({
    super.key,
    required this.workspaceSession,
    this.savedRecipesRepository,
    this.offlineInventoryRest,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;

  late List<Widget> _pages;
  late WorkspaceInventoryRepository _inventoryRepository;
  late WorkspaceActivityRepository _activityRepository;
  final _inventorySessionChanges =
      StreamController<InventoryHttpsSession?>.broadcast(sync: true);
  HttpsWorkspaceInventory? _inventoryMutations;
  AndroidPilotPolicy? _policy;
  late final _buildPolicy = AndroidPilotPolicy.fromBuildConfiguration(
    isWeb: kIsWeb,
    platform: defaultTargetPlatform,
    androidFlavor: appFlavor,
  );

  @override
  void initState() {
    super.initState();
    _configureRepositories();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final policy =
        context
            .dependOnInheritedWidgetOfExactType<AndroidPilotAuthScope>()
            ?.dependencies
            .policy ??
        _buildPolicy;
    if (!identical(_policy, policy)) {
      _policy = policy;
      _configureInventoryMutations();
      _configurePages();
    }
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sessionChanged = !identical(
      oldWidget.workspaceSession,
      widget.workspaceSession,
    );
    final transportChanged = !identical(
      oldWidget.offlineInventoryRest,
      widget.offlineInventoryRest,
    );
    if (sessionChanged) {
      _configureRepositories();
    }
    if (sessionChanged || transportChanged) {
      _configureInventoryMutations();
    }
    if (sessionChanged ||
        transportChanged ||
        !identical(
          oldWidget.savedRecipesRepository,
          widget.savedRecipesRepository,
        )) {
      _configurePages();
    }
  }

  void _configureInventoryMutations() {
    _invalidateInventoryMutations();
    final config = widget.offlineInventoryRest;
    final workspace = widget.workspaceSession;
    final policy = _policy;
    if (config == null ||
        !config._matches(workspace) ||
        policy?.state != AndroidPilotState.normal ||
        _buildPolicy.state != AndroidPilotState.normal) {
      return;
    }
    late final HttpsWorkspaceInventory adapter;
    adapter = HttpsWorkspaceInventory(
      pilotPolicy: policy!,
      endpoint: Uri.https('inventory.offline.invalid'),
      projectId: OfflineInventoryRest.projectId,
      endpointProjectId: OfflineInventoryRest.projectId,
      client: MockClient(config.respond),
      currentSession: () =>
          identical(_inventoryMutations, adapter) && config._matches(workspace)
          ? config.session
          : null,
      sessionChanges: _inventorySessionChanges.stream,
      idToken: (_) async => 'synthetic-inventory-token',
      journal: config.journal,
    );
    _inventoryMutations = adapter;
  }

  void _invalidateInventoryMutations() {
    if (_inventoryMutations == null) return;
    _inventoryMutations = null;
    _inventorySessionChanges.add(null);
  }

  @override
  void dispose() {
    _invalidateInventoryMutations();
    unawaited(_inventorySessionChanges.close());
    super.dispose();
  }

  void _configureRepositories() {
    _inventoryRepository = WorkspaceInventoryRepository(
      session: widget.workspaceSession,
    );
    _activityRepository = WorkspaceActivityRepository(
      session: widget.workspaceSession,
    );
  }

  void _configurePages() {
    _pages = [
      DashboardPage(
        workspaceSession: widget.workspaceSession,
        inventoryRepository: _inventoryRepository,
        activityRepository: _activityRepository,
        savedRecipesRepository: widget.savedRecipesRepository,
        onAddTap: _openAddItem,
        onInventoryTap: () => setState(() => _selectedIndex = 1),
        onAlertTap: _openAlerts,
        onActivityTap: _openActivity,
      ),
      InventoryPage(
        workspaceSession: widget.workspaceSession,
        repository: _inventoryRepository,
        inventoryCreator: _inventoryMutations,
        inventoryUpdater: _inventoryMutations,
        stockAdjuster: _inventoryMutations,
        lifecycleManager: _inventoryMutations,
      ),
      const SizedBox(),
      SuggestionsPage(
        workspaceSession: widget.workspaceSession,
        repository: _inventoryRepository,
        savedRecipesRepository: widget.savedRecipesRepository,
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
    final creator = _inventoryMutations;
    final session = widget.workspaceSession;
    if (creator != null && session.isActive) {
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              AddItemPage(workspaceSession: session, creator: creator),
        ),
      );
      return;
    }
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
