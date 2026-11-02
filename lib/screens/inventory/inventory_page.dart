import '../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

import '../../models/inventory_item.dart';
import '../../repositories/workspace_inventory_repository.dart';
import '../../repositories/workspace_inventory_movement_repository.dart';
import '../../services/workspace_session.dart';
import '../../services/workspace_inventory_create_service.dart';
import '../../services/workspace_inventory_update_service.dart';
import '../../services/workspace_inventory_stock_service.dart';
import '../../services/workspace_inventory_lifecycle_service.dart';
import 'add_item/add_item_page.dart';
import 'archived_items_page.dart';
import 'item_details_page.dart';
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

  const InventoryPage({
    super.key,
    required this.workspaceSession,
    this.repository,
    this.inventoryCreator,
    this.inventoryUpdater,
    this.stockAdjuster,
    this.movementReader,
    this.lifecycleManager,
  });

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final TextEditingController _searchController = TextEditingController();
  late final WorkspaceInventoryRepository _repository;
  late Stream<List<InventoryItem>> _itemsStream;

  String _searchQuery = '';
  String _selectedFilter = 'All Items';
  String _selectedCategory = InventorySortHelper.allCategories;
  InventorySortOption _selectedSort = InventorySortOption.expiry;

  @override
  void initState() {
    super.initState();
    _repository =
        widget.repository ??
        WorkspaceInventoryRepository(session: widget.workspaceSession);
    _itemsStream = _repository.watchItems();
  }

  @override
  void dispose() {
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
    setState(() => _itemsStream = _repository.watchItems());
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

  void _goToAddItem() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddItemPage(
          workspaceSession: widget.workspaceSession,
          creator: widget.inventoryCreator,
        ),
      ),
    );
  }

  void _goToDetails(InventoryItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ItemDetailsPage(
          item: item,
          workspaceSession: widget.workspaceSession,
          repository: _repository,
          updater: widget.inventoryUpdater,
          stockAdjuster: widget.stockAdjuster,
          movementReader: widget.movementReader,
          lifecycleManager: widget.lifecycleManager,
        ),
      ),
    );
  }

  void _goToArchivedItems() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArchivedItemsPage(
          workspaceSession: widget.workspaceSession,
          repository: _repository,
          lifecycleManager: widget.lifecycleManager,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallPhone = screenWidth < 370;
    final horizontalPadding = isSmallPhone ? 16.0 : 20.0;

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
          IconButton(
            key: const ValueKey('open-archived-items'),
            onPressed: _goToArchivedItems,
            tooltip: 'Archived Items',
            icon: const Icon(Icons.archive_outlined),
          ),
        ],
      ),
      body: StreamBuilder<List<InventoryItem>>(
        stream: _itemsStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
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
                      onPressed: _retry,
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
          final visibleItems = _applySearchFilterSort(items);
          final categories = InventorySortHelper.categories(items);

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
