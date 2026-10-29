import '../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

import '../../models/inventory_item.dart';
import 'action_card.dart';
import 'empty_card.dart';
import 'near_expiry_card.dart';

class SuggestionPageTitle extends StatelessWidget {
  const SuggestionPageTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI Suggestions',
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              SizedBox(height: 5),
              Text(
                'Smart ideas to manage your inventory',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: AppColors.nude,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(
            Icons.auto_awesome_rounded,
            color: AppColors.primary,
          ),
        ),
      ],
    );
  }
}

class SuggestionActionButtons extends StatelessWidget {
  final VoidCallback onRecipeTap;
  final VoidCallback onRestockTap;

  const SuggestionActionButtons({
    super.key,
    required this.onRecipeTap,
    required this.onRestockTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ActionCard(
            title: 'Generate Recipes',
            subtitle: 'AI recipe ideas',
            icon: Icons.restaurant_rounded,
            isPrimary: true,
            onTap: onRecipeTap,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ActionCard(
            title: 'Restock Advice',
            subtitle: 'What to buy',
            icon: Icons.shopping_cart_rounded,
            isPrimary: false,
            onTap: onRestockTap,
          ),
        ),
      ],
    );
  }
}

class NearExpirySection extends StatelessWidget {
  final List<InventoryItem> nearExpiry;
  final String Function(DateTime) daysLeftText;

  const NearExpirySection({
    super.key,
    required this.nearExpiry,
    required this.daysLeftText,
  });

  @override
  Widget build(BuildContext context) {
    if (nearExpiry.isEmpty) {
      return const EmptyCard(text: 'No near-expiry items found.');
    }

    return SizedBox(
      height: 180,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: nearExpiry.length,
        separatorBuilder: (context, index) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final item = nearExpiry[index];

          return NearExpiryCard(
            item: item,
            daysLeft: daysLeftText(item.expiryDate),
          );
        },
      ),
    );
  }
}

class SuggestionSectionTitle extends StatelessWidget {
  final String title;

  const SuggestionSectionTitle({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
    );
  }
}
