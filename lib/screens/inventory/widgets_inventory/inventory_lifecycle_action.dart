import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;
import '../../../services/android_pilot_policy.dart';
import '../../auth/workspace_gate.dart';
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
  late final _buildPolicy = AndroidPilotPolicy.fromBuildConfiguration(
    isWeb: kIsWeb,
    platform: defaultTargetPlatform,
    androidFlavor: appFlavor,
  );
  AndroidPilotPolicy get _policy =>
      AndroidPilotAuthScope.read(context)?.policy ?? _buildPolicy;
  AndroidPilotPolicy? _boundPolicy;
  bool _policyBlocked = false;
  bool get _allowed =>
      !_policyBlocked &&
      widget.workspaceSession?.isActive != false &&
      (_policy.state == AndroidPilotState.normal ||
          _policy.permits(AndroidPilotCapability.inventoryMutations));
  bool get _current => mounted && _allowed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.dependOnInheritedWidgetOfExactType<AndroidPilotAuthScope>();
    if (!identical(_boundPolicy, _policy)) _policyBlocked = true;
  }

  @override
  void didUpdateWidget(covariant InventoryLifecycleActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspaceSession, widget.workspaceSession) ||
        !identical(oldWidget.manager, widget.manager) ||
        !identical(oldWidget.item, widget.item)) {
      _policyBlocked = true;
    }
  }

  @override
  void initState() {
    super.initState();
    _boundPolicy = _policy;
  }

  bool _loading = false;
  bool _confirming = false;
  String? _key;

  String _newKey() {
    final random = Random.secure();
    return List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> _submit() async {
    if (!mounted || !_current) return;
    if (_loading || _confirming) return;
    _confirming = true;
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
    _confirming = false;
    if (confirmed != true || !_current) return;
    setState(() => _loading = true);
    try {
      final manager =
          widget.manager ??
          FirebaseWorkspaceInventoryLifecycleManager(
            pilotPolicy: _policy,
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
      if (!mounted || !_current) return;
      widget.onChanged();
    } on WorkspaceInventoryLifecycleException catch (error) {
      if (!mounted || !_current) return;
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
      if (_current) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => !_allowed
      ? const Text(
          'Inventory changes are unavailable under the Android pilot policy.',
        )
      : OutlinedButton.icon(
          key: ValueKey(
            widget.item.isArchived ? 'restore-item' : 'archive-item',
          ),
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
