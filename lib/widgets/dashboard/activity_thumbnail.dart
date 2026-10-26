import 'package:flutter/material.dart';
import 'dashboard_style.dart';

/// Uses stored remote images only; local device paths remain a neutral fallback.
class ActivityThumbnail extends StatelessWidget {
  final String imageUrl;
  const ActivityThumbnail({super.key, required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(imageUrl.trim());
    const fallback = Icon(
      Icons.kitchen_outlined,
      size: 22,
      color: DashboardStyle.secondary,
    );
    return Container(
      width: 34,
      height: 38,
      decoration: BoxDecoration(
        color: DashboardStyle.background,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
          ? Image.network(
              uri.toString(),
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (_, error, stack) => fallback,
              loadingBuilder: (_, child, progress) =>
                  progress == null ? child : fallback,
            )
          : fallback,
    );
  }
}
