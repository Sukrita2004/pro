import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../providers/app_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/data_context_bar.dart';
import 'operational_dashboard.dart';
import 'inventory_page.dart';
import 'recommendation_review_page.dart';
import 'demand_forecast_page.dart';
import 'measured_analytics_page.dart';
import 'notifications_page.dart';
import 'history_page.dart';

class ManagerHome extends StatefulWidget {
  const ManagerHome({super.key});

  @override
  State<ManagerHome> createState() => _ManagerHomeState();
}

class _ManagerHomeState extends State<ManagerHome> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    // Keep page IDs stable for dashboard shortcuts when a page is removed.
    const mobilePages = [0, 2, 3, 5];
    final pages = <int, Widget>{
      0: OperationalDashboard(
        onNavigateTab: (index) => setState(() => _selectedIndex = index),
      ),
      2: const InventoryPage(),
      3: const RecommendationReviewPage(action: 'RESTOCK'),
      4: const RecommendationReviewPage(action: 'DISCOUNT'),
      5: const DemandForecastPage(),
      6: const MeasuredAnalyticsPage(),
      7: const NotificationsPage(),
      8: const HistoryPage(),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 800;

        if (isMobile) {
          // Mobile Phone View: Bottom Navigation & Clean Header
          return Scaffold(
            backgroundColor: const Color(0xFFF8FAFC),
            appBar: AppBar(
              title: Row(
                children: [
                  const Text('🌱 ', style: TextStyle(fontSize: 20)),
                  Text(
                    'FreshFlow Manager',
                    style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF0F172A),
                    ),
                  ),
                ],
              ),
              actions: [
                PopupMenuButton<int>(
                  tooltip: 'More manager pages',
                  onSelected: (index) => setState(() => _selectedIndex = index),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 7, child: Text('Notifications')),
                    PopupMenuItem(value: 8, child: Text('History')),
                  ],
                ),
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
                Expanded(child: pages[_selectedIndex]!),
              ],
            ),
            bottomNavigationBar: BottomNavigationBar(
              currentIndex: mobilePages.contains(_selectedIndex)
                  ? mobilePages.indexOf(_selectedIndex)
                  : 0,
              onTap: (index) =>
                  setState(() => _selectedIndex = mobilePages[index]),
              selectedItemColor: const Color(0xFF16A34A),
              unselectedItemColor: const Color(0xFF64748B),
              showUnselectedLabels: true,
              type: BottomNavigationBarType.fixed,
              selectedFontSize: 11,
              unselectedFontSize: 11,
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.dashboard_outlined),
                  activeIcon: Icon(Icons.dashboard),
                  label: 'Dashboard',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.inventory_2_outlined),
                  activeIcon: Icon(Icons.inventory_2),
                  label: 'Inventory',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.warning_amber_rounded),
                  activeIcon: Icon(Icons.warning_rounded),
                  label: 'Restock',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.auto_graph_outlined),
                  activeIcon: Icon(Icons.auto_graph),
                  label: 'AI Forecast',
                ),
              ],
            ),
          );
        }

        // Desktop / Tablet View: Collapsible Sidebar + Demo Scenario Ribbon
        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          body: Column(
            children: [
              // Demo Scenario Presentation Ribbon
              const DataContextBar(),

              Expanded(
                child: Row(
                  children: [
                    // Sidebar
                    _buildSidebar(context),

                    // Main Content
                    Expanded(
                      child: Column(
                        children: [
                          _buildHeader(context),
                          Expanded(child: pages[_selectedIndex]!),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSidebar(BuildContext context) {
    final alertCount = context
        .watch<AppProvider>()
        .alerts
        .where((a) => a['status'] != 'resolved')
        .length;

    return Container(
      width: 250,
      color: const Color(0xFF0F172A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Logo Area
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16A34A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.grass, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 10),
                Text(
                  'FreshFlow',
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(
              'MANAGEMENT PORTAL',
              style: GoogleFonts.inter(
                color: const Color(0xFF64748B),
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
          ),

          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _buildNavItem(0, Icons.dashboard_outlined, 'Dashboard'),
                _buildNavItem(2, Icons.inventory_2_outlined, 'Inventory'),
                _buildNavItem(
                  3,
                  Icons.warning_amber_rounded,
                  'Restock Center',
                  badge: alertCount > 0 ? '$alertCount' : null,
                ),
                _buildNavItem(4, Icons.local_offer_outlined, 'Dynamic Pricing'),
                _buildNavItem(5, Icons.auto_graph, 'AI Forecast'),
                _buildNavItem(6, Icons.bar_chart, 'Business Impact'),
                _buildNavItem(7, Icons.notifications_none, 'Notifications'),
                _buildNavItem(8, Icons.history, 'History'),
              ],
            ),
          ),

          // User Profile Bottom
          Builder(
            builder: (context) {
              final user = context.watch<AppProvider>().currentUser;
              final userName = user?['name'] ?? 'Somchai Jaidee';
              final userBranch = context.watch<AppProvider>().selectedStoreName;
              final initial = userName.isNotEmpty
                  ? userName[0].toUpperCase()
                  : 'M';

              return Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: const Color(0xFF16A34A),
                          radius: 16,
                          child: Text(
                            initial,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                userName,
                                style: GoogleFonts.inter(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                userBranch,
                                style: GoogleFonts.inter(
                                  color: const Color(0xFF94A3B8),
                                  fontSize: 11,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    InkWell(
                      onTap: () {
                        context.read<AppProvider>().setRole(null);
                        context.go('/login');
                      },
                      child: Row(
                        children: [
                          const Icon(
                            Icons.logout,
                            color: Color(0xFF94A3B8),
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Sign out',
                            style: GoogleFonts.inter(
                              color: const Color(0xFF94A3B8),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(
    int index,
    IconData icon,
    String title, {
    String? badge,
  }) {
    final isSelected = _selectedIndex == index;
    return InkWell(
      onTap: () => setState(() => _selectedIndex = index),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected
                  ? const Color(0xFF16A34A)
                  : const Color(0xFF94A3B8),
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: GoogleFonts.inter(
                  color: isSelected ? Colors.white : const Color(0xFFCBD5E1),
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (badge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    const titles = {
      0: 'Store Overview Dashboard',
      2: 'Inventory & Shelf Tracker',
      3: 'Restock Alert Center',
      4: 'Dynamic Discount Engine',
      5: 'AI Prediction Intelligence',
      6: 'Business Impact & Sustainability',
      7: 'Notifications Feed',
      8: 'Historical Records',
    };

    final provider = context.watch<AppProvider>();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titles[_selectedIndex]!,
                style: GoogleFonts.poppins(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF0F172A),
                ),
              ),
              Text(
                'Selected store — see scope above',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: const Color(0xFF64748B),
                ),
              ),
            ],
          ),
          Row(
            children: [
              // Backend Status Indicator
              InkWell(
                onTap: () => _showBackendConfigDialog(context),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  margin: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    color: provider.isBackendOnline
                        ? const Color(0xFFDCFCE7)
                        : const Color(0xFFFEF3C7),
                    border: Border.all(
                      color: provider.isBackendOnline
                          ? const Color(0xFF86EFAC)
                          : const Color(0xFFFCD34D),
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (provider.isSyncingBackend)
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF16A34A),
                          ),
                        )
                      else
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: provider.isBackendOnline
                                ? const Color(0xFF16A34A)
                                : const Color(0xFFD97706),
                          ),
                        ),
                      const SizedBox(width: 8),
                      Text(
                        provider.isBackendOnline
                            ? 'FastAPI Online'
                            : 'Mock Mode (Backend Offline)',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: provider.isBackendOnline
                              ? const Color(0xFF15803D)
                              : const Color(0xFFB45309),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.settings_outlined,
                        size: 14,
                        color: provider.isBackendOnline
                            ? const Color(0xFF15803D)
                            : const Color(0xFFB45309),
                      ),
                    ],
                  ),
                ),
              ),

              OutlinedButton.icon(
                onPressed: () {
                  context.read<AppProvider>().setRole(null);
                  context.go('/login');
                },
                icon: const Icon(Icons.swap_horiz, size: 16),
                label: const Text('Sign out'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF475569),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showBackendConfigDialog(BuildContext context) {
    final urlCtrl = TextEditingController(text: ApiService.baseUrl);
    final keyCtrl = TextEditingController(text: ApiService.apiKey);
    final provider = context.read<AppProvider>();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.dns_rounded, color: Color(0xFF16A34A)),
                const SizedBox(width: 8),
                Text(
                  'FastAPI Backend Settings',
                  style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Current Status: ${provider.backendStatusMessage}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: provider.isBackendOnline
                          ? const Color(0xFF16A34A)
                          : const Color(0xFFD97706),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: urlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Backend Base URL',
                      hintText: 'http://127.0.0.1:8000',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: keyCtrl,
                    decoration: const InputDecoration(
                      labelText: 'X-API-Key (from backend .env)',
                      hintText: 'your_local_admin_key',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.key),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (provider.isBackendOnline) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF86EFAC)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(
                                Icons.check_circle,
                                color: Color(0xFF16A34A),
                                size: 16,
                              ),
                              SizedBox(width: 6),
                              Text(
                                'LIVE DATA VERIFIED FROM BACKEND',
                                style: TextStyle(
                                  color: Color(0xFF15803D),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '• Store ID: STORE_01 · Date: 2026-10-12',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: const Color(0xFF166534),
                            ),
                          ),
                          Text(
                            '• Loaded Snapshots: ${provider.backendInventory.length} items',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: const Color(0xFF166534),
                            ),
                          ),
                          Text(
                            '• Total Opening Units: ${provider.backendDashboardSummary?['total_opening_units'] ?? 556} units',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: const Color(0xFF166534),
                            ),
                          ),
                          Text(
                            '• Expiring Items (0-2d): ${provider.backendDashboardSummary?['near_expiry_in_stock_count'] ?? 16} items',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: const Color(0xFF166534),
                            ),
                          ),
                          Text(
                            '• AI Actions: ${provider.backendRecommendations.length} recommendations',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: const Color(0xFF166534),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '💡 To run backend: "uvicorn app.main:app --reload --host 127.0.0.1 --port 8000" in freshflow-backend. If using Web, ensure CORS_ORIGINS in .env allows this web port.',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: const Color(0xFF475569),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Save & Test Connection'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF16A34A),
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  ApiService.baseUrl = urlCtrl.text.trim();
                  ApiService.apiKey = keyCtrl.text.trim();
                  Navigator.pop(ctx);
                  await provider.checkBackendConnection();
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
