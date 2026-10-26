import 'package:flutter/material.dart';
import 'widgets_home/bottom_bar.dart';
import '../../widgets/dashboard/dashboard_style.dart';

import '../dashboard/dashboard_page.dart';
import '../inventory/inventory_page.dart';
import '../suggestions/suggestions_page.dart';
import '../inventory/add_item/add_item_page.dart';
import '../settings/settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;

  final List<Widget> _pages = const [
    DashboardPage(),
    InventoryPage(),
    SizedBox(),
    SuggestionsPage(),
    SettingsPage(),
  ];

  void _changePage(int index) {
    if (index == 2) {
      _showAddMessage();
      return;
    }

    setState(() => _selectedIndex = index);
  }

  void _showAddMessage() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddItemPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DashboardStyle.background,
      body: _pages[_selectedIndex],
      bottomNavigationBar: VeloraBottomBar(
        currentIndex: _selectedIndex,
        onTap: _changePage,
      ),
    );
  }
}
