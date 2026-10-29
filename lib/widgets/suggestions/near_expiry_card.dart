import '../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';
import '../../models/inventory_item.dart';

class NearExpiryCard extends StatelessWidget {
  final InventoryItem item;
  final String daysLeft;

  const NearExpiryCard({super.key, required this.item, required this.daysLeft});

  int _daysNumber() {
    final days = item.expiryDate.difference(DateTime.now()).inDays;
    return days < 0 ? 0 : days;
  }

  Color _statusColor(int days) {
    if (days <= 1) return const Color(0xFFEF4444);
    if (days <= 4) return const Color(0xFFF97316);
    return const Color(0xFF10B981);
  }

  Color _statusBgColor(int days) {
    if (days <= 1) return const Color(0xFFFEE2E2);
    if (days <= 4) return const Color(0xFFFFEDD5);
    return const Color(0xFFD1FAE5);
  }

  String _statusText(int days) {
    if (days <= 1) return 'Expiring Soon';
    if (days <= 4) return 'Use Soon';
    return 'Good';
  }

  double _progressValue(int days) {
    final value = 1 - (days / 7);
    return value.clamp(0.1, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final days = _daysNumber();
    final color = _statusColor(days);
    final bgColor = _statusBgColor(days);
    final progress = _progressValue(days);

    return Container(
      width: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          /// TOP ROW
          Row(
            children: [
              const Icon(Icons.access_time, size: 18, color: Colors.orange),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  item.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              Text(
                '$days d',
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
            ],
          ),

          const SizedBox(height: 6),

          Text(
            item.category,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),

          Text(
            'Qty: ${item.quantity}',
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),

          const SizedBox(height: 8),

          /// STATUS CHIP
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _statusText(days),
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),

          const SizedBox(height: 10),

          /// PROGRESS BAR
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: AppColors.border,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ],
      ),
    );
  }
}
