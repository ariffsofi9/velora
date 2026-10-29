import 'package:flutter/material.dart';
import '../../../core/theme/app_tokens.dart';

class NotificationHeaderCard extends StatelessWidget {
  final int total;
  final int unread;
  final VoidCallback onReadAll;
  const NotificationHeaderCard({
    super.key,
    required this.total,
    required this.unread,
    required this.onReadAll,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 8,
      children: [
        Text(
          '$total active alerts \u00b7 $unread unread',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
        ),
        TextButton(
          onPressed: total == 0 ? null : onReadAll,
          child: const Text('Read all'),
        ),
      ],
    ),
  );
}
