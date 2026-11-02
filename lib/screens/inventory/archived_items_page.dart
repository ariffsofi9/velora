import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../models/inventory_item.dart';
import '../../repositories/workspace_inventory_repository.dart';
import '../../services/workspace_inventory_lifecycle_service.dart';
import '../../services/workspace_session.dart';
import 'item_details_page.dart';

class ArchivedItemsPage extends StatefulWidget {
  final WorkspaceSession workspaceSession;
  final WorkspaceInventoryRepository repository;
  final WorkspaceInventoryLifecycleManager? lifecycleManager;

  const ArchivedItemsPage({
    super.key,
    required this.workspaceSession,
    required this.repository,
    this.lifecycleManager,
  });

  @override
  State<ArchivedItemsPage> createState() => _ArchivedItemsPageState();
}

class _ArchivedItemsPageState extends State<ArchivedItemsPage> {
  late Stream<List<InventoryItem>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = widget.repository.watchArchivedItems();
  }

  void _retry() {
    setState(() => _stream = widget.repository.watchArchivedItems());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(title: const Text('Archived Items')),
    body: StreamBuilder<List<InventoryItem>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Archived items cannot load right now.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  key: const ValueKey('archived-retry'),
                  onPressed: _retry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        final items = snapshot.data ?? const <InventoryItem>[];
        if (items.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No archived items.',
                key: ValueKey('archived-empty'),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final item = items[index];
            return Card(
              child: ListTile(
                key: ValueKey('archived-${item.id}'),
                leading: const Icon(Icons.archive_outlined),
                title: Text(item.name),
                subtitle: Text(
                  '${item.quantity} ${item.unit} • ${item.category}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ItemDetailsPage(
                      item: item,
                      workspaceSession: widget.workspaceSession,
                      repository: widget.repository,
                      lifecycleManager: widget.lifecycleManager,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
