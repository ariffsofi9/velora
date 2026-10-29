import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../models/inventory_item.dart';

enum StockAdjustmentType { stockIn, stockOut }

class StockInPage extends StatelessWidget {
  final InventoryItem item;

  const StockInPage({super.key, required this.item});

  @override
  Widget build(BuildContext context) =>
      StockAdjustmentPage(item: item, type: StockAdjustmentType.stockIn);
}

class StockOutPage extends StatelessWidget {
  final InventoryItem item;

  const StockOutPage({super.key, required this.item});

  @override
  Widget build(BuildContext context) =>
      StockAdjustmentPage(item: item, type: StockAdjustmentType.stockOut);
}

class StockAdjustmentPage extends StatefulWidget {
  final InventoryItem item;
  final StockAdjustmentType type;

  const StockAdjustmentPage({
    super.key,
    required this.item,
    required this.type,
  });

  @override
  State<StockAdjustmentPage> createState() => _StockAdjustmentPageState();
}

class _StockAdjustmentPageState extends State<StockAdjustmentPage> {
  final _quantityController = TextEditingController();
  final _notesController = TextEditingController();
  bool _quantityTouched = false;

  bool get _isStockOut => widget.type == StockAdjustmentType.stockOut;
  String get _title => _isStockOut ? 'Stock Out' : 'Stock In';
  String get _buttonLabel =>
      _isStockOut ? 'Confirm Stock Out' : 'Confirm Stock In';

  String? get _quantityError {
    if (!_quantityTouched) return null;
    final value = int.tryParse(_quantityController.text.trim());
    if (value == null || value <= 0) return 'Enter a whole number above 0.';
    if (_isStockOut && value > widget.item.quantity) {
      return 'Quantity cannot exceed available stock.';
    }
    return null;
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  IconData _categoryIcon() {
    final category = widget.item.category.toLowerCase();
    if (category.contains('dairy')) return Icons.local_drink_outlined;
    if (category.contains('vegetable')) return Icons.eco_outlined;
    if (category.contains('fruit')) return Icons.apple_outlined;
    if (category.contains('meat')) return Icons.restaurant_outlined;
    return Icons.inventory_2_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = MediaQuery.sizeOf(context).width < 370 ? 16.0 : 20.0;
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: Text(
          _title,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
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
                _ItemSummary(
                  item: widget.item,
                  icon: _categoryIcon(),
                  isStockOut: _isStockOut,
                ),
                const SizedBox(height: 24),
                const _FieldLabel('Quantity'),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('stock-quantity-field'),
                  controller: _quantityController,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() => _quantityTouched = true),
                  decoration: InputDecoration(
                    hintText: '0',
                    errorText: _quantityError,
                    suffixIcon: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14),
                      child: Center(
                        widthFactor: 1,
                        child: Text(
                          'Unit unavailable',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const _FieldLabel('Notes (Optional)'),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('stock-notes-field'),
                  controller: _notesController,
                  minLines: 3,
                  maxLines: 4,
                  maxLength: 240,
                  decoration: const InputDecoration(
                    hintText: 'Add a short note...',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 12),
                const _ProvisioningNotice(),
                const SizedBox(height: 20),
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    key: const ValueKey('stock-confirm-button'),
                    onPressed: null,
                    child: Text(_buttonLabel),
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
  final IconData icon;
  final bool isStockOut;

  const _ItemSummary({
    required this.item,
    required this.icon,
    required this.isStockOut,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: Row(
      children: [
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: AppColors.nude,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: AppColors.primary, size: 28),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                item.category,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${isStockOut ? 'Available' : 'Current stock'}: ${item.quantity}',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _FieldLabel extends StatelessWidget {
  final String text;

  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: AppColors.textPrimary,
      fontWeight: FontWeight.w600,
    ),
  );
}

class _ProvisioningNotice extends StatelessWidget {
  const _ProvisioningNotice();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.nude.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.border),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, color: AppColors.primary, size: 20),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'Stock confirmation is unavailable until an atomic, authorized transaction service is connected.',
            style: TextStyle(
              color: AppColors.textSecondary,
              height: 1.4,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ],
    ),
  );
}
