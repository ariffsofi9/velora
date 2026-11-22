import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;
import '../../../services/android_pilot_policy.dart';
import '../../auth/workspace_gate.dart';
import '../../../core/theme/app_tokens.dart';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../services/workspace_inventory_create_service.dart';
import '../../../services/workspace_inventory_https_transport.dart'
    show InventoryHttpsCreateException;
import '../../../services/workspace_session.dart';

import 'widgets_add/add_item_date_box.dart';
import 'widgets_add/add_item_dropdown.dart';
import 'widgets_add/add_item_header.dart';
import 'widgets_add/add_item_save_button.dart';
import 'widgets_add/add_item_text_field.dart';

class AddItemPage extends StatefulWidget {
  final WorkspaceSession? workspaceSession;
  final WorkspaceInventoryCreator? creator;
  final String Function()? idempotencyKeyFactory;

  const AddItemPage({
    super.key,
    this.workspaceSession,
    this.creator,
    this.idempotencyKeyFactory,
  });

  @override
  State<AddItemPage> createState() => _AddItemPageState();
}

class _AddItemPageState extends State<AddItemPage> {
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
  void didUpdateWidget(covariant AddItemPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspaceSession, widget.workspaceSession) ||
        !identical(oldWidget.creator, widget.creator)) {
      _policyBlocked = true;
    }
  }

  final itemNameController = TextEditingController();
  final quantityController = TextEditingController();

  String selectedCategory = 'Meat';
  String selectedUnit = 'kg';
  DateTime? selectedDate;
  bool isSaving = false;
  String? _submissionFingerprint;
  String? _idempotencyKey;

  final categories = ['Meat', 'Dairy', 'Vegetable', 'Fruit', 'Bakery', 'Other'];
  final units = ['kg', 'g', 'L', 'ml', 'pcs'];

  bool get _hasVerifiedWorkspace => widget.workspaceSession != null;

  @override
  void initState() {
    super.initState();
    _boundPolicy = _policy;
  }

  @override
  void dispose() {
    itemNameController.dispose();
    quantityController.dispose();
    super.dispose();
  }

  Future<void> _pickExpiryDate() async {
    if (!mounted || !_current) return;
    final pickedDate = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime(2035),
      initialDate: DateTime.now(),
    );

    if (pickedDate != null && _current) {
      setState(() => selectedDate = pickedDate);
    }
  }

  Future<void> _saveItem() async {
    if (!mounted || !_current) return;
    if (!_hasVerifiedWorkspace) {
      _showMessage(
        'Adding items requires a verified workspace. Please sign in again.',
      );
      return;
    }
    if (isSaving) return;
    final creator = widget.creator;
    if (creator == null) {
      _showMessage('Secure inventory updates are unavailable.');
      return;
    }

    final quantityText = quantityController.text.trim();
    final quantity = int.tryParse(quantityText);
    if (itemNameController.text.trim().isEmpty ||
        quantityText.isEmpty ||
        selectedDate == null) {
      _showMessage('Please fill item name, quantity and expiry date');
      return;
    }
    if (quantity == null || quantity < 0) {
      _showMessage('Quantity must be a whole number of zero or more.');
      return;
    }

    final requestWithoutKey = WorkspaceInventoryCreateRequest(
      idempotencyKey: 'pending-idempotency-key',
      name: itemNameController.text.trim(),
      category: selectedCategory,
      quantity: quantity,
      unit: selectedUnit,
      expiryDate: selectedDate!,
    );
    final fingerprint = requestWithoutKey.fingerprint;
    if (_submissionFingerprint != fingerprint || _idempotencyKey == null) {
      _submissionFingerprint = fingerprint;
      _idempotencyKey =
          widget.idempotencyKeyFactory?.call() ?? _newIdempotencyKey();
    }
    final request = WorkspaceInventoryCreateRequest(
      idempotencyKey: _idempotencyKey!,
      name: requestWithoutKey.name,
      category: requestWithoutKey.category,
      quantity: requestWithoutKey.quantity,
      unit: requestWithoutKey.unit,
      expiryDate: requestWithoutKey.expiryDate,
    );

    setState(() => isSaving = true);
    try {
      await creator.createItem(request);
      if (!mounted || !_current) return;
      setState(() => isSaving = false);
      _showMessage('${request.name} added successfully');
      Navigator.pop(context, true);
    } on WorkspaceInventoryCreateException catch (error) {
      if (!mounted || !_current) return;
      setState(() => isSaving = false);
      _showMessage(
        error is InventoryHttpsCreateException && error.outcomeUnknown
            ? 'Item creation could not be confirmed. Check your connection and inventory before another submission.'
            : _failureMessage(error.failure),
      );
    } catch (_) {
      if (!mounted || !_current) return;
      setState(() => isSaving = false);
      _showMessage('Unable to add the item. Check your connection and retry.');
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
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final encoded = bytes.map(
      (value) => value.toRadixString(16).padLeft(2, '0'),
    );
    return encoded.join();
  }

  String _failureMessage(
    WorkspaceInventoryCreateFailure failure,
  ) => switch (failure) {
    WorkspaceInventoryCreateFailure.invalidInput =>
      'Check the item details and try again.',
    WorkspaceInventoryCreateFailure.unauthenticated ||
    WorkspaceInventoryCreateFailure.permissionDenied =>
      'Your workspace access could not be verified. Please sign in again.',
    WorkspaceInventoryCreateFailure.conflict =>
      'This request conflicts with an earlier submission. Change the item and retry.',
    WorkspaceInventoryCreateFailure.unavailable =>
      'Unable to reach inventory services. Check your connection and retry.',
    WorkspaceInventoryCreateFailure.internal =>
      'Unable to add the item right now. Please retry.',
  };

  String get expiryText {
    if (selectedDate == null) return 'Select date';
    return '${selectedDate!.day}/${selectedDate!.month}/${selectedDate!.year}';
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed) return const PilotAccessBlockedPage();
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.symmetric(
            horizontal: ((MediaQuery.sizeOf(context).width - 640) / 2).clamp(
              20.0,
              double.infinity,
            ),
            vertical: 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AddItemHeader(),
              const SizedBox(height: 20),
              const AddItemTextFieldLabel(text: 'Item Name'),
              AddItemTextField(
                controller: itemNameController,
                hint: 'e.g. Chicken Breast',
              ),
              const SizedBox(height: 16),
              const AddItemTextFieldLabel(text: 'Category'),
              AddItemDropdown(
                value: selectedCategory,
                items: categories,
                onChanged: (value) {
                  if (!mounted || !_current) return;
                  setState(() => selectedCategory = value!);
                },
              ),
              const SizedBox(height: 16),
              const AddItemTextFieldLabel(text: 'Quantity'),
              Row(
                children: [
                  Expanded(
                    child: AddItemTextField(
                      controller: quantityController,
                      hint: '0',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 90,
                    child: AddItemDropdown(
                      value: selectedUnit,
                      items: units,
                      onChanged: (value) {
                        if (!mounted || !_current) return;
                        setState(() => selectedUnit = value!);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const AddItemTextFieldLabel(text: 'Expiry Date'),
              AddItemDateBox(
                expiryText: expiryText,
                selectedDate: selectedDate,
                onTap: _pickExpiryDate,
              ),
              const SizedBox(height: 24),
              AddItemSaveButton(isSaving: isSaving, onTap: _saveItem),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
