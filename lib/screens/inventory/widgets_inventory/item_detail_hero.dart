import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../models/inventory_item.dart';

class ItemDetailHero extends StatelessWidget {
  final InventoryItem item;
  final bool hasImage;
  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String expiryText;
  final Color expiryColor;
  final Color expiryBg;
  final bool isSmall;

  const ItemDetailHero({
    super.key,
    required this.item,
    required this.hasImage,
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.expiryText,
    required this.expiryColor,
    required this.expiryBg,
    required this.isSmall,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(isSmall ? 18 : 22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _ImageBox(
            item: item,
            hasImage: hasImage,
            icon: icon,
            iconBg: iconBg,
            iconColor: iconColor,
            isSmall: isSmall,
          ),
          const SizedBox(height: 18),
          Text(
            item.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: isSmall ? 22 : 25,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.category,
            style: const TextStyle(
              fontWeight: FontWeight.w400,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: expiryBg,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              expiryText,
              style: TextStyle(fontWeight: FontWeight.w600, color: expiryColor),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageBox extends StatelessWidget {
  final InventoryItem item;
  final bool hasImage;
  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final bool isSmall;

  const _ImageBox({
    required this.item,
    required this.hasImage,
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.isSmall,
  });

  @override
  Widget build(BuildContext context) {
    final height = isSmall ? 150.0 : 180.0;

    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: iconBg,
        borderRadius: BorderRadius.circular(18),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: hasImage && !kIsWeb
            ? Image.file(
                File(item.imageUrl),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => _fallbackIcon(),
              )
            : _fallbackIcon(),
      ),
    );
  }

  Widget _fallbackIcon() {
    return Icon(icon, size: isSmall ? 58 : 70, color: iconColor);
  }
}

class ItemDetailTipsCard extends StatelessWidget {
  final String expiryText;
  final Color expiryColor;

  const ItemDetailTipsCard({
    super.key,
    required this.expiryText,
    required this.expiryColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lightbulb_rounded, color: Color(0xFFF59E0B)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Tip: This item status is $expiryText. Use near-expiry items first to reduce food waste.',
              style: TextStyle(
                height: 1.4,
                fontWeight: FontWeight.w400,
                color: expiryColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
