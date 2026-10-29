import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../pages/staff/daily_entry_page.dart';

class DailyWorkOverview extends StatelessWidget {
  final ValueChanged<int> onNavigateTab;
  const DailyWorkOverview({super.key, required this.onNavigateTab});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final summary = provider.backendDashboardSummary;
    final ready =
        provider.isBackendOnline &&
        !provider.isSyncingBackend &&
        provider.syncFailures.isEmpty &&
        provider.lastBackendError == null;
    final inventory = provider.backendInventory;
    final near = inventory
        .where(
          (row) =>
              (row['opening_inventory_units'] as num? ?? 0) > 0 &&
              (row['days_to_expiry'] as num? ?? 999) <= 2,
        )
        .toList();
    final pending = provider.backendRecommendations
        .where(
          (row) =>
              row['approval_status'] == 'PROPOSED' &&
              row['sale_eligible_now'] == true &&
              (row['actions'] as List? ?? []).any(
                (a) => a['action'] == 'DISCOUNT',
              ),
        )
        .length;
    final warnings = <String>[];
    if (!provider.isBackendOnline) {
      warnings.add(
        'Backend unavailable. Reconnect before acting on inventory or offers.',
      );
    } else if (provider.isSyncingBackend) {
      warnings.add('Refreshing store data. Wait for the refresh to finish.');
    }
    if (provider.syncFailures.isNotEmpty || provider.lastBackendError != null) {
      warnings.add(
        'Some data could not be refreshed. Retry before making decisions.',
      );
    }
    if (provider.isBackendOnline && !provider.isSyncingBackend) {
      if (inventory.isEmpty) {
        warnings.add(
          'No inventory saved for this date. Record opening stock or receive a delivery in Daily entry.',
        );
      }
      if (summary == null) {
        warnings.add('Daily summary unavailable. Retry the data refresh.');
      }
      final previous = summary?['previous_unclosed_product_count'] as num? ?? 0;
      if (previous > 0) {
        warnings.add(
          '$previous products were not closed on ${summary?['previous_business_date']}. Review Daily entry for that date.',
        );
      }
      final historyDay = summary?['latest_history_date']?.toString();
      final previousDay = summary?['previous_business_date']?.toString();
      if (summary != null &&
          (historyDay == null ||
              (previousDay != null && historyDay.compareTo(previousDay) < 0))) {
        warnings.add(
          'Sales history does not reach the previous day. Complete missing daily records before forecasting.',
        );
      }
      if ((summary?['missing_open_forecast_count'] as num? ?? 0) > 0) {
        warnings.add(
          'Some open products need a new forecast. Open AI Forecast after updating stock.',
        );
      }
      final weather = provider.backendRecommendations
          .map((r) => r['result']?['weather'])
          .whereType<Map>()
          .toList();
      if (weather.any((w) => w['source'] == 'mock')) {
        warnings.add(
          'Current recommendations use mock weather. Select live weather in AI Forecast when real weather is required.',
        );
      }
      final now = DateTime.now().toUtc();
      if (weather.any((w) {
        if (w['source'] == 'mock') return false;
        final fetched = DateTime.tryParse(w['fetched_at']?.toString() ?? '');
        return fetched == null || now.difference(fetched.toUtc()).inHours >= 3;
      })) {
        warnings.add(
          'Live weather is old or has no fetch time. Run a fresh live forecast.',
        );
      }
      if (!ApiService.demoMode &&
          inventory.any(
            (r) => RegExp(
              'MOCK|DEMO|SYNTHETIC',
            ).hasMatch(r['snapshot_source']?.toString() ?? ''),
          )) {
        warnings.add(
          'This selection contains demo or synthetic stock. Replace it with verified store records before operational use.',
        );
      }
    }
    final updated = provider.lastSuccessfulSyncAt?.add(
      const Duration(hours: 7),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Today's tasks",
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              '${provider.selectedStoreName} | Business date: ${ApiService.defaultDate}',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: ready ? () => onNavigateTab(2) : null,
                  child: Text(
                    'Check expiry / sell-first batches (${near.length})',
                  ),
                ),
                OutlinedButton(
                  onPressed: ready ? () => onNavigateTab(4) : null,
                  child: Text('Review pending discounts ($pending)'),
                ),
                OutlinedButton(
                  onPressed: ready ? () => onNavigateTab(3) : null,
                  child: const Text('Review replenishment'),
                ),
                OutlinedButton(
                  onPressed: ready
                      ? () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => Scaffold(
                              appBar: AppBar(title: const Text('Daily entry')),
                              body: const DailyEntryPage(),
                            ),
                          ),
                        )
                      : null,
                  child: const Text('Receive stock / close day'),
                ),
                OutlinedButton(
                  onPressed: ready ? () => onNavigateTab(5) : null,
                  child: const Text('Open AI Forecast'),
                ),
              ],
            ),
            if (ready && near.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                'Check these products first; open Inventory for lot instructions:',
              ),
              for (final row in near.take(5))
                Text(
                  '${row['product_name'] ?? row['product_id']} | ${row['days_to_expiry']} days to earliest expiry',
                ),
              if (near.length > 5) Text('${near.length - 5} more in Inventory'),
            ],
            const Divider(),
            Text(
              'Data readiness',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (updated != null)
              Text(
                'Last complete refresh: ${updated.toIso8601String().substring(0, 19).replaceFirst('T', ' ')} (Bangkok)',
              ),
            if (warnings.isEmpty)
              const Text(
                'No issues detected in the available checks. Verify physical stock before acting.',
              ),
            for (final warning in warnings)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(warning),
              ),
            TextButton.icon(
              onPressed: provider.isSyncingBackend
                  ? null
                  : () => provider.checkBackendConnection(),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh store data'),
            ),
          ],
        ),
      ),
    );
  }
}
