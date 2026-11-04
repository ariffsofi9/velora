import '../../core/theme/app_tokens.dart';
import 'package:flutter/material.dart';

import '../../models/inventory_item.dart';
import 'action_card.dart';
import 'empty_card.dart';

class SuggestionPageTitle extends StatelessWidget {
  const SuggestionPageTitle({super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('AI Suggestions', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: AppSpacing.sm),
      Text(
        'Recipe ideas from your caf? inventory',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
      ),
    ],
  );
}

class SuggestionActionButtons extends StatelessWidget {
  final VoidCallback? onRecipeTap;
  final VoidCallback? onRestockTap;

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

    return Column(
      children: [
        for (final item in nearExpiry)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.schedule_outlined,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            '${item.quantity} ${item.unit} ? ${daysLeftText(item.expiryDate)}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
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
