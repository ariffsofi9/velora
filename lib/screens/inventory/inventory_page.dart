import 'dart:async';

import '../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

import '../../models/inventory_item.dart';
import '../../repositories/workspace_inventory_repository.dart';
import '../../repositories/workspace_inventory_movement_repository.dart';
import '../../services/mutation_recovery_service.dart';
import '../../services/workspace_session.dart';
import '../../services/workspace_inventory_create_service.dart';
import '../../services/workspace_inventory_https_transport.dart';
import '../../services/workspace_inventory_update_service.dart';
import '../../services/workspace_inventory_stock_service.dart';
import '../../services/workspace_inventory_lifecycle_service.dart';
import '../../services/inventory_csv_export_service.dart';
import 'add_item/add_item_page.dart';
import 'archived_items_page.dart';
import 'item_details_page.dart';
import 'stock/stock_history_page.dart';
import 'utils_inventory/inventory_sort_helper.dart';
import 'widgets_inventory/inventory_card.dart';
import 'widgets_inventory/inventory_empty_state.dart';
import 'widgets_inventory/inventory_filter_chips.dart';
import 'widgets_inventory/inventory_header_summary.dart';
import 'widgets_inventory/inventory_list_controls.dart';
import 'widgets_inventory/inventory_search_bar.dart';

class InventoryPage extends StatefulWidget {
  final WorkspaceSession workspaceSession;
  final WorkspaceInventoryRepository? repository;
  final WorkspaceInventoryCreator? inventoryCreator;
  final WorkspaceInventoryUpdater? inventoryUpdater;
  final WorkspaceInventoryStockAdjuster? stockAdjuster;
  final WorkspaceInventoryMovementReader? movementReader;
  final WorkspaceInventoryLifecycleManager? lifecycleManager;
  final InventoryCsvExportService? csvExportService;

  const InventoryPage({
    super.key,
    required this.workspaceSession,
    this.repository,
    this.inventoryCreator,
    this.inventoryUpdater,
    this.stockAdjuster,
    this.movementReader,
    this.lifecycleManager,
    this.csvExportService,
  });

  /// Used by the opt-in WorkspaceGate handoff with a synthetic read repository.
  factory InventoryPage.offlineRest({
    Key? key,
    required WorkspaceSession workspaceSession,
    required WorkspaceInventoryRepository repository,
    required HttpsWorkspaceInventory transport,
  }) {
    final mutations =
        workspaceSession.isActive &&
            transport.endpoint == Uri.https('inventory.offline.invalid') &&
            identical(repository.session, workspaceSession) &&
            identical(transport.currentSession()?.workspace, workspaceSession)
        ? transport
        : null;
    return InventoryPage(
      key: key,
      workspaceSession: workspaceSession,
      repository: repository,
      inventoryCreator: mutations,
      inventoryUpdater: mutations,
      stockAdjuster: mutations,
      lifecycleManager: mutations,
    );
  }

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final TextEditingController _searchController = TextEditingController();
  late WorkspaceInventoryRepository _repository;
  late Stream<List<InventoryItem>> _itemsStream;
  bool _exporting = false;
  int _exportGeneration = 0;
  _InventoryRecovery? _recovery;

  String _searchQuery = '';
  String _selectedFilter = 'All Items';
  String _selectedCategory = InventorySortHelper.allCategories;
  InventorySortOption _selectedSort = InventorySortOption.expiry;

  @override
  void initState() {
    super.initState();
    _configureRepository();
    _itemsStream = _watchVerifiedItems();
  }

