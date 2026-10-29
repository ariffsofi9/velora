part of 'recipe_detail_page.dart';

class _CookNowBottomBar extends StatelessWidget {
  final bool isCooking;
  final VoidCallback onPressed;

  const _CookNowBottomBar({required this.isCooking, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: SizedBox(
              height: 54,
              child: ElevatedButton.icon(
                onPressed: isCooking ? null : onPressed,
                icon: isCooking
                    ? const SizedBox(
                        height: 19,
                        width: 19,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.3,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.restaurant_rounded),
                label: Text(
                  isCooking ? 'Updating Inventory...' : 'Cook Now',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.border,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  final String title;
  final bool isSmall;

  const _HeroCard({required this.title, required this.isSmall});

  String get _imageUrl {
    final lower = title.toLowerCase();

    if (lower.contains('pizza')) {
      return 'https://images.unsplash.com/photo-1513104890138-7c749659a591';
    }

    if (lower.contains('pasta')) {
      return 'https://images.unsplash.com/photo-1521389508051-d7ffb5dc8f70';
    }

    if (lower.contains('omelette') || lower.contains('egg')) {
      return 'https://images.unsplash.com/photo-1510693206972-df098062cb71';
    }

    if (lower.contains('sandwich')) {
      return 'https://images.unsplash.com/photo-1528735602780-2552fd46c7af';
    }

    if (lower.contains('toast')) {
      return 'https://images.unsplash.com/photo-1509440159596-0249088772ff';
    }

    if (lower.contains('wrap')) {
      return 'https://images.unsplash.com/photo-1565299624946-b28f40a0ae38';
    }

    if (lower.contains('pancake')) {
      return 'https://images.unsplash.com/photo-1528207776546-365bb710ee93';
    }

    return 'https://images.unsplash.com/photo-1546069901-ba9599a7e63c';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 22,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: Stack(
          children: [
            SizedBox(
              height: isSmall ? 260 : 300,
              width: double.infinity,
              child: Image.network(
                _imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(
                  color: AppColors.nude,
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.restaurant_menu_rounded,
                    color: AppColors.primary,
                    size: 64,
                  ),
                ),
              ),
            ),

            Container(
              height: isSmall ? 260 : 300,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .34),
              ),
            ),

            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.38),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 54,
                      width: 54,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Icon(
                        Icons.restaurant_menu_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),

                    const SizedBox(height: 16),

                    Text(
                      title.isEmpty ? 'Cafe Recipe' : title,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: isSmall ? 24 : 28,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),

                    const SizedBox(height: 10),

                    Text(
                      'AI-powered cafe recipe generated from your inventory ingredients.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.88),
                        fontSize: 13,
                        height: 1.4,
                        fontWeight: FontWeight.w400,
                      ),
                    ),

                    const SizedBox(height: 14),

                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _HeroBadge(
                          icon: Icons.auto_awesome_rounded,
                          text: 'AI Recipe',
                        ),
                        _HeroBadge(
                          icon: Icons.inventory_2_rounded,
                          text: 'Inventory Based',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
