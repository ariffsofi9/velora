import 'package:flutter/material.dart';
import '../../../widgets/dashboard/dashboard_style.dart';

class VeloraBottomBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  const VeloraBottomBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  Widget _item(int index, String label, IconData icon) {
    final selected = index == currentIndex;
    final color = selected ? DashboardStyle.primary : DashboardStyle.secondary;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          onTap: () => onTap(index),
          borderRadius: BorderRadius.circular(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: color, size: 22),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: DashboardStyle.border)),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  _item(0, 'Home', Icons.home_rounded),
                  _item(1, 'Inventory', Icons.inventory_2_outlined),
                  Expanded(
                    child: Center(
                      heightFactor: 1,
                      child: SizedBox(
                        width: 54,
                        height: 54,
                        child: Material(
                          color: DashboardStyle.primary,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => onTap(2),
                            child: Semantics(
                              button: true,
                              label: 'Add Item',
                              child: Icon(
                                Icons.add,
                                color: Colors.white,
                                size: 30,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _item(3, 'AI Tips', Icons.tips_and_updates_outlined),
                  _item(4, 'Profile', Icons.person_outline_rounded),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
