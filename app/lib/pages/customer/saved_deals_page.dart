import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import 'deal_detail_modal.dart';

class SavedDealsPage extends StatelessWidget {
  const SavedDealsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final saved = provider.customerDeals
        .where((d) => provider.savedDealIds.contains(d['id']))
        .toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Saved offers (${saved.length})',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
        'Saved for this app session and selected branch. Saving does not reserve stock. Expired or withdrawn offers are hidden. Reloading the app clears saved offers.',
        ),
        if (saved.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('No currently available saved offers.'),
          ),
        for (final deal in saved)
          Card(
            child: ListTile(
              title: Text(deal['productName'] ?? deal['name'] ?? 'Store offer'),
              subtitle: Text(
                'USD ${deal['finalPrice']} | ${deal['discountPercent']}% off | Valid through ${deal['expiryDate']} (Bangkok)',
              ),
              onTap: () => DealDetailModal.show(
                context,
                deal: deal,
                product: {'name': deal['productName'] ?? deal['name']},
                aisle: const {},
              ),
              trailing: IconButton(
                tooltip: 'Remove saved offer',
                icon: const Icon(Icons.bookmark_remove),
                onPressed: () => provider.toggleSaveDeal(deal['id']),
              ),
            ),
          ),
      ],
    );
  }
}
