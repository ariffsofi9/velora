import 'package:flutter/material.dart';

class InventoryChangedCard extends StatelessWidget {
  final VoidCallback onRegenerate;

  const InventoryChangedCard({super.key, required this.onRegenerate});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFED7AA)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFF97316)),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Inventory changed. Generate new suggestions?',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          TextButton(onPressed: onRegenerate, child: const Text('Refresh')),
        ],
      ),
    );
  }
}
