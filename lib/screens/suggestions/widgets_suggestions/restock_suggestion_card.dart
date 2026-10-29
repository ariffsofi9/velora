import '../../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

import '../restock_suggestion_service.dart';

class RestockSuggestionCard extends StatelessWidget {
  final RestockSuggestion suggestion;

  const RestockSuggestionCard({super.key, required this.suggestion});

  Color get color {
    if (suggestion.priority == 1) {
      return const Color(0xFFEF4444);
    }

    if (suggestion.priority == 2) {
      return const Color(0xFFF59E0B);
    }

    return const Color(0xFF10B981);
  }

  IconData get icon {
    if (suggestion.priority == 1) {
      return Icons.warning_rounded;
    }

    if (suggestion.priority == 2) {
      return Icons.priority_high_rounded;
    }

    return Icons.shopping_cart_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withAlpha(45)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 16,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: color.withAlpha(22),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TopRow(suggestion: suggestion, color: color),
                const SizedBox(height: 6),
                Text(
                  suggestion.reason,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  suggestion.suggestion,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _InfoChip(
                      icon: Icons.inventory_2_rounded,
                      text: 'Qty ${suggestion.quantity}',
                    ),
                    _InfoChip(
                      icon: Icons.category_rounded,
                      text: suggestion.category,
                    ),
                    if (suggestion.daysLeft != null)
                      _InfoChip(
                        icon: Icons.event_rounded,
                        text: _daysText(suggestion.daysLeft!),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _daysText(int days) {
    if (days < 0) return 'Expired';
    if (days == 0) return 'Expires today';
    if (days == 1) return '1 day left';

    return '$days days left';
  }
}

class _TopRow extends StatelessWidget {
  final RestockSuggestion suggestion;
  final Color color;

  const _TopRow({required this.suggestion, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            suggestion.itemName,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withAlpha(18),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            suggestion.priorityLabel,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.textSecondary),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
