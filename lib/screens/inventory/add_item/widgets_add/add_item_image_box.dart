import '../../../../core/theme/app_tokens.dart';
import 'dart:io';
import 'package:flutter/material.dart';

class AddItemImageBox extends StatelessWidget {
  final File? selectedImage;
  final VoidCallback onTap;

  const AddItemImageBox({
    super.key,
    required this.selectedImage,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: selectedImage != null ? 170 : null,
        constraints: const BoxConstraints(minHeight: 170),
        padding: selectedImage == null
            ? const EdgeInsets.all(20)
            : EdgeInsets.zero,
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 14,
              offset: const Offset(0, 7),
            ),
          ],
        ),
        child: selectedImage != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.file(
                  selectedImage!,
                  fit: BoxFit.cover,
                  width: double.infinity,
                ),
              )
            : const _EmptyImageBox(),
      ),
    );
  }
}

class _EmptyImageBox extends StatelessWidget {
  const _EmptyImageBox();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: AppColors.nude,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(
            Icons.add_a_photo_outlined,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Add Photo',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Color(0xFF374151),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Tap to choose from gallery',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}
