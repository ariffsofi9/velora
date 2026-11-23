import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../models/inventory_item.dart';
import '../../repositories/workspace_inventory_repository.dart';
import '../../repositories/workspace_inventory_movement_repository.dart';
import '../../services/workspace_inventory_lifecycle_service.dart';
import '../../services/workspace_session.dart';
import 'item_details_page.dart';
import 'stock/stock_history_page.dart';

class ArchivedItemsPage extends StatefulWidget {
  final WorkspaceSession workspaceSession;
  final WorkspaceInventoryRepository repository;
  final WorkspaceInventoryLifecycleManager? lifecycleManager;
  final WorkspaceInventoryMovementReader? movementReader;
  final VoidCallback? onRefresh;

  const ArchivedItemsPage({
    super.key,
    required this.workspaceSession,
    required this.repository,
    this.lifecycleManager,
    this.movementReader,
    this.onRefresh,
  });

  @override
  State<ArchivedItemsPage> createState() => _ArchivedItemsPageState();
}

class _ArchivedItemsPageState extends State<ArchivedItemsPage> {
  late Stream<List<InventoryItem>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _watchArchivedItems();
  }

  @override
  void didUpdateWidget(covariant ArchivedItemsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspaceSession, widget.workspaceSession) ||
        !identical(oldWidget.repository, widget.repository)) {
      _stream = _watchArchivedItems();
    }
  }

  bool get _hasVerifiedContext =>
      widget.workspaceSession.isActive &&
      identical(widget.repository.session, widget.workspaceSession);

  Stream<List<InventoryItem>> _watchArchivedItems() => _hasVerifiedContext
      ? widget.repository.watchArchivedItems()
      : const Stream.empty();

  void _retry() {
    setState(() => _stream = _watchArchivedItems());
  }

  void _goToStockHistory(InventoryItem item) {
    if (!_hasVerifiedContext) return;
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

  Future<void> _goToDetails(InventoryItem item) async {
    if (!_hasVerifiedContext) return;
    final workspace = widget.workspaceSession;
    final repository = widget.repository;
    final refresh = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ItemDetailsPage(
          item: item,
          workspaceSession: workspace,
          repository: repository,
          lifecycleManager: widget.lifecycleManager,
          movementReader: widget.movementReader,
        ),
      ),
    );
    if (refresh == true &&
        mounted &&
        _hasVerifiedContext &&
        identical(widget.workspaceSession, workspace) &&
        identical(widget.repository, repository)) {
      _retry();
      widget.onRefresh?.call();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(title: const Text('Archived Items')),
    body: StreamBuilder<List<InventoryItem>>(
      key: ObjectKey(_stream),
      stream: _stream,
      builder: (context, snapshot) {
        if (!_hasVerifiedContext) {
          return const Center(
            child: Text('Workspace access could not be verified.'),
          );
        }
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
                trailing: IconButton(
                  tooltip: 'Stock history for ${item.name}',
                  onPressed: () => _goToStockHistory(item),
                  icon: const Icon(Icons.history_rounded),
                ),
                onTap: () => _goToDetails(item),
              ),
            );
          },
        );
      },
    ),
  );
}
