import '../../../services/workspace_session.dart';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../models/inventory_item.dart';
import '../../../services/workspace_inventory_lifecycle_service.dart';

class InventoryLifecycleActionButton extends StatefulWidget {
  final InventoryItem item;
  final WorkspaceSession? workspaceSession;
  final WorkspaceInventoryLifecycleManager? manager;
  final VoidCallback onChanged;

  const InventoryLifecycleActionButton({
    super.key,
    required this.item,
    required this.onChanged,
    this.manager,
    this.workspaceSession,
  });

  @override
  State<InventoryLifecycleActionButton> createState() =>
      _InventoryLifecycleActionButtonState();
}

class _InventoryLifecycleActionButtonState
    extends State<InventoryLifecycleActionButton> {
  bool _loading = false;
  String? _key;

  String _newKey() {
    final random = Random.secure();
    return List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> _submit() async {
    if (_loading) return;
    final archived = widget.item.isArchived;
    final action = archived
        ? InventoryLifecycleAction.restore
        : InventoryLifecycleAction.archive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(archived ? 'Restore item?' : 'Archive item?'),
        content: Text(
          archived
              ? 'This item will return to active inventory with its stock unchanged.'
              : 'This item will leave active inventory. Stock and history will be preserved.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('lifecycle-cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('lifecycle-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(archived ? 'Restore' : 'Archive'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _loading = true);
    try {
      final manager =
          widget.manager ??
          FirebaseWorkspaceInventoryLifecycleManager(
            session: widget.workspaceSession,
          );
      _key ??= _newKey();
      await manager.setLifecycle(
        WorkspaceInventoryLifecycleRequest(
          idempotencyKey: _key!,
          itemId: widget.item.id,
          action: action,
          expectedVersion: widget.item.version,
        ),
      );
      if (!mounted) return;
      widget.onChanged();
    } on WorkspaceInventoryLifecycleException catch (error) {
      if (!mounted) return;
      final message = switch (error.failure) {
        WorkspaceInventoryLifecycleFailure.stale =>
          'This item changed. Return to the list and try again.',
        WorkspaceInventoryLifecycleFailure.permissionDenied ||
        WorkspaceInventoryLifecycleFailure.unauthenticated =>
          'You no longer have permission to change this item.',
        WorkspaceInventoryLifecycleFailure.notFound =>
          'This inventory item is no longer available.',
        WorkspaceInventoryLifecycleFailure.conflict =>
          'This request conflicts with an earlier action.',
        _ => 'Unable to update this item. Try again.',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: ValueKey(widget.item.isArchived ? 'restore-item' : 'archive-item'),
    onPressed: _loading ? null : _submit,
    icon: _loading
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(
            widget.item.isArchived
                ? Icons.unarchive_outlined
                : Icons.archive_outlined,
          ),
    label: Text(widget.item.isArchived ? 'Restore Item' : 'Archive Item'),
  );
}
