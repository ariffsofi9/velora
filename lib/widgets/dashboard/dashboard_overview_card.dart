import '../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

class DashboardOverviewCard extends StatelessWidget {
  final int totalItems;
  final int nearExpiry;
  final int lowStock;

  const DashboardOverviewCard({
    super.key,
    required this.totalItems,
    required this.nearExpiry,
    required this.lowStock,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 174,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: AppColors.primary,
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.24),
            blurRadius: 8,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            right: -4,
            top: 10,
            child: Container(
              width: 92,
              height: 88,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.13),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(70),
                  bottomLeft: Radius.circular(70),
                  bottomRight: Radius.circular(8),
                ),
              ),
            ),
          ),
          Positioned(
            right: 2,
            bottom: 12,
            child: Image.asset(
              'assets/images/ai_robot.png',
              width: 84,
              height: 84,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) {
                return const Icon(
                  Icons.smart_toy_rounded,
                  color: Colors.white,
                  size: 66,
                );
              },
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Overview',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Total Overview',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  _stat(totalItems.toString(), 'Total Items'),
                  _line(),
                  _stat(nearExpiry.toString(), 'Near Expiry'),
                  _line(),
                  _stat(lowStock.toString(), 'Low Stock'),
                ],
              ),
              const Spacer(),
              const Row(
                children: [
                  Text(
                    'View All',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(width: 5),
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    color: Colors.white,
                    size: 12,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) {
    return SizedBox(
      width: 58,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _line() {
    return Container(
      width: 1,
      height: 32,
      margin: const EdgeInsets.symmetric(horizontal: 7),
      color: Colors.white.withValues(alpha: 0.28),
    );
  }
}
