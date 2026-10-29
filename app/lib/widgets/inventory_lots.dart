import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';

class InventoryLots extends StatelessWidget {
  const InventoryLots({super.key});

  Widget _product(Map<String, dynamic> row) {
    final day = row['snapshot_date'] as String;
    final lots = List<Map<String, dynamic>>.from(row['lots'] ?? [])
      ..sort(
        (a, b) => '${a['expiry_date']}/${a['lot_key']}'.compareTo(
          '${b['expiry_date']}/${b['lot_key']}',
        ),
      );
    final available = lots.where((lot) => (lot['units'] as num) > 0).toList();
    final sellable = available
        .where((lot) => '${lot['expiry_date']}'.compareTo(day) >= 0)
        .toList();
    final expired = available
        .where((lot) => '${lot['expiry_date']}'.compareTo(day) < 0)
        .toList();
    final summary = sellable.isEmpty
        ? 'Do not sell: no unexpired stock is available.'
        : sellable.length == 1
        ? 'Only one unexpired batch: sell these ${sellable.first['units']} units before expiry.'
        : 'Sell ${sellable.first['batch_id']} first (${sellable.first['units']} units). Keep later batches for after it.';
    return ExpansionTile(
      title: Text('${row['product_id']} - ${row['product_name']}'),
      subtitle: Text(
        '${expired.isNotEmpty ? 'Remove ${expired.fold<num>(0, (sum, lot) => sum + (lot['units'] as num))} expired units. ' : ''}$summary',
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text('Selling order for inventory dated $day.'),
        ),
        for (final lot in available) _batch(lot, day, sellable),
        if (available.isEmpty) const ListTile(title: Text('NO STOCK TO SELL')),
      ],
    );
  }

  Widget _batch(
    Map<String, dynamic> lot,
    String day,
    List<Map<String, dynamic>> sellable,
  ) {
    final expired = '${lot['expiry_date']}'.compareTo(day) < 0;
    final index = sellable.indexOf(lot);
    final first = index == 0;
    final title = expired
        ? 'DO NOT SELL - EXPIRED'
        : first
        ? 'SELL THESE ${lot['units']} UNITS FIRST'
        : 'SELL AFTER BATCH ${sellable[index - 1]['batch_id']}';
    final instruction = expired
        ? 'Remove these ${lot['units']} units from sale and record them as waste when discarded.'
        : first
        ? 'Pick from this batch before any later-expiring batch.'
        : 'Keep these ${lot['units']} units for after the earlier batch is sold or removed. Do not sell them if they expire.';
    return ListTile(
      leading: Icon(
        expired
            ? Icons.block
            : first
            ? Icons.arrow_forward
            : Icons.hourglass_bottom,
        color: expired
            ? Colors.red
            : first
            ? const Color(0xFF15803D)
            : Colors.blueGrey,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: expired ? Colors.red : null,
        ),
      ),
      subtitle: Text(
        '$instruction\nBatch: ${lot['batch_id']} | ${lot['units']} units | Expires: ${lot['expiry_date']}\n'
        '${lot['source'] == 'DEMO_CALENDAR_RECEIPT'
            ? 'Automatically generated demo delivery.'
            : lot['source'] == 'RECORDED_RECEIPT'
            ? 'From a recorded delivery.'
            : 'Opening batch estimated from old records; verify the physical stock.'}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = context.watch<AppProvider>().backendInventory;
    if (!rows.any((row) => row['lots'] != null)) return const SizedBox.shrink();
    return Card(
      child: ExpansionTile(
        title: const Text('Which batch should staff sell first?'),
        subtitle: const Text(
          'Open a product to see what to sell first, what to sell next, and what must be removed.',
        ),
        children: [for (final row in rows) _product(row)],
      ),
    );
  }
}