  @override
  void didUpdateWidget(covariant InventoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_recovery case final recovery? when !_isRecoveryCurrent(recovery)) {
      _clearRecovery();
    }
    if (!identical(oldWidget.workspaceSession, widget.workspaceSession) ||
        !identical(oldWidget.repository, widget.repository)) {
      _configureRepository();
      _itemsStream = _watchVerifiedItems();
      _exportGeneration++;
      _searchController.clear();
      _searchQuery = '';
      _selectedFilter = 'All Items';
      _selectedCategory = InventorySortHelper.allCategories;
      _selectedSort = InventorySortOption.expiry;
    }
  }

  void _configureRepository() {
    _repository =
        widget.repository ??
        WorkspaceInventoryRepository(session: widget.workspaceSession);
  }

  bool get _hasVerifiedContext =>
      widget.workspaceSession.isActive &&
      identical(_repository.session, widget.workspaceSession);

  HttpsWorkspaceInventory? get _guardedInventory {
    if (!_hasVerifiedContext) return null;
    for (final adapter in [
      widget.stockAdjuster,
      widget.inventoryCreator,
      widget.inventoryUpdater,
      widget.lifecycleManager,
    ].whereType<HttpsWorkspaceInventory>()) {
      if (adapter.isGuarded &&
          identical(
            adapter.currentSession()?.workspace,
            widget.workspaceSession,
          )) {
        return adapter;
      }
    }
    return null;
  }

  bool _isRecoveryCurrent(_InventoryRecovery recovery) =>
      mounted &&
      identical(_recovery, recovery) &&
      identical(_guardedInventory, recovery.transport) &&
      recovery.session.matches(recovery.transport.currentSession());

  void _clearRecovery() {
    final recovery = _recovery;
    _recovery = null;
    unawaited(recovery?.changes?.cancel());
  }

  Future<void> _openRecovery() async {
    final transport = _guardedInventory;
    final session = transport?.currentSession();
    if (transport == null || session == null || _recovery != null) return;
    final recovery = _InventoryRecovery(transport, session);
    setState(() => _recovery = recovery);
    void revoke() {
      if (mounted && identical(_recovery, recovery)) setState(_clearRecovery);
    }

    recovery.changes = transport.sessionChanges.listen(
      (current) {
        if (!session.matches(current)) revoke();
      },
      onError: (Object _) => revoke(),
      onDone: revoke,
    );
    await _loadPending(recovery);
  }

  Future<void> _loadPending(_InventoryRecovery recovery) async {
    if (!_isRecoveryCurrent(recovery) || recovery.busy) return;
    setState(() {
      recovery.busy = true;
      recovery.message = 'Checking pending inventory changes…';
    });
    try {
      final pending = await recovery.transport.pendingInventory();
      if (!_isRecoveryCurrent(recovery)) return;
      setState(() {
        recovery.pending = pending;
        recovery.message = pending.isEmpty
            ? 'No pending inventory changes are available for this session.'
            : 'Pending inventory changes are unresolved.';
      });
    } catch (_) {
      if (!_isRecoveryCurrent(recovery)) return;
      setState(() {
        recovery.pending = const [];
        recovery.message = 'Could not check pending inventory changes.';
      });
    } finally {
      if (_isRecoveryCurrent(recovery)) {
        setState(() => recovery.busy = false);
      }
    }
  }

  Future<void> _observePending(
    _InventoryRecovery recovery,
    PendingMutationOperation pending,
  ) async {
    if (!_isRecoveryCurrent(recovery) || recovery.busy) return;
    setState(() {
      recovery.busy = true;
      recovery.message = 'Reconciling the original inventory change…';
    });
    try {
      final result = await recovery.transport.reconcile(pending);
      if (!_isRecoveryCurrent(recovery)) return;
      setState(() {
        if (result.committed) {
          recovery.pending = recovery.pending
              .where((record) => !identical(record, pending))
              .toList();
          recovery.message = 'The original inventory change was confirmed.';
          _itemsStream = _watchVerifiedItems();
        } else {
          recovery.message =
              'The original inventory change is still unresolved.';
        }
      });
    } catch (_) {
      if (!_isRecoveryCurrent(recovery)) return;
      setState(() {
        recovery.message =
            'Could not confirm the inventory change. Check pending changes again.';
      });
    } finally {
      if (_isRecoveryCurrent(recovery)) {
        setState(() => recovery.busy = false);
      }
    }
  }

  Widget _recoverySheet(BuildContext context, _InventoryRecovery recovery) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .45,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Expanded(child: Text('Inventory recovery')),
                TextButton(
                  key: const ValueKey('inventory-recovery-close'),
                  onPressed: recovery.busy
                      ? null
                      : () => setState(_clearRecovery),
                  child: const Text('Close'),
                ),
              ],
            ),
            Text(recovery.message),
            for (final pending in recovery.pending)
              ListTile(
                title: Text(switch (pending.operation) {
                  'create' => 'Add item',
                  'update' => 'Edit item',
                  'adjust-stock' =>
                    pending.request['direction'] == 'in'
                        ? 'Stock In'
                        : 'Stock Out',
                  'lifecycle' =>
                    pending.request['action'] == 'archive'
                        ? 'Archive item'
                        : 'Restore item',
                  _ => 'Inventory change',
                }),
                subtitle: switch (pending.request[pending.operation == 'create'
                    ? 'name'
                    : 'itemId']) {
                  final String itemId => Text(
                    itemId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  _ => null,
                },
                trailing: TextButton(
                  onPressed: recovery.busy
                      ? null
                      : () => _observePending(recovery, pending),
                  child: const Text('Check outcome'),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: recovery.busy ? null : () => _loadPending(recovery),
                child: const Text('Reload pending changes'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Stream<List<InventoryItem>> _watchVerifiedItems() => _hasVerifiedContext
      ? _repository.watchItems()
      : Stream.error(StateError('Workspace access could not be verified.'));

  bool _requireVerifiedContext() {
    if (_hasVerifiedContext) return true;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Workspace access could not be verified.')),
    );
    return false;
  }

  void _showMutationsUnavailable() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Inventory changes are unavailable until secure workspace updates are enabled.',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _exportGeneration++;
    _clearRecovery();
    _searchController.dispose();
    super.dispose();
  }

  List<InventoryItem> _applySearchFilterSort(List<InventoryItem> items) {
    return InventorySortHelper.apply(
      items: items,
      query: _searchQuery,
      category: _selectedCategory,
      statusFilter: _selectedFilter,
      sort: _selectedSort,
    );
  }

  void _retry() {
    setState(() => _itemsStream = _watchVerifiedItems());
  }

  void _clearListControls() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _selectedFilter = 'All Items';
      _selectedCategory = InventorySortHelper.allCategories;
      _selectedSort = InventorySortOption.expiry;
    });
  }

  Future<void> _goToAddItem() async {
    if (!_requireVerifiedContext()) return;
    final creator = widget.inventoryCreator;
    if (creator == null) {
      _showMutationsUnavailable();
      return;
    }
    final workspace = widget.workspaceSession;
    final confirmed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AddItemPage(workspaceSession: workspace, creator: creator),
      ),
    );
    if (confirmed == true &&
        mounted &&
        _hasVerifiedContext &&
        identical(workspace, widget.workspaceSession) &&
        identical(creator, widget.inventoryCreator)) {
      _retry();
    }
  }

  Future<void> _goToDetails(InventoryItem item) async {
    if (!_requireVerifiedContext()) return;
    final workspace = widget.workspaceSession;
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ItemDetailsPage(
          item: item,
          workspaceSession: workspace,
          repository: _repository,
          updater: widget.inventoryUpdater,
          stockAdjuster: widget.stockAdjuster,
          movementReader: widget.movementReader,
          lifecycleManager: widget.lifecycleManager,
        ),
      ),
    );
    if (changed == true &&
        mounted &&
        _hasVerifiedContext &&
        identical(workspace, widget.workspaceSession)) {
      _retry();
    }
  }

  void _goToArchivedItems() {
    if (!_requireVerifiedContext()) return;
    final workspace = widget.workspaceSession;
    final repository = _repository;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArchivedItemsPage(
          workspaceSession: workspace,
          repository: repository,
          lifecycleManager: widget.lifecycleManager,
          movementReader: widget.movementReader,
          onRefresh: () {
            if (mounted &&
                _hasVerifiedContext &&
                identical(widget.workspaceSession, workspace) &&
                identical(_repository, repository)) {
              _retry();
            }
          },
        ),
      ),
    );
  }

  void _goToStockHistory(InventoryItem item) {
    if (!_requireVerifiedContext()) return;
    final workspace = widget.workspaceSession;
    final reader = widget.movementReader;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StockHistoryPage(
          item: item,
          workspaceSession: workspace,
          movementReader: reader,
        ),
      ),
    );
  }

  Future<void> _chooseExport() async {
    if (!_requireVerifiedContext() || _exporting) return;
    final generation = ++_exportGeneration;
    final service =
        widget.csvExportService ??
        InventoryCsvExportService(repository: _repository);
    final expected = widget.workspaceSession;
    StreamSubscription<dynamic>? subscription;
    setState(() => _exporting = true);
    try {
      var lastUid = service.auth.currentUser?.uid;
      subscription = service.auth.authStateChanges().listen(
        (user) {
          if (user?.uid != lastUid) _exportGeneration++;
          lastUid = user?.uid;
        },
        onError: (Object _) {
          _exportGeneration++;
        },
      );
      bool current() =>
          mounted &&
          generation == _exportGeneration &&
          service.auth.currentUser?.uid == expected.uid &&
          _hasVerifiedContext &&
          identical(expected, widget.workspaceSession);
      if (!current()) return;
      final scope = await showDialog<InventoryCsvScope>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Export inventory'),
          content: const Text('Choose which café inventory records to export.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const ValueKey('export-active-only'),
              onPressed: () =>
                  Navigator.pop(context, InventoryCsvScope.activeOnly),
              child: const Text('Active only'),
            ),
            FilledButton(
              key: const ValueKey('export-include-archived'),
              onPressed: () =>
                  Navigator.pop(context, InventoryCsvScope.includeArchived),
              child: const Text('Include archived'),
            ),
          ],
        ),
      );
      if (scope == null || !current()) return;
      final result = await service.export(scope, isSessionCurrent: current);
      if (!mounted || !current()) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Exported ${result.itemCount} inventory items.'),
        ),
      );
    } on InventoryCsvEmptyException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('There are no items to export.')),
      );
    } on InventoryCsvSessionChangedException {
      return;
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Inventory export failed. Please try again.'),
        ),
      );
    } finally {
      unawaited(subscription?.cancel());
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallPhone = screenWidth < 370;
    final horizontalPadding = isSmallPhone ? 16.0 : 20.0;
    final recovery = _recovery;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        centerTitle: false,
        automaticallyImplyLeading: false,
        title: Text(
          'Inventory',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: isSmallPhone ? 20 : 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          if (_guardedInventory != null)
            IconButton(
              key: const ValueKey('inventory-recovery-open'),
              onPressed: recovery == null ? _openRecovery : null,
              tooltip: 'Inventory recovery',
              icon: const Icon(Icons.history_rounded),
            ),
          IconButton(
            key: const ValueKey('open-archived-items'),
            onPressed: _goToArchivedItems,
            tooltip: 'Archived Items',
            icon: const Icon(Icons.archive_outlined),
          ),
        ],
      ),
      body: StreamBuilder<List<InventoryItem>>(
        key: ObjectKey(_itemsStream),
        stream: _itemsStream,
        builder: (context, snapshot) {
          if (!_hasVerifiedContext || snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  key: const ValueKey('inventory-read-error'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.cloud_off_rounded,
                      color: AppColors.textSecondary,
                      size: 42,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Inventory could not be loaded.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Check your connection and try again.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _hasVerifiedContext ? _retry : null,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          if (!snapshot.hasData) {
            return const Center(
              child: Column(
                key: ValueKey('inventory-loading'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppColors.primary),
                  SizedBox(height: 12),
                  Text(
                    'Loading inventory…',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ],
              ),
            );
          }

          final items = snapshot.data!;
          final categories = InventorySortHelper.categories(items);
          if (!categories.contains(_selectedCategory)) {
            _selectedCategory = InventorySortHelper.allCategories;
          }
          final visibleItems = _applySearchFilterSort(items);

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        6,
                        horizontalPadding,
                        12,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InventoryHeaderSummary(
                            totalItems: items.length,
                            visibleItems: visibleItems.length,
                            isSmallPhone: isSmallPhone,
                          ),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerRight,
                            child: OutlinedButton.icon(
                              key: const ValueKey('export-inventory-csv'),
                              onPressed: _exporting ? null : _chooseExport,
                              icon: _exporting
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.download_outlined),
                              label: const Text('Export CSV'),
                            ),
                          ),
                          const SizedBox(height: 14),
                          InventorySearchBar(
                            controller: _searchController,
                            onChanged: (value) {
                              setState(() => _searchQuery = value);
                            },
                          ),
                          const SizedBox(height: 14),
                          InventoryFilterChips(
                            selectedFilter: _selectedFilter,
                            onSelected: (value) {
                              setState(() => _selectedFilter = value);
                            },
                          ),
                          const SizedBox(height: 14),
                          InventoryListControls(
                            // Recreate form-field state when controlled values change.
                            key: ValueKey((
                              _selectedCategory,
                              _selectedSort,
                              Object.hashAll(categories),
                            )),
                            categories: categories,
                            selectedCategory: _selectedCategory,
                            selectedSort: _selectedSort,
                            onCategoryChanged: (value) {
                              setState(() => _selectedCategory = value);
                            },
                            onSortChanged: (value) {
                              setState(() => _selectedSort = value);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (items.isEmpty)
                    SliverToBoxAdapter(
                      child: InventoryEmptyState(onAdd: _goToAddItem),
                    )
                  else if (visibleItems.isEmpty)
                    SliverToBoxAdapter(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            key: const ValueKey('inventory-no-matches'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'No matching items found.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextButton(
                                onPressed: _clearListControls,
                                child: const Text('Clear filters'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        4,
                        horizontalPadding,
                        110,
                      ),
                      sliver: SliverList.builder(
                        itemCount: visibleItems.length,
                        itemBuilder: (context, index) {
                          final item = visibleItems[index];
                          return InventoryCard(
                            item: item,
                            onTap: () => _goToDetails(item),
                            onHistory: () => _goToStockHistory(item),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
      bottomSheet: recovery != null && _isRecoveryCurrent(recovery)
          ? _recoverySheet(context, recovery)
          : null,
      floatingActionButton: FloatingActionButton(
        onPressed: _goToAddItem,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: const Icon(Icons.add_rounded, size: 30),
      ),
    );
  }
}

class _InventoryRecovery {
  final HttpsWorkspaceInventory transport;
  final InventoryHttpsSession session;
  StreamSubscription<InventoryHttpsSession?>? changes;
  List<PendingMutationOperation> pending = const [];
  String message = '';
  bool busy = false;

  _InventoryRecovery(this.transport, this.session);
}
