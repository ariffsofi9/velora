import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;
import '../../../services/android_pilot_policy.dart';
import '../../auth/workspace_gate.dart';
import '../../../services/workspace_session.dart';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../models/inventory_item.dart';
import '../../../services/workspace_inventory_https_transport.dart'
    show HttpsWorkspaceInventory, InventoryHttpsLifecycleException;
import '../../../services/workspace_inventory_lifecycle_service.dart';

class InventoryLifecycleActionButton extends StatefulWidget {
  final InventoryItem item;
  final WorkspaceSession? workspaceSession;
  final WorkspaceInventoryLifecycleManager? manager;
  final VoidCallback onChanged;
  final VoidCallback? onReload;

  const InventoryLifecycleActionButton({
    super.key,
    required this.item,
    required this.onChanged,
    this.onReload,
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
  bool _pending = false;
  bool _stale = false;
  bool _completed = false;
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
    final manager = widget.manager;
    if (manager == null ||
        _loading ||
        _confirming ||
        _pending ||
        _stale ||
        _completed) {
      return;
    }
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
      setState(() => _completed = true);
      _showMessage(archived ? 'Item restored.' : 'Item archived.');
      widget.onChanged();
    } on WorkspaceInventoryLifecycleException catch (error) {
      if (!mounted || !_current) return;
      final unknown =
          error is InventoryHttpsLifecycleException && error.outcomeUnknown;
      setState(() {
        _pending =
            unknown && manager is HttpsWorkspaceInventory && manager.isGuarded;
        _stale =
            !unknown &&
            error.failure == WorkspaceInventoryLifecycleFailure.stale;
      });
      if (_pending || _stale) return;
      final message = unknown
          ? 'The inventory change could not be confirmed. Check inventory before another submission.'
          : error is InventoryHttpsLifecycleException &&
                error.transport.code == 'resource-exhausted'
          ? 'The inventory service is busy. Try again later.'
          : switch (error.failure) {
              WorkspaceInventoryLifecycleFailure.permissionDenied =>
                'You no longer have permission to change this item.',
              WorkspaceInventoryLifecycleFailure.unauthenticated =>
                'Your session could not be verified. Please sign in again.',
              WorkspaceInventoryLifecycleFailure.notFound =>
                'This inventory item is no longer available.',
              WorkspaceInventoryLifecycleFailure.conflict =>
                'This request conflicts with an earlier action.',
              _ => 'Unable to update this item. Try again.',
            };
      _showMessage(message);
    } catch (_) {
      if (_current) _showMessage('Unable to update this item. Try again.');
    } finally {
      if (_current) setState(() => _loading = false);
    }
  }

  void _showMessage(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) => !_allowed
      ? const Text(
          'Inventory changes are unavailable under the Android pilot policy.',
        )
      : widget.manager == null
      ? const Text('Secure inventory updates are unavailable.')
      : _completed
      ? Text(widget.item.isArchived ? 'Item restored.' : 'Item archived.')
      : _pending
      ? const Text(
          'Confirmation pending. Return to Inventory and open Inventory recovery.',
        )
      : _stale
      ? Column(
          children: [
            const Text(
              'This item changed. Reload the list before trying again.',
            ),
            if (widget.onReload case final reload?)
              TextButton(
                onPressed: _current ? reload : null,
                child: const Text('Reload Inventory List'),
              ),
          ],
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
