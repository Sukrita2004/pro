import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';

class StaffTasksPage extends StatelessWidget {
  const StaffTasksPage({super.key});
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final rows = provider.alerts
        .where((a) => a['status'] != 'resolved')
        .toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Replenishment tasks',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const Text(
          'These are recommendations, not deliveries. Record a physical receipt with its quantity, batch and expiry in the Daily entry tab.',
        ),
        const SizedBox(height: 16),
        if (rows.isEmpty)
          const Text(
            'No replenishment tasks for this store/date. Run a forecast if needed.',
          ),
        ...rows.map(
          (row) => Card(
            child: ListTile(
              leading: const Icon(Icons.local_shipping_outlined),
              title: Text(row['title'] as String),
            ),
          ),
        ),
      ],
    );
  }
}
