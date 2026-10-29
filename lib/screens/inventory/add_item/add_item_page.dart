import '../../../core/theme/app_tokens.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../logic/firestore_service.dart';
import '../../../models/inventory_item.dart';
import '../../../services/activity_service.dart';

import 'widgets_add/add_item_date_box.dart';
import 'widgets_add/add_item_dropdown.dart';
import 'widgets_add/add_item_header.dart';
import 'widgets_add/add_item_image_box.dart';
import 'widgets_add/add_item_save_button.dart';
import 'widgets_add/add_item_text_field.dart';

class AddItemPage extends StatefulWidget {
  const AddItemPage({super.key});

  @override
  State<AddItemPage> createState() => _AddItemPageState();
}

class _AddItemPageState extends State<AddItemPage> {
  final itemNameController = TextEditingController();
  final quantityController = TextEditingController();
  final priceController = TextEditingController();

  String selectedCategory = 'Meat';
  String selectedUnit = 'kg';
  DateTime? selectedDate;
  bool isSaving = false;
  File? selectedImage;

  final picker = ImagePicker();

  final categories = ['Meat', 'Dairy', 'Vegetable', 'Fruit', 'Bakery', 'Other'];
  final units = ['kg', 'g', 'L', 'ml', 'pcs'];

  @override
  void dispose() {
    itemNameController.dispose();
    quantityController.dispose();
    priceController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
    );

    if (picked != null) {
      setState(() => selectedImage = File(picked.path));
    }
  }

  Future<void> _pickExpiryDate() async {
    final pickedDate = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime(2035),
      initialDate: DateTime.now(),
    );

    if (pickedDate != null) {
      setState(() => selectedDate = pickedDate);
    }
  }

  Future<void> _saveItem() async {
    if (itemNameController.text.trim().isEmpty ||
        quantityController.text.trim().isEmpty ||
        selectedDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please fill item name, quantity and expiry date'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => isSaving = true);

    final itemName = itemNameController.text.trim();

    final newItem = InventoryItem(
      id: '',
      name: itemName,
      category: selectedCategory,
      quantity: int.tryParse(quantityController.text.trim()) ?? 0,
      expiryDate: selectedDate!,
      imageUrl: selectedImage?.path ?? '',
      createdAt: DateTime.now(),
    );

    await FirestoreService.instance.addItem(newItem);

    await ActivityService.addActivity(
      type: 'stock_in',
      title: 'Added $itemName',
      subtitle: 'New item added to inventory',
    );

    if (!mounted) return;

    setState(() => isSaving = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$itemName added successfully'),
        behavior: SnackBarBehavior.floating,
      ),
    );

    Navigator.pop(context);
  }

  String get expiryText {
    if (selectedDate == null) return 'Select date';
    return '${selectedDate!.day}/${selectedDate!.month}/${selectedDate!.year}';
  }

  @override
  Widget build(BuildContext context) {
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
              const SizedBox(height: 16),
              AddItemImageBox(selectedImage: selectedImage, onTap: _pickImage),
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
              const SizedBox(height: 16),
              const AddItemTextFieldLabel(text: 'Purchase Price (RM)'),
              AddItemTextField(
                controller: priceController,
                hint: '0.00',
                keyboardType: TextInputType.number,
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
