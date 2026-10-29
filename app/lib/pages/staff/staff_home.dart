import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../providers/app_provider.dart';
import 'staff_tasks_page.dart';
import 'staff_inventory_page.dart';
import 'staff_notifications_page.dart';
import 'daily_entry_page.dart';
import '../../widgets/data_context_bar.dart';

class StaffHome extends StatefulWidget {
  const StaffHome({super.key});

  @override
  State<StaffHome> createState() => _StaffHomeState();
}

class _StaffHomeState extends State<StaffHome> {
  int _selectedIndex = 0;

  static const List<Widget> _pages = <Widget>[
    StaffTasksPage(),
    StaffInventoryPage(),
    StaffNotificationsPage(),
    DailyEntryPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final alertCount = context
        .watch<AppProvider>()
        .alerts
        .where((a) => a['status'] != 'resolved')
        .length;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF16A34A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('🌱', style: TextStyle(fontSize: 16)),
            ),
            const SizedBox(width: 8),
            Text(
              'FreshFlow Staff',
              style: GoogleFonts.poppins(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: const Color(0xFF0F172A),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz, color: Color(0xFF16A34A)),
            tooltip: 'Sign out',
            onPressed: () {
              context.read<AppProvider>().setRole(null);
              context.go('/login');
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const DataContextBar(),
          Expanded(child: _pages.elementAt(_selectedIndex)),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        items: [
          BottomNavigationBarItem(
            icon: Badge(
              isLabelVisible: alertCount > 0,
              label: Text('$alertCount'),
              child: const Icon(Icons.checklist_rounded),
            ),
            label: 'My Tasks',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.inventory_2_outlined),
            activeIcon: Icon(Icons.inventory_2),
            label: 'Inventory',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.notifications_none_rounded),
            activeIcon: Icon(Icons.notifications),
            label: 'Alerts',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.add_box_outlined),
            label: 'Daily entry',
          ),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: const Color(0xFF16A34A),
        unselectedItemColor: const Color(0xFF64748B),
        onTap: (index) => setState(() => _selectedIndex = index),
        type: BottomNavigationBarType.fixed,
        selectedFontSize: 12,
        unselectedFontSize: 12,
      ),
    );
  }
}
