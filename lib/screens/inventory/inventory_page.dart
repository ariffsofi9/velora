import '../../core/theme/app_tokens.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../models/inventory_item.dart';
import 'item_details_page.dart';
import 'utils_inventory/inventory_sort_helper.dart';
import 'widgets_inventory/inventory_card.dart';
import 'widgets_inventory/inventory_empty_state.dart';
import 'widgets_inventory/inventory_filter_chips.dart';
import 'widgets_inventory/inventory_header_summary.dart';
import 'widgets_inventory/inventory_search_bar.dart';

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final TextEditingController _searchController = TextEditingController();

  String _searchQuery = '';
  String _selectedFilter = 'All Items';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  DateTime _parseExpiry(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
    return DateTime.now();
  }

  InventoryItem _itemFromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    return InventoryItem(
      id: doc.id,
      name: data['name'] ?? '',
      category: data['category'] ?? '',
      quantity: data['quantity'] ?? 0,
      expiryDate: _parseExpiry(data['expiryDate']),
      imageUrl: data['imageUrl'] ?? '',
      createdAt: DateTime.now(),
    );
  }

  List<InventoryItem> _applySearchFilterSort(List<InventoryItem> items) {
    var result = InventorySortHelper.sortByExpiry(items);
    result = InventorySortHelper.searchItems(result, _searchQuery);
    result = InventorySortHelper.filterItems(result, _selectedFilter);
    return result;
  }

  void _goToAddItem() {
    Navigator.pushNamed(context, '/add-item');
  }

  void _goToDetails(InventoryItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ItemDetailsPage(item: item)),
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
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('inventory').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('Something went wrong.'));
          }

          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            );
          }

          final items = snapshot.data!.docs.map(_itemFromDoc).toList();
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
