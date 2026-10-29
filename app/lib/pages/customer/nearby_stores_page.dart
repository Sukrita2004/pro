import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';

class NearbyStoresPage extends StatelessWidget {
  const NearbyStoresPage({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Dataset stores',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const Text(
          'Four store identifiers are available. Verified addresses, distances, '
          'and store-level waste savings have not been supplied.',
        ),
        for (var i = 1; i <= 4; i++)
          ListTile(
            title: Text('STORE_0$i'),
            subtitle: const Text('32 training products; location unavailable'),
            selected: provider.selectedStoreId == 'STORE_0$i',
            onTap: () => provider.selectStore('STORE_0$i'),
          ),
      ],
    );
  }
}
