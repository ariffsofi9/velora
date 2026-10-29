import '../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

class HeaderCard extends StatelessWidget {
  final int totalItems;
  final int nearExpiry;

  const HeaderCard({
    super.key,
    required this.totalItems,
    required this.nearExpiry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: .03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 34),
          SizedBox(height: 14),
          Text(
            'Let AI help you today!',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Get recipe ideas and restock recommendations.',
            style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
          ),
          SizedBox(height: 18),
        ],
      ),
    );
  }
}
