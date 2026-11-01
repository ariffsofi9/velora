import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../models/inventory_item.dart';
import '../../../repositories/workspace_inventory_repository.dart';
import '../../../services/workspace_inventory_stock_service.dart';
import '../../../services/workspace_session.dart';

enum StockAdjustmentType { stockIn, stockOut }

class StockInPage extends StatelessWidget {
  final InventoryItem item;
  final WorkspaceSession? workspaceSession;
  final WorkspaceInventoryRepository? repository;
  final WorkspaceInventoryStockAdjuster? adjuster;
  final String Function()? idempotencyKeyFactory;
  const StockInPage({
    super.key,
    required this.item,
    this.workspaceSession,
    this.repository,
    this.adjuster,
    this.idempotencyKeyFactory,
  });

  @override
  Widget build(BuildContext context) => StockAdjustmentPage(
    item: item,
    type: StockAdjustmentType.stockIn,
    workspaceSession: workspaceSession,
    repository: repository,
    adjuster: adjuster,
    idempotencyKeyFactory: idempotencyKeyFactory,
  );
}

class StockOutPage extends StatelessWidget {
  final InventoryItem item;
  final WorkspaceSession? workspaceSession;
  final WorkspaceInventoryRepository? repository;
  final WorkspaceInventoryStockAdjuster? adjuster;
  final String Function()? idempotencyKeyFactory;
  const StockOutPage({
    super.key,
    required this.item,
    this.workspaceSession,
    this.repository,
    this.adjuster,
    this.idempotencyKeyFactory,
  });

  @override
  Widget build(BuildContext context) => StockAdjustmentPage(
    item: item,
    type: StockAdjustmentType.stockOut,
    workspaceSession: workspaceSession,
    repository: repository,
    adjuster: adjuster,
    idempotencyKeyFactory: idempotencyKeyFactory,
  );
}

class StockAdjustmentPage extends StatefulWidget {
  final InventoryItem item;
  final StockAdjustmentType type;
  final WorkspaceSession? workspaceSession;
  final WorkspaceInventoryRepository? repository;
  final WorkspaceInventoryStockAdjuster? adjuster;
  final String Function()? idempotencyKeyFactory;
  const StockAdjustmentPage({
    super.key,
    required this.item,
    required this.type,
    this.workspaceSession,
    this.repository,
    this.adjuster,
    this.idempotencyKeyFactory,
  });

  @override
  State<StockAdjustmentPage> createState() => _StockAdjustmentPageState();
}

class _StockAdjustmentPageState extends State<StockAdjustmentPage> {
  static const maxSafeInteger = 9007199254740991;
  final quantityController = TextEditingController();
  final reasonController = TextEditingController();
  late InventoryItem item;
  late final WorkspaceInventoryStockAdjuster adjuster;
  bool touched = false, saving = false, refreshing = false;
  bool needsReload = false, completed = false;
  String? fingerprint, idempotencyKey;

  bool get stockOut => widget.type == StockAdjustmentType.stockOut;
  String get title => stockOut ? 'Stock Out' : 'Stock In';
  int? get quantity => int.tryParse(quantityController.text.trim());
  bool get verified =>
      widget.workspaceSession != null && item.id.trim().isNotEmpty;
  String? get quantityError {
    if (!touched) return null;
    final value = quantity;
    if (value == null || value <= 0 || value > maxSafeInteger) {
      return 'Enter a whole number above 0.';
    }
    if (stockOut && value > item.quantity) {
      return 'Quantity cannot exceed available stock.';
    }
    if (!stockOut && item.quantity > maxSafeInteger - value) {
      return 'Result exceeds the supported quantity range.';
    }
    return null;
  }

  int? get preview {
    if (quantityError != null) return null;
    final value = quantity;
    if (value == null || value <= 0) return null;
    return stockOut ? item.quantity - value : item.quantity + value;
  }

  @override
  void initState() {
    super.initState();
    item = widget.item;
    adjuster = widget.adjuster ?? FirebaseWorkspaceInventoryStockAdjuster();
  }

  @override
  void dispose() {
    quantityController.dispose();
    reasonController.dispose();
    super.dispose();
  }

  String newKey() {
    final random = Random.secure();
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
        '${random.nextInt(1 << 32).toRadixString(36).padLeft(7, '0')}-stock';
  }

