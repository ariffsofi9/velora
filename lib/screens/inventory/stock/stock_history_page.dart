import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../models/inventory_item.dart';
import '../../../models/inventory_movement.dart';
import '../../../repositories/workspace_inventory_movement_repository.dart';
import '../../../services/workspace_session.dart';

class StockHistoryPage extends StatefulWidget {
  final InventoryItem item;
  final WorkspaceSession workspaceSession;
  final WorkspaceInventoryMovementReader? movementReader;

  const StockHistoryPage({
    super.key,
    required this.item,
    required this.workspaceSession,
    this.movementReader,
  });

  @override
  State<StockHistoryPage> createState() => _StockHistoryPageState();
}

class _StockHistoryPageState extends State<StockHistoryPage> {
  late WorkspaceInventoryMovementReader _reader;
  final List<InventoryMovement> _movements = [];
  WorkspaceMovementCursor? _cursor;
  WorkspaceMovementFailure? _failure;
  WorkspaceMovementFailure? _loadMoreFailure;
  bool _loading = false;
  bool _loadingMore = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _configureReader();
    _loadFirstPage();
  }

  @override
  void didUpdateWidget(covariant StockHistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.workspaceSession.cafeId != widget.workspaceSession.cafeId ||
        oldWidget.movementReader != widget.movementReader) {
      _generation += 1;
      _configureReader();
      _movements.clear();
      _cursor = null;
      _failure = null;
      _loadMoreFailure = null;
      _loading = false;
      _loadingMore = false;
      _loadFirstPage();
    }
  }

  void _configureReader() {
    _reader =
        widget.movementReader ??
        WorkspaceInventoryMovementRepository(session: widget.workspaceSession);
  }

  Future<void> _loadFirstPage() async {
    if (_loading) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final page = await _reader.getItemMovements(widget.item.id);
      if (!mounted || generation != _generation) return;
      setState(() {
        _movements
          ..clear()
          ..addAll(page.movements);
        _cursor = page.nextCursor;
        _loading = false;
      });
    } on WorkspaceMovementException catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _failure = error.failure;
      });
    }
  }

  Future<void> _loadMore() async {
    final cursor = _cursor;
    if (cursor == null || _loadingMore) return;
    final generation = _generation;
    setState(() {
      _loadingMore = true;
      _loadMoreFailure = null;
    });
    try {
      final page = await _reader.getItemMovements(
        widget.item.id,
        cursor: cursor,
      );
      if (!mounted || generation != _generation) return;
      final existing = _movements.map((movement) => movement.id).toSet();
      setState(() {
        _movements.addAll(
          page.movements.where((movement) => existing.add(movement.id)),
        );
        _cursor = page.nextCursor;
        _loadingMore = false;
      });
    } on WorkspaceMovementException catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingMore = false;
        _loadMoreFailure = error.failure;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(
      title: const Text(
        'Stock History',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: _body(),
        ),
      ),
    ),
  );

  Widget _body() {
    if (_loading && _movements.isEmpty) {
      return const Center(
        key: ValueKey('stock-history-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_failure != null && _movements.isEmpty) {
      return _HistoryState(
        key: const ValueKey('stock-history-error'),
        icon: Icons.error_outline_rounded,
        title: _failureTitle(_failure!),
        message: _failureMessage(_failure!),
        actionLabel: 'Retry',
        onAction: _loadFirstPage,
      );
    }
    if (_movements.isEmpty) {
      return const _HistoryState(
        key: ValueKey('stock-history-empty'),
        icon: Icons.history_rounded,
        title: 'No stock history yet',
        message: 'Stock movements for this item will appear here.',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          widget.item.name,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Newest movements first',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        for (final movement in _movements) ...[
          _MovementCard(
            key: ValueKey('movement-${movement.id}'),
            movement: movement,
          ),
          const SizedBox(height: 10),
        ],
        if (_loadMoreFailure != null) ...[
          Text(
            _failureMessage(_loadMoreFailure!),
            key: const ValueKey('stock-history-load-more-error'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.danger),
          ),
          const SizedBox(height: 8),
        ],
        if (_cursor != null)
          OutlinedButton(
            key: const ValueKey('stock-history-load-more'),
            onPressed: _loadingMore ? null : _loadMore,
            child: _loadingMore
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_loadMoreFailure == null ? 'Load More' : 'Retry'),
          )
        else
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'End of stock history',
              key: ValueKey('stock-history-end'),
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }

  String _failureTitle(WorkspaceMovementFailure failure) => switch (failure) {
    WorkspaceMovementFailure.permissionDenied => 'History unavailable',
    WorkspaceMovementFailure.unavailable => 'Unable to load history',
    WorkspaceMovementFailure.invalidData => 'History data is invalid',
  };

  String _failureMessage(WorkspaceMovementFailure failure) => switch (failure) {
    WorkspaceMovementFailure.permissionDenied =>
      'You no longer have permission to view this item history.',
    WorkspaceMovementFailure.unavailable =>
      'Check your connection and try again.',
    WorkspaceMovementFailure.invalidData =>
      'A movement record could not be read safely.',
  };
}

class _MovementCard extends StatelessWidget {
  final InventoryMovement movement;
  const _MovementCard({super.key, required this.movement});

  @override
  Widget build(BuildContext context) {
    final stockIn = movement.type == InventoryMovementType.stockIn;
    final stockOut = movement.type == InventoryMovementType.stockOut;
    final color = stockOut ? AppColors.warning : AppColors.success;
    final title = switch (movement.type) {
      InventoryMovementType.initialStock => 'Initial Stock',
      InventoryMovementType.stockIn => 'Stock In',
      InventoryMovementType.stockOut => 'Stock Out',
    };
    final quantity = movement.type == InventoryMovementType.initialStock
        ? '${movement.quantity} ${movement.unit}'
        : '${stockIn ? '+' : '−'}${movement.quantity} ${movement.unit}';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                stockOut
                    ? Icons.remove_circle_outline
                    : Icons.add_circle_outline,
                color: color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                quantity,
                style: TextStyle(color: color, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _formatDate(movement.createdAt),
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          if (movement.previousQuantity != null &&
              movement.resultingQuantity != null) ...[
            const SizedBox(height: 8),
            Text(
              'Balance: ${movement.previousQuantity} → '
              '${movement.resultingQuantity} ${movement.unit}',
            ),
          ],
          if (movement.reason != null) ...[
            const SizedBox(height: 8),
            Text('Reason: ${movement.reason}'),
          ],
        ],
      ),
    );
  }

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '• ${two(local.hour)}:${two(local.minute)}';
  }
}

class _HistoryState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _HistoryState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: AppColors.primary),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          if (onAction != null && actionLabel != null) ...[
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}
