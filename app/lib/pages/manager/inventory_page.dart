import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../providers/app_provider.dart';
import '../../data/mock_data.dart';
import '../../widgets/inventory_lots.dart';
import '../../services/api_service.dart';

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  String _selectedCategory = 'all'; // all, critical, expiring, promo, normal
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 650;

        return SingleChildScrollView(
          padding: EdgeInsets.all(isMobile ? 16.0 : 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              _buildHeader(context),
              const InventoryLots(),
              const SizedBox(height: 20),

              // Search & Filter Bar
              _buildSearchAndFilters(),
              const SizedBox(height: 20),

              // Inventory Table / List
              _buildInventoryList(context, isMobile),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final isLive = provider.isBackendOnline && provider.backendInventory.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF16A34A).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text('📦', style: TextStyle(fontSize: 28)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Store Inventory & Shelf Health',
                      style: GoogleFonts.poppins(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (isLive)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDCFCE7),
                          border: Border.all(color: const Color(0xFF86EFAC)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('🟢', style: TextStyle(fontSize: 10)),
                            const SizedBox(width: 4),
                            Text(
                              'Backend: ${provider.selectedStoreId} (${provider.backendInventory.length} items)',
                              style: GoogleFonts.inter(
                                color: const Color(0xFF15803D),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  isLive
                      ? '${provider.selectedStoreName} | Snapshot: ${ApiService.defaultDate} | ${provider.backendInventory.length} saved inventory records. ${ApiService.demoMode ? "Demo stock" : "Application stock"}.'
                      : 'Live tracking of stock quantities, expiration countdowns, sales velocities, and dynamic pricing statuses.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilters() {
    return Column(
      children: [
        TextField(
          onChanged: (val) => setState(() => _searchQuery = val.toLowerCase()),
          decoration: InputDecoration(
            hintText: 'Search products by name, category, or aisle...',
            hintStyle: GoogleFonts.inter(color: const Color(0xFF94A3B8), fontSize: 13),
            prefixIcon: const Icon(Icons.search, color: Color(0xFF64748B)),
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF16A34A), width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildFilterPill('all', 'All Products'),
              const SizedBox(width: 8),
              _buildFilterPill('critical', '🔴 Critical (<5)'),
              const SizedBox(width: 8),
              _buildFilterPill('expiring', '🟠 Expiring Today'),
              const SizedBox(width: 8),
              _buildFilterPill('promo', '🟣 Dynamic Discount'),
              const SizedBox(width: 8),
              _buildFilterPill('normal', '🟢 Healthy Stock'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFilterPill(String id, String label) {
    final isSelected = _selectedCategory == id;
    return InkWell(
      onTap: () => setState(() => _selectedCategory = id),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0F172A) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSelected ? const Color(0xFF0F172A) : const Color(0xFFE2E8F0)),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? Colors.white : const Color(0xFF475569),
          ),
        ),
      ),
    );
  }

  Widget _buildInventoryList(BuildContext context, bool isMobile) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        final aisles = provider.aisles;

        var items = aisles.where((aisle) {
          final product = productsData.firstWhere(
            (p) => p['id'] == aisle['productId'],
            orElse: () => {'name': aisle['label'], 'category': ''},
          );

          // Category filter
          if (_selectedCategory == 'critical' && aisle['status'] != 'critical') return false;
          if (_selectedCategory == 'expiring' && aisle['status'] != 'expiring') return false;
          if (_selectedCategory == 'promo' && aisle['status'] != 'promo') return false;
          if (_selectedCategory == 'normal' && aisle['status'] != 'normal' && aisle['status'] != 'low') return false;

          // Search query
          if (_searchQuery.isNotEmpty) {
            final name = (product['name'] as String).toLowerCase();
            final category = (product['category'] as String).toLowerCase();
            final aisleId = (aisle['id'] as String).toLowerCase();
            if (!name.contains(_searchQuery) && !category.contains(_searchQuery) && !aisleId.contains(_searchQuery)) {
              return false;
            }
          }
          return true;
        }).toList();

        if (items.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(40),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Text(
              'No inventory items matched your search filter.',
              style: GoogleFonts.inter(color: const Color(0xFF64748B), fontSize: 14),
            ),
          );
        }

        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            separatorBuilder: (context, index) => const Divider(height: 1, color: Color(0xFFF1F5F9)),
            itemBuilder: (context, index) {
              final aisle = items[index];
              final product = productsData.firstWhere(
                (p) => p['id'] == aisle['productId'],
                orElse: () => {'name': aisle['label'], 'emoji': '📦', 'price': 50.0, 'category': 'General', 'shelfLife': '3 days'},
              );

              final stock = (aisle['stock'] as num).toInt();
              final maxStock = (aisle['maxStock'] as num).toInt();
              final status = aisle['status'] as String;

              Color statusColor;
              String statusLabel;
              if (status == 'critical') {
                statusColor = const Color(0xFFEF4444);
                statusLabel = '🔴 Critical';
              } else if (status == 'expiring') {
                statusColor = const Color(0xFFF59E0B);
                statusLabel = '🟠 Expiring';
              } else if (status == 'promo') {
                statusColor = const Color(0xFF9333EA);
                statusLabel = '🟣 Discounted';
              } else if (status == 'low') {
                statusColor = const Color(0xFFEAB308);
                statusLabel = '🟡 Low';
              } else {
                statusColor = const Color(0xFF16A34A);
                statusLabel = '🟢 Normal';
              }

              if (isMobile) {
                // Responsive Clean Mobile Card View
                return Padding(
                  padding: const EdgeInsets.all(14.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            alignment: Alignment.center,
                            child: Text(product['emoji'] ?? '📦', style: const TextStyle(fontSize: 20)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  product['name'],
                                  style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 14, color: const Color(0xFF0F172A)),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '${product['category']} · ${aisle['id']} (${aisle['label']})',
                                  style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF64748B)),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                'USD ${product['price']}',
                                style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A)),
                              ),
                              const SizedBox(height: 2),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: statusColor.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  statusLabel,
                                  style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.bold, color: statusColor),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      '$stock / $maxStock units',
                                      style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, color: const Color(0xFF1E293B)),
                                    ),
                                    const Spacer(),
                                    InkWell(
                                      onTap: () => provider.adjustStock(aisle['id'], -1),
                                      child: Container(
                                        padding: const EdgeInsets.all(2),
                                        decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(4)),
                                        child: const Icon(Icons.remove, size: 14, color: Color(0xFF475569)),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    InkWell(
                                      onTap: () => provider.adjustStock(aisle['id'], 5),
                                      child: Container(
                                        padding: const EdgeInsets.all(2),
                                        decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(4)),
                                        child: const Icon(Icons.add, size: 14, color: Color(0xFF475569)),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: (stock / maxStock).clamp(0.0, 1.0),
                                    backgroundColor: const Color(0xFFE2E8F0),
                                    valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                                    minHeight: 5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 14),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('Shelf Life: ${product['shelfLife']}', style: GoogleFonts.inter(fontSize: 10, color: const Color(0xFF64748B))),
                              Text('⚡ ${aisle['salesVelocity']} u/hr', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, color: const Color(0xFF1E293B))),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }

              // Desktop Multi-Column Table Row
              return Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    // Emoji Icon
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Text(product['emoji'] ?? '📦', style: const TextStyle(fontSize: 22)),
                    ),
                    const SizedBox(width: 14),

                    // Name & Aisle
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            product['name'],
                            style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 14, color: const Color(0xFF0F172A)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${product['category']} · ${aisle['id']} (${aisle['label']})',
                            style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF64748B)),
                          ),
                        ],
                      ),
                    ),

                    // Stock Progress & Controls
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                '$stock / $maxStock units',
                                style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: const Color(0xFF1E293B)),
                              ),
                              const Spacer(),
                              // Quick +/- adjustment buttons
                              InkWell(
                                onTap: () => provider.adjustStock(aisle['id'], -1),
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(4)),
                                  child: const Icon(Icons.remove, size: 14, color: Color(0xFF475569)),
                                ),
                              ),
                              const SizedBox(width: 6),
                              InkWell(
                                onTap: () => provider.adjustStock(aisle['id'], 5),
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(4)),
                                  child: const Icon(Icons.add, size: 14, color: Color(0xFF475569)),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: (stock / maxStock).clamp(0.0, 1.0),
                              backgroundColor: const Color(0xFFE2E8F0),
                              valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                              minHeight: 6,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),

                    // Expiry & Velocity
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Shelf Life: ${product['shelfLife']}', style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF64748B))),
                          Text('⚡ ${aisle['salesVelocity']} units/hr', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: const Color(0xFF1E293B))),
                        ],
                      ),
                    ),

                    // Price & Status Badge
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'USD ${product['price']}',
                          style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.bold, color: const Color(0xFF0F172A)),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            statusLabel,
                            style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.bold, color: statusColor),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
