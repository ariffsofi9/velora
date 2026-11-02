import '../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

import '../../models/inventory_item.dart';
import '../../repositories/workspace_inventory_repository.dart';
import '../../repositories/workspace_inventory_movement_repository.dart';
import '../../services/workspace_session.dart';
import '../../services/workspace_inventory_create_service.dart';
import '../../services/workspace_inventory_update_service.dart';
import '../../services/workspace_inventory_stock_service.dart';
import 'add_item/add_item_page.dart';
import 'item_details_page.dart';
import 'utils_inventory/inventory_sort_helper.dart';
import 'widgets_inventory/inventory_card.dart';
import 'widgets_inventory/inventory_empty_state.dart';
import 'widgets_inventory/inventory_filter_chips.dart';
import 'widgets_inventory/inventory_header_summary.dart';
import 'widgets_inventory/inventory_search_bar.dart';

class InventoryPage extends StatefulWidget {
  final WorkspaceSession workspaceSession;
  final WorkspaceInventoryRepository? repository;
  final WorkspaceInventoryCreator? inventoryCreator;
  final WorkspaceInventoryUpdater? inventoryUpdater;
  final WorkspaceInventoryStockAdjuster? stockAdjuster;
  final WorkspaceInventoryMovementReader? movementReader;

  const InventoryPage({
    super.key,
    required this.workspaceSession,
    this.repository,
    this.inventoryCreator,
    this.inventoryUpdater,
    this.stockAdjuster,
    this.movementReader,
  });

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final TextEditingController _searchController = TextEditingController();
  late final WorkspaceInventoryRepository _repository;
  late final Stream<List<InventoryItem>> _itemsStream;

  String _searchQuery = '';
  String _selectedFilter = 'All Items';

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
    var result = InventorySortHelper.sortByExpiry(items);
    result = InventorySortHelper.searchItems(result, _searchQuery);
    result = InventorySortHelper.filterItems(result, _selectedFilter);
    return result;
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
      ),
      body: StreamBuilder<List<InventoryItem>>(
        stream: _itemsStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('Something went wrong.'));
          }

          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            );
          }

          final items = snapshot.data!;
          final visibleItems = _applySearchFilterSort(items);

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                children: [
                  Padding(
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
                      ],
                    ),
                  ),
                  Expanded(
                    child: items.isEmpty
                        ? InventoryEmptyState(onAdd: _goToAddItem)
                        : visibleItems.isEmpty
                        ? const Center(
                            child: Text(
                              'No matching items found.',
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: EdgeInsets.fromLTRB(
                              horizontalPadding,
                              4,
                              horizontalPadding,
                              110,
                            ),
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
