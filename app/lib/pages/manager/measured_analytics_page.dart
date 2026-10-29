import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';

class MeasuredAnalyticsPage extends StatelessWidget {
  const MeasuredAnalyticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Waste and business evaluation',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        const Text(
          'Waste reduction and profit improvement have not yet been established. '
          'A controlled policy comparison or pilot is required; forecasting error alone '
          'does not demonstrate either outcome.',
        ),
        const SizedBox(height: 16),
        Text('Selected store: ${provider.selectedStoreId}'),
        Text('Inventory rows displayed: ${provider.aisles.length}'),
        Text(
          'Data source: ${provider.isPreview ? "MOCK snapshot" : "Backend API"}',
        ),
        const SizedBox(height: 16),
        const Text(
          'Measured waste and financial outcomes require dated waste quantities, '
          'costs, actual selling prices, and comparison periods. Product weights are '
          'additionally required for kilogram totals. Savings, ROI, and annual '
          'projections are unavailable until those data are evaluated.',
        ),
      ],
    );
  }
}
