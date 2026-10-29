import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';

class DealDetailModal extends StatelessWidget {
  final Map<String, dynamic> deal;
  final Map<String, dynamic> product;
  final Map<String, dynamic> aisle;
  const DealDetailModal({
    super.key,
    required this.deal,
    required this.product,
    required this.aisle,
  });

  static void show(
    BuildContext context, {
    required Map<String, dynamic> deal,
    required Map<String, dynamic> product,
    required Map<String, dynamic> aisle,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => SingleChildScrollView(
      child: DealDetailModal(deal: deal, product: product, aisle: aisle),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    // Re-read after a refresh: an offer may have been withdrawn or sold out.
    final current = provider.discounts.where((d) => d['id'] == deal['id']);
    final offer = current.isEmpty ? deal : current.first;
    final available =
        provider.isBackendOnline &&
        !provider.isSyncingBackend &&
        provider.syncFailures.isEmpty &&
        provider.lastBackendError == null &&
        current.isNotEmpty &&
        provider.isDealAvailable(offer) &&
        offer['storeId'] == provider.selectedStoreId;
    final saved = provider.savedDealIds.contains(deal['id']);
    final stock = offer['stock'] as num? ?? 0;
    final expiry = offer['expiryDate']?.toString();
    final status = stock <= 0
        ? 'Sold out'
        : available
        ? 'Available'
        : 'Unavailable - refresh store offers';
    String price(dynamic value) =>
        value is num ? value.toStringAsFixed(2) : 'Not available';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              offer['productName'] ?? product['name'] ?? 'Store offer',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text(provider.selectedStoreName),
            const SizedBox(height: 16),
            Text(
              'USD ${price(offer['finalPrice'])}',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            Text(
              'Original price: USD ${price(offer['originalPrice'])} | ${offer['discountPercent']}% off',
            ),
            const SizedBox(height: 16),
            Text(
              status,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: available ? Colors.green.shade700 : Colors.red.shade700,
              ),
            ),
            Text('Discounted stock at last refresh: $stock units'),
            Text(
              expiry == null
                  ? 'Expiry date unavailable'
                  : 'Valid through $expiry, 23:59 (Asia/Bangkok), while eligible stock remains.',
            ),
            const SizedBox(height: 16),
            const Text(
              'Before visiting',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text(
              'Available at this branch only, during store opening hours. Confirm pickup hours with the store; opening hours are not configured here.',
            ),
            const Text(
              'Saving this offer does not reserve stock, place an order or take payment. Staff confirm the price, eligible batch and remaining stock at the store.',
            ),
            if (offer['demoMode'] == true)
              const Text(
                'Demo offer: simulated stock and business date; not a real purchase.',
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: available
                  ? () {
                      provider.toggleSaveDeal(deal['id']);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            saved
                                ? 'Offer removed from saved offers.'
                          : 'Offer saved for this app session. Stock is not reserved.',
                          ),
                        ),
                      );
                    }
                  : null,
              icon: Icon(
                saved ? Icons.bookmark_remove : Icons.bookmark_add_outlined,
              ),
              label: Text(
              saved ? 'Remove saved offer' : 'Save offer for this session',
              ),
            ),
            TextButton(
              onPressed: provider.isSyncingBackend
                  ? null
                  : () => provider.checkBackendConnection(),
              child: const Text('Refresh availability'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}