  Future<void> submit() async {
    setState(() => touched = true);
    if (!verified) return message('A verified workspace item is required.');
    if (saving || needsReload || completed || quantityError != null) return;
    final value = quantity;
    final reason = reasonController.text.trim();
    if (value == null || value <= 0) return;
    if (reason.length > 200) {
      return message('Reason must be 200 characters or less.');
    }
    final draft = WorkspaceInventoryStockRequest(
      idempotencyKey: 'pending-idempotency-key',
      itemId: item.id,
      direction: stockOut ? StockDirection.stockOut : StockDirection.stockIn,
      quantity: value,
      expectedVersion: item.version,
      reason: reason,
    );
    if (fingerprint != draft.fingerprint || idempotencyKey == null) {
      fingerprint = draft.fingerprint;
      idempotencyKey = widget.idempotencyKeyFactory?.call() ?? newKey();
    }
    final request = WorkspaceInventoryStockRequest(
      idempotencyKey: idempotencyKey!,
      itemId: draft.itemId,
      direction: draft.direction,
      quantity: draft.quantity,
      expectedVersion: draft.expectedVersion,
      reason: draft.reason,
    );
    setState(() => saving = true);
    try {
      await adjuster.adjustStock(request);
      if (!mounted) return;
      setState(() {
        saving = false;
        completed = true;
      });
      message('$title completed successfully.');
      Navigator.pop(context, true);
    } on WorkspaceInventoryStockException catch (error) {
      if (!mounted) return;
      final reload =
          error.failure == WorkspaceInventoryStockFailure.stale ||
          error.failure == WorkspaceInventoryStockFailure.insufficientStock;
      setState(() {
        saving = false;
        needsReload = reload;
      });
      message(failureMessage(error.failure));
    }
  }

  Future<void> reload() async {
    final repository = widget.repository;
    if (repository == null || refreshing) return;
    setState(() => refreshing = true);
    try {
      final items = await repository.getItems();
      InventoryItem? latest;
      for (final candidate in items) {
        if (candidate.id == item.id) latest = candidate;
      }
      if (latest == null) return message('This item is no longer available.');
      if (!mounted) return;
      setState(() {
        item = latest!;
        needsReload = false;
        fingerprint = null;
        idempotencyKey = null;
      });
      message('Latest stock loaded. Review before submitting again.');
    } catch (_) {
      message('Unable to reload the latest item. Try again.');
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  String failureMessage(
    WorkspaceInventoryStockFailure failure,
  ) => switch (failure) {
    WorkspaceInventoryStockFailure.stale =>
      'Stock changed elsewhere. Reload the latest item before trying again.',
    WorkspaceInventoryStockFailure.insufficientStock =>
      'Available stock has changed. Reload the latest item.',
    WorkspaceInventoryStockFailure.unauthenticated => 'Please log in again.',
    WorkspaceInventoryStockFailure.permissionDenied =>
      'You no longer have permission to adjust this item.',
    WorkspaceInventoryStockFailure.notFound =>
      'This item is no longer available.',
    WorkspaceInventoryStockFailure.invalidInput ||
    WorkspaceInventoryStockFailure.outOfRange =>
      'Review the entered quantity and try again.',
    WorkspaceInventoryStockFailure.conflict =>
      'This request conflicts with an earlier submission.',
    WorkspaceInventoryStockFailure.unavailable =>
      'Could not confirm the result. Retry unchanged to safely check again.',
    WorkspaceInventoryStockFailure.internal =>
      'Stock adjustment failed. Try again.',
  };

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = MediaQuery.sizeOf(context).width < 370 ? 16.0 : 20.0;
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 24),
              children: [
                _ItemSummary(item: item, stockOut: stockOut),
                if (needsReload) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('reload-latest-stock-item'),
                    onPressed: refreshing ? null : reload,
                    icon: refreshing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                    label: const Text('Reload Latest Item'),
                  ),
                ],
                const SizedBox(height: 24),
                const _Label('Quantity'),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('stock-quantity-field'),
                  controller: quantityController,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() => touched = true),
                  decoration: InputDecoration(
                    hintText: '0',
                    errorText: quantityError,
                    suffixText: item.unit,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  preview == null
                      ? 'Resulting stock: — ${item.unit}'
                      : 'Resulting stock: $preview ${item.unit}',
                  key: const ValueKey('stock-result-preview'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 20),
                const _Label('Reason (Optional)'),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('stock-reason-field'),
                  controller: reasonController,
                  minLines: 3,
                  maxLines: 4,
                  maxLength: 200,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'Add a short reason...',
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    key: const ValueKey('stock-confirm-button'),
                    onPressed: saving || needsReload || completed
                        ? null
                        : submit,
                    child: saving
                        ? const SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : Text('Confirm $title'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ItemSummary extends StatelessWidget {
  final InventoryItem item;
  final bool stockOut;
  const _ItemSummary({required this.item, required this.stockOut});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.name,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
        ),
        const SizedBox(height: 6),
        Text(
          '${stockOut ? 'Available' : 'Current stock'}: ${item.quantity} ${item.unit}',
        ),
        const SizedBox(height: 4),
        Text(
          'Version ${item.version}',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      ],
    ),
  );
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontWeight: FontWeight.w600));
}
