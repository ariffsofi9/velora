import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;
import '../../services/android_pilot_policy.dart';
import '../auth/workspace_gate.dart';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../models/inventory_item.dart';
import '../../repositories/workspace_inventory_repository.dart';
import '../../services/workspace_inventory_https_transport.dart'
    show HttpsWorkspaceInventory, InventoryHttpsUpdateException;
import '../../services/workspace_inventory_update_service.dart';
import '../../services/workspace_session.dart';

class EditItemPage extends StatefulWidget {
  final InventoryItem item;
  final WorkspaceSession? workspaceSession;
  final WorkspaceInventoryUpdater? updater;
  final WorkspaceInventoryRepository? repository;
  final String Function()? idempotencyKeyFactory;

  const EditItemPage({
    super.key,
    required this.item,
    this.workspaceSession,
    this.updater,
    this.repository,
    this.idempotencyKeyFactory,
  });

  @override
  State<EditItemPage> createState() => _EditItemPageState();
}

class _EditItemPageState extends State<EditItemPage> {
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
  void didUpdateWidget(covariant EditItemPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspaceSession, widget.workspaceSession) ||
        !identical(oldWidget.updater, widget.updater) ||
        !identical(oldWidget.repository, widget.repository) ||
        !identical(oldWidget.item, widget.item)) {
      _policyBlocked = true;
    }
  }

  static const _units = ['kg', 'g', 'L', 'ml', 'pcs'];

  late final TextEditingController _nameController;
  late final TextEditingController _categoryController;
  late final TextEditingController _imageUrlController;
  WorkspaceInventoryRepository? _repository;
  late InventoryItem _item;
  late String _unit;
  late DateTime _expiryDate;
  bool _isSaving = false;
  bool _isRefreshing = false;
  bool _hasConflict = false;
  bool _confirmationPending = false;
  bool get _editable =>
      !_isSaving && !_isRefreshing && !_hasConflict && !_confirmationPending;
  String? _submissionFingerprint;
  String? _idempotencyKey;

  bool get _hasVerifiedContext =>
      widget.workspaceSession != null && _item.id.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _boundPolicy = _policy;
    _item = widget.item;
    _nameController = TextEditingController();
    _categoryController = TextEditingController();
    _imageUrlController = TextEditingController();
    _repository = widget.repository;
    _loadForm(_item);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _categoryController.dispose();
    _imageUrlController.dispose();
    super.dispose();
  }

  void _loadForm(InventoryItem item) {
    _item = item;
    _nameController.text = item.name;
    _categoryController.text = item.category;
    _imageUrlController.text = item.imageUrl;
    _unit = item.unit;
    _expiryDate = item.expiryDate;
    _submissionFingerprint = null;
    _idempotencyKey = null;
  }

  Future<void> _pickExpiryDate() async {
    if (!_current || !_editable) return;
    final first = DateTime(2020);
    final last = DateTime(2035);
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _expiryDate,
      firstDate: _expiryDate.isBefore(first) ? _expiryDate : first,
      lastDate: _expiryDate.isAfter(last) ? _expiryDate : last,
    );
    if (pickedDate != null && _current && _editable) {
      setState(() => _expiryDate = pickedDate);
    }
  }

  Future<void> _saveItem() async {
    if (!_current || !_editable) return;
    if (!_hasVerifiedContext) {
      _showMessage('Editing requires a verified workspace and inventory item.');
      return;
    }
    final updater = widget.updater;
    if (updater == null) {
      _showMessage('Secure inventory updates are unavailable.');
      return;
    }

    final whitespace = RegExp(r'\s+');
    final controls = RegExp(r'[\x00-\x1f\x7f-\x9f]');
    final name = _nameController.text.trim().replaceAll(whitespace, ' ');
    final category = _categoryController.text.trim().replaceAll(
      whitespace,
      ' ',
    );
    final imageUrl = _imageUrlController.text.trim().replaceAll(
      whitespace,
      ' ',
    );
    if (name.isEmpty || category.isEmpty) {
      _showMessage('Item name and category are required.');
      return;
    }
    if (name.length > 100 ||
        category.length > 60 ||
        controls.hasMatch(name) ||
        controls.hasMatch(category)) {
      _showMessage(
        'Use a valid item name of up to 100 characters and a category of up to 60 characters.',
      );
      return;
    }
    if (!_units.contains(_unit)) {
      _showMessage('Select a supported inventory unit.');
      return;
    }
    if (imageUrl.isNotEmpty) {
      final uri = Uri.tryParse(imageUrl);
      if (imageUrl.length > 2048 ||
          controls.hasMatch(imageUrl) ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        _showMessage('Image URL must be empty or use HTTPS.');
        return;
      }
    }

    FocusScope.of(context).unfocus();
    setState(() => _isSaving = true);
    try {
      final draft = WorkspaceInventoryUpdateRequest(
        idempotencyKey: 'pending-idempotency-key',
        itemId: _item.id,
        expectedVersion: _item.version,
        name: name,
        category: category,
        unit: _unit,
        expiryDate: _expiryDate,
        imageUrl: imageUrl,
      );
      if (_submissionFingerprint != draft.fingerprint ||
          _idempotencyKey == null) {
        _submissionFingerprint = draft.fingerprint;
        _idempotencyKey =
            widget.idempotencyKeyFactory?.call() ?? _newIdempotencyKey();
      }
      final request = WorkspaceInventoryUpdateRequest(
        idempotencyKey: _idempotencyKey!,
        itemId: draft.itemId,
        expectedVersion: draft.expectedVersion,
        name: draft.name,
        category: draft.category,
        unit: draft.unit,
        expiryDate: draft.expiryDate,
        imageUrl: draft.imageUrl,
      );

      final result = await updater.updateItem(request);
      if (!mounted || !_current) return;
      setState(() => _isSaving = false);
      _showMessage(
        result.updated
            ? 'Item updated successfully'
            : 'No changes were needed.',
      );
      Navigator.pop(context, true);
    } on WorkspaceInventoryUpdateException catch (error) {
      if (!mounted || !_current) return;
      final outcomeUnknown =
          error is InventoryHttpsUpdateException && error.outcomeUnknown;
      setState(() {
        _isSaving = false;
        _confirmationPending =
            outcomeUnknown &&
            updater is HttpsWorkspaceInventory &&
            updater.isGuarded;
        _hasConflict =
            !outcomeUnknown &&
            error.failure == WorkspaceInventoryUpdateFailure.stale;
      });
      if (_confirmationPending) return;
      _showMessage(
        outcomeUnknown
            ? 'The item update could not be confirmed. Check inventory before another submission.'
            : error is InventoryHttpsUpdateException &&
                  error.transport.code == 'resource-exhausted'
            ? 'The inventory service is busy. Try again later.'
            : _failureMessage(error.failure),
      );
    } catch (_) {
      if (!mounted || !_current) return;
      setState(() => _isSaving = false);
      _showMessage(
        'Unable to update the item. Check your connection and retry.',
      );
    }
  }

  Future<void> _reloadItem() async {
    if (!_current || !_hasConflict || _isRefreshing) return;
    final repository =
        _repository ??
        (widget.workspaceSession == null
            ? null
            : WorkspaceInventoryRepository(session: widget.workspaceSession!));
    if (repository == null ||
        !identical(repository.session, widget.workspaceSession)) {
      return;
    }
    setState(() => _isRefreshing = true);
    try {
      final items = await repository.getItems();
      InventoryItem? refreshed;
      for (final item in items) {
        if (item.id == _item.id) {
          refreshed = item;
          break;
        }
      }
      if (!mounted || !_current) return;
      if (refreshed == null) {
        _showMessage('This inventory item no longer exists.');
        return;
      }
      setState(() {
        _loadForm(refreshed!);
        _hasConflict = false;
      });
    } catch (_) {
      if (_current) _showMessage('Unable to reload this inventory item.');
    } finally {
      if (_current) setState(() => _isRefreshing = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted || !_current) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  String _newIdempotencyKey() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  String _failureMessage(
    WorkspaceInventoryUpdateFailure failure,
  ) => switch (failure) {
    WorkspaceInventoryUpdateFailure.invalidInput =>
      'Check the item details and try again.',
    WorkspaceInventoryUpdateFailure.permissionDenied =>
      'You do not have permission to edit this item.',
    WorkspaceInventoryUpdateFailure.unauthenticated =>
      'Your workspace access could not be verified. Please sign in again.',
    WorkspaceInventoryUpdateFailure.notFound =>
      'This inventory item no longer exists.',
    WorkspaceInventoryUpdateFailure.conflict =>
      'This request conflicts with an earlier submission.',
    WorkspaceInventoryUpdateFailure.stale =>
      'This item changed elsewhere. Reload the latest item before editing again.',
    WorkspaceInventoryUpdateFailure.unavailable =>
      'Unable to reach inventory services. Check your connection and retry.',
    WorkspaceInventoryUpdateFailure.internal =>
      'Unable to update the item right now. Please retry.',
  };

  String _formatDate(DateTime date) => '${date.day}/${date.month}/${date.year}';

  @override
  Widget build(BuildContext context) {
    if (!_allowed) return const PilotAccessBlockedPage();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        centerTitle: true,
        title: const Text('Edit Item'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: ((MediaQuery.sizeOf(context).width - 640) / 2).clamp(
              20.0,
              double.infinity,
            ),
            vertical: 24,
          ),
          child: Column(
            children: [
              const Text(
                'Quantity is read-only. Use Stock In or Stock Out when secure stock adjustments are enabled.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary),
              ),
              if (_confirmationPending) ...[
                const SizedBox(height: 16),
                const Text(
                  'Confirmation pending. Return to Inventory and open Inventory recovery.',
                ),
              ],
              if (_hasConflict) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7ED),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        'This item changed elsewhere. Your edits were not saved.',
                        textAlign: TextAlign.center,
                      ),
                      TextButton.icon(
                        key: const ValueKey('reload-latest-item'),
                        onPressed: _isRefreshing ? null : _reloadItem,
                        icon: _isRefreshing
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded),
                        label: const Text('Reload Latest Item'),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 18),
              _formCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _formCard() => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      children: [
        _textField('Item Name', _nameController, Icons.inventory_2_outlined),
        const SizedBox(height: 14),
        _textField('Category', _categoryController, Icons.category_outlined),
        const SizedBox(height: 14),
        TextFormField(
          key: ValueKey(
            'edit-quantity-${_item.version}-${_item.quantity}-${_item.unit}',
          ),
          initialValue: '${_item.quantity} ${_item.unit}',
          readOnly: true,
          decoration: const InputDecoration(
            labelText: 'Current Quantity (read-only)',
            prefixIcon: Icon(Icons.numbers_outlined),
          ),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          key: ValueKey('edit-unit-${_item.version}-$_unit'),
          initialValue: _unit,
          decoration: const InputDecoration(
            labelText: 'Unit',
            prefixIcon: Icon(Icons.straighten_rounded),
          ),
          items: _units
              .map((unit) => DropdownMenuItem(value: unit, child: Text(unit)))
              .toList(),
          onChanged: _editable
              ? (value) {
                  if (!_current || !_editable || value == null) return;
                  setState(() => _unit = value);
                }
              : null,
        ),
        const SizedBox(height: 14),
        _datePicker(),
        const SizedBox(height: 14),
        _textField(
          'Image URL (optional)',
          _imageUrlController,
          Icons.image_outlined,
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _editable ? _saveItem : null,
            child: _isSaving
                ? const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Text('Save Changes'),
          ),
        ),
      ],
    ),
  );

  Widget _textField(
    String label,
    TextEditingController controller,
    IconData icon,
  ) => TextField(
    controller: controller,
    enabled: _editable,
    decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
  );

  Widget _datePicker() => InkWell(
    key: const ValueKey('edit-expiry-date'),
    onTap: _editable ? _pickExpiryDate : null,
    borderRadius: BorderRadius.circular(18),
    child: InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Expiry Date',
        prefixIcon: Icon(Icons.calendar_month_outlined),
      ),
      child: Text(
        _formatDate(_expiryDate),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
  );
}
