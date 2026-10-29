import '../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

import '../../logic/firestore_service.dart';

class TodayOverviewSection extends StatelessWidget {
  const TodayOverviewSection({super.key});

  static const Color textDark = AppColors.textPrimary;
  static const Color textGrey = AppColors.textSecondary;
  static const Color borderGrey = AppColors.border;
  static const Color green = Color(0xFF10B981);
  static const Color orange = Color(0xFFF97316);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, int>>(
      stream: FirestoreService.instance.getTodayOverviewStream(),
      builder: (context, snapshot) {
        final data = snapshot.data ?? {'stock_in': 0, 'stock_out': 0};

        return Row(
          children: [
            Expanded(
              child: _todayCard(
                title: 'Stock In',
                value: '${data['stock_in'] ?? 0}',
                subtitle: 'Today added',
                icon: Icons.arrow_downward_rounded,
                iconColor: green,
                iconBgColor: const Color(0xFFE7FFF4),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _todayCard(
                title: 'Stock Out',
                value: '${data['stock_out'] ?? 0}',
                subtitle: 'Today used',
                icon: Icons.arrow_upward_rounded,
                iconColor: orange,
                iconBgColor: const Color(0xFFFFF1E8),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _todayCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required Color iconBgColor,
  }) {
    return Container(
      height: 92,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderGrey),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 14,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            height: 38,
            width: 38,
            decoration: BoxDecoration(
              color: iconBgColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: textGrey,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    value,
                    style: const TextStyle(
                      color: textDark,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: iconColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
