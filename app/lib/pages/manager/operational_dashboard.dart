import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/daily_work_overview.dart';

class OperationalDashboard extends StatelessWidget {
  final ValueChanged<int> onNavigateTab;
  const OperationalDashboard({super.key, required this.onNavigateTab});

  Widget _metric(
    BuildContext context,
    String title,
    String value,
    IconData icon,
  ) {
    return SizedBox(
      width: 245,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: const Color(0xFF16A34A)),
              const SizedBox(height: 12),
              Text(title),
              Text(value, style: Theme.of(context).textTheme.headlineMedium),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final summary = provider.backendDashboardSummary;
    final count = provider.aisles.length;
    final opening = provider.aisles.fold<num>(
      0,
      (sum, row) => sum + (row['stock'] as num),
    );
    final near = provider.aisles
        .where(
          (r) =>
              (r['stock'] as num) > 0 &&
              ((r['daysToExpiry'] ?? 999) as num) <= 2,
        )
        .length;
    final predicted = summary?['predicted_demand_total'] as num?;
    final closed = summary?['closed_product_count'] as int? ?? 0;
    final snapshots = summary?['snapshot_count'] as int? ?? count;
    final open = summary?['open_product_count'] as int? ?? count;
    final valid = summary?['valid_forecast_count'] as int? ?? 0;
    final missing = summary?['missing_open_forecast_count'] as int? ?? open;
    String recorded(String key) =>
        summary?[key] == null ? 'Not recorded' : '${summary![key]} units';
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Store overview',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        Text('${provider.selectedStoreId} • ${ApiService.defaultDate}'),
        const SizedBox(height: 16),
        DailyWorkOverview(onNavigateTab: onNavigateTab),
        if (ApiService.demoMode && ApiService.demoAutomaticCalendar)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Automatic daily demo - Asia/Bangkok',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'All branches use the Thai calendar date. Daily sales, waste and replenishment are simulated; saved staff entries are preserved. Automatic daily forecasts use mock weather and await manager approval. OpenWeather live can be run separately.',
                  ),
                ],
              ),
            ),
          ),
        if (ApiService.demoMode && !ApiService.demoAutomaticCalendar)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Demo day test',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    'Simulate only unclosed products. Existing staff closures are preserved. Generated sales/waste are test values.',
                  ),
                  Wrap(
                    spacing: 12,
                    children: [
                      OutlinedButton(
                        onPressed:
                            provider.isSyncingBackend ||
                                !provider.isBackendOnline ||
                                closed == snapshots
                            ? null
                            : () async {
                                final message = await provider.runDemoDayAction(
                                  'close-remaining',
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(message)),
                                  );
                                }
                              },
                        child: const Text('Simulate remaining closures'),
                      ),
                      FilledButton(
                        onPressed:
                            provider.isSyncingBackend ||
                                !provider.isBackendOnline ||
                                snapshots != 32 ||
                                closed != 32
                            ? null
                            : () async {
                                final message = await provider.runDemoDayAction(
                                  'advance',
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(message)),
                                  );
                                }
                              },
                        child: const Text('Go to next demo day'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _metric(
              context,
              'Product snapshots',
              '$count',
              Icons.inventory_2_outlined,
            ),
            _metric(
              context,
              'Stock before daily close (incl. receipts)',
              '$opening units',
              Icons.shopping_basket_outlined,
            ),
            _metric(
              context,
              'Expiry within 2 days',
              '$near products',
              Icons.schedule,
            ),
            _metric(
              context,
              'Forecast for unclosed products ($valid/$open)',
              predicted == null
                  ? 'Not calculated'
                  : '${predicted.toStringAsFixed(1)} units',
              Icons.auto_graph,
            ),
            _metric(
              context,
              'Restock recommendations',
              '${summary?['action_counts']?['RESTOCK'] ?? 0}',
              Icons.local_shipping_outlined,
            ),
            _metric(
              context,
              'Markdown recommendations',
              '${summary?['action_counts']?['DISCOUNT'] ?? 0}',
              Icons.sell_outlined,
            ),
            _metric(
              context,
              'Products closed',
              '$closed/$snapshots',
              Icons.fact_check_outlined,
            ),
            _metric(
              context,
              'Recorded sales (closed products)',
              recorded('recorded_sales_units'),
              Icons.point_of_sale,
            ),
            _metric(
              context,
              'Recorded waste (closed products)',
              recorded('recorded_waste_units'),
              Icons.delete_outline,
            ),
            _metric(
              context,
              'Recorded closing stock (closed products)',
              recorded('recorded_closing_units'),
              Icons.inventory_outlined,
            ),
          ],
        ),
        if (summary != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '$closed of $snapshots products closed. Sales, waste and closing stock cover only those products; they are not full-store totals until all products are closed. '
              'Closed products are excluded from actionable forecasts. $missing unclosed products need a new forecast.',
            ),
          ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Inventory by category',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                for (final category in ['Bakery', 'Produce', 'Dairy', 'Meat'])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        SizedBox(width: 85, child: Text(category)),
                        Expanded(
                          child: LinearProgressIndicator(
                            value: count == 0
                                ? 0
                                : provider.aisles
                                          .where(
                                            (r) => r['category'] == category,
                                          )
                                          .length /
                                      count,
                            minHeight: 12,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '${provider.aisles.where((r) => r['category'] == category).length} products',
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => onNavigateTab(5),
              icon: const Icon(Icons.auto_graph),
              label: const Text('AI Forecast'),
            ),
            OutlinedButton(
              onPressed: () => onNavigateTab(2),
              child: const Text('Inventory'),
            ),
            OutlinedButton(
              onPressed: () => onNavigateTab(3),
              child: const Text('Restock review'),
            ),
          ],
        ),
      ],
    );
  }
}
