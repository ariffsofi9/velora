import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'widgets_home/bottom_bar.dart';
import '../../widgets/responsive_navigation.dart';
import '../../widgets/dashboard/dashboard_style.dart';
import '../../logic/low_stock_policy.dart';
import '../../services/android_pilot_policy.dart';
import '../../services/mutation_recovery_service.dart';
import '../../services/real_inventory_journal.dart'
    if (dart.library.js_interop) '../../services/real_inventory_journal_web.dart';
import '../../services/workspace_inventory_firebase_token_provider.dart';
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
  final Future<String?> Function(InventoryHttpsSession) refreshSyntheticBearer;
  final DateTime Function() now;
  final Future<http.Response> Function(http.Request) respond;
  final MutationRecoveryJournal? journal;

  const OfflineInventoryRest({
    required this.session,
    required this.refreshSyntheticBearer,
    this.now = DateTime.now,
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

  Future<String?> _refresh(InventoryHttpsSession captured) async {
    if (!session.matches(captured) || !_matches(captured.workspace)) {
      return null;
    }
    try {
      final token = await refreshSyntheticBearer(captured);
      if (!_matches(captured.workspace) ||
          token == null ||
          token.length > 8192) {
        return null;
      }
      final parts = token.split('.');
      if (parts.length != 3 ||
          !parts.every((part) => RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(part))) {
        return null;
      }
      // Local binding only. The canonical backend verifies the signature,
      // account freshness and transactional membership.
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (claims is! Map<String, dynamic> ||
          claims['sub'] != captured.uid ||
          claims['aud'] != captured.projectId ||
          claims['iss'] !=
              'https://securetoken.google.com/${captured.projectId}' ||
          claims['email_verified'] != true ||
          claims['exp'] is! int ||
          (claims['exp'] as int) <= now().millisecondsSinceEpoch ~/ 1000) {
        return null;
      }
      return token;
    } catch (_) {
      return null;
    }
  }
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
  HttpsWorkspaceInventory? _realInventory;
  http.Client? _realInventoryClient;
  int _realInventoryRevision = 0;
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
    if (policy == null ||
        policy.state != AndroidPilotState.normal ||
        _buildPolicy.state != AndroidPilotState.normal) {
      return;
    }
    if (config == null) {
      _configureRealInventory(workspace, policy);
      return;
    }
    if (!config._matches(workspace)) return;
    late final HttpsWorkspaceInventory adapter;
    adapter = HttpsWorkspaceInventory(
      pilotPolicy: policy,
      endpoint: Uri.https('inventory.offline.invalid'),
      projectId: OfflineInventoryRest.projectId,
      endpointProjectId: OfflineInventoryRest.projectId,
      client: MockClient(config.respond),
      currentSession: () =>
          identical(_inventoryMutations, adapter) && config._matches(workspace)
          ? config.session
          : null,
      sessionChanges: _inventorySessionChanges.stream,
      idToken: config._refresh,
      journal: config.journal,
    );
    _inventoryMutations = adapter;
  }

  void _configureRealInventory(
    WorkspaceSession workspace,
    AndroidPilotPolicy policy,
  ) {
    const project = HttpsWorkspaceInventory.realProject;
    final FirebaseAuth auth;
    try {
      auth = FirebaseAuth.instance;
    } catch (_) {
      return;
    }
    if (auth.app.options.projectId != project) return;
    final store = realInventoryJournal(workspace);
    if (store == null) return;
    final session = InventoryHttpsSession(
      workspace: workspace,
      projectId: project,
      uid: workspace.uid,
      emailVerified: true,
      revision: ++_realInventoryRevision,
    );
    late final HttpsWorkspaceInventory adapter;
    InventoryHttpsSession? currentSession() {
      final user = auth.currentUser;
      return identical(_realInventory, adapter) &&
              workspace.isActive &&
              user?.uid == workspace.uid &&
              user?.emailVerified == true
          ? session
          : null;
    }

    final client = http.Client();
    adapter = HttpsWorkspaceInventory(
      pilotPolicy: policy,
      endpoint: Uri.https(HttpsWorkspaceInventory.realHost),
      projectId: project,
      endpointProjectId: project,
      client: client,
      currentSession: currentSession,
      sessionChanges: _inventorySessionChanges.stream,
      idToken: WorkspaceInventoryFirebaseTokenProvider(
        auth: auth,
        projectId: project,
        currentSession: currentSession,
      ).call,
      guardedStore: store,
    );
    _realInventoryClient = client;
    _realInventory = adapter;
  }

  void _invalidateInventoryMutations() {
    if (_inventoryMutations == null && _realInventory == null) return;
    _inventoryMutations = null;
    _realInventory = null;
    _inventorySessionChanges.add(null);
    _realInventoryClient?.close();
    _realInventoryClient = null;
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
        onStockAlertTap: (attention) => _openAlerts(stockAttention: attention),
        onActivityTap: _openActivity,
      ),
      InventoryPage(
        workspaceSession: widget.workspaceSession,
        repository: _inventoryRepository,
        inventoryCreator: _realInventory ?? _inventoryMutations,
        inventoryUpdater: _realInventory ?? _inventoryMutations,
        stockAdjuster: _realInventory ?? _inventoryMutations,
        lifecycleManager: _realInventory ?? _inventoryMutations,
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
    final creator = _realInventory ?? _inventoryMutations;
    final session = widget.workspaceSession;
    if (creator != null && session.isActive) {
      Navigator.of(context).push<bool>(
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

  void _openAlerts({StockAttention? stockAttention}) {
    final workspace = widget.workspaceSession;
    final repository = _inventoryRepository;
    if (!workspace.isActive || !identical(repository.session, workspace)) {
      return;
    }
    final mutations = _realInventory ?? _inventoryMutations;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AlertsPage(
          workspaceSession: workspace,
          repository: repository,
          inventoryMutations: mutations,
          initialStockAttention: stockAttention,
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
    final side = usesSideNavigation(context);
    final navigation = VeloraBottomBar(
      currentIndex: _selectedIndex,
      onTap: _changePage,
      side: side,
    );
    final content = widget.workspaceSession.isActive
        ? KeyedSubtree(
            key: ObjectKey(widget.workspaceSession),
            child: _pages[_selectedIndex],
          )
        : const Center(child: Text('Workspace access could not be verified.'));
    return Scaffold(
      backgroundColor: DashboardStyle.background,
      body: Row(
        children: [
          if (side) navigation,
          Expanded(key: const ValueKey('workspace-content'), child: content),
        ],
      ),
      bottomNavigationBar: side ? null : navigation,
    );
  }
}
