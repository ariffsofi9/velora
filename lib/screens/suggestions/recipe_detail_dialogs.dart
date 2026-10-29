part of 'recipe_detail_page.dart';

abstract class _RecipeDetailDialogs extends _RecipeDetailBase {
  @override
  Future<int?> _showPortionDialog() async {
    int portions = 1;

    return showDialog<int>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              title: const Text(
                'Cook Now',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'How many portions/orders did you cook?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          onPressed: portions <= 1
                              ? null
                              : () {
                                  setDialogState(() => portions--);
                                },
                          icon: const Icon(Icons.remove_circle_outline),
                          color: AppColors.primary,
                        ),
                        Container(
                          width: 64,
                          alignment: Alignment.center,
                          child: Text(
                            portions.toString(),
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: portions >= 10
                              ? null
                              : () {
                                  setDialogState(() => portions++);
                                },
                          icon: const Icon(Icons.add_circle_outline),
                          color: AppColors.primary,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Velora will deduct this amount from each matched inventory ingredient.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF9CA3AF),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, portions),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    'Confirm',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  void _showSnackBar({required String message, required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: isError
            ? const Color(0xFFEF4444)
            : const Color(0xFF10B981),
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  @override
  void _showResultDialog(CookNowDeductionResult result) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: Text(
            result.success ? 'Inventory Updated' : 'Cook Now Failed',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          content: SingleChildScrollView(
            child: Text(
              _buildResultMessage(result),
              style: const TextStyle(
                color: AppColors.textPrimary,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);

                if (result.success) {
                  Navigator.pop(context, true);
                }
              },
              child: const Text(
                'OK',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );
      },
    );
  }

  String _buildResultMessage(CookNowDeductionResult result) {
    final buffer = StringBuffer();

    buffer.writeln(result.message);

    if (result.usedItems.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('Used items:');

      for (final item in result.usedItems) {
        buffer.writeln('• $item');
      }
    }

    if (result.skippedItems.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('Skipped items:');

      for (final item in result.skippedItems) {
        buffer.writeln('• $item');
      }
    }

    return buffer.toString().trim();
  }
}
