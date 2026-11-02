import '../../../models/inventory_item.dart';
import '../../../logic/inventory_expiry_policy.dart';

class LocalRestockFormatter {
  String format(List<InventoryItem> items) {
    final restockItems = items.where((item) {
      final daysLeft = _daysLeft(item.expiryDate);

      return item.quantity <= 2 || (daysLeft >= 0 && daysLeft <= 1);
    }).toList();

    restockItems.sort((a, b) {
      final quantityCompare = a.quantity.compareTo(b.quantity);

      if (quantityCompare != 0) return quantityCompare;

      return a.expiryDate.compareTo(b.expiryDate);
    });

    if (restockItems.isEmpty) {
      return '''
Smart Restock Advice

No urgent restock needed right now.

Your current inventory quantity looks stable. Keep monitoring low-stock and near-expiry ingredients to avoid cafe operation issues.
'''
          .trim();
    }

    final buffer = StringBuffer();

    buffer.writeln('Smart Restock Advice');
    buffer.writeln('');
    buffer.writeln(
      'Velora checked your cafe inventory and found items that may need restock soon.',
    );
    buffer.writeln('');

    for (final item in restockItems.take(5)) {
      final daysLeft = _daysLeft(item.expiryDate);
      final priority = _priorityText(item.quantity, daysLeft);
      final suggestion = _suggestionText(item.quantity, daysLeft);

      buffer.writeln('Ingredient: ${item.name}');
      buffer.writeln('Category: ${item.category}');
      buffer.writeln('Current Quantity: ${item.quantity}');
      buffer.writeln('Priority: $priority');
      buffer.writeln('Reason: ${_reasonText(item, daysLeft)}');
      buffer.writeln('Suggested Action: $suggestion');
      buffer.writeln('');
    }

    return buffer.toString().trim();
  }

  int _daysLeft(DateTime expiryDate) {
    return InventoryExpiryPolicy.daysUntil(expiryDate);
  }

  String _priorityText(int quantity, int daysLeft) {
    if (quantity <= 0) return 'Urgent';
    if (quantity <= 2) return 'High';
    if (daysLeft >= 0 && daysLeft <= 1) return 'High';

    return 'Medium';
  }

  String _reasonText(InventoryItem item, int daysLeft) {
    if (item.quantity <= 0) {
      return '${item.name} is already out of stock and may stop drink or food preparation.';
    }

    if (item.quantity <= 2) {
      return '${item.name} is running low with only ${item.quantity} left.';
    }

    if (daysLeft >= 0 && daysLeft <= 1) {
      return '${item.name} will expire very soon, so replacement stock should be prepared.';
    }

    return '${item.name} should be monitored because it may affect cafe preparation.';
  }

  String _suggestionText(int quantity, int daysLeft) {
    if (quantity <= 0) {
      return 'Restock immediately today.';
    }

    if (quantity <= 2) {
      return 'Restock within 1-2 days.';
    }

    if (daysLeft >= 0 && daysLeft <= 1) {
      return 'Prepare replacement stock before this ingredient expires.';
    }

    return 'Monitor this item and restock if usage increases.';
  }
}
