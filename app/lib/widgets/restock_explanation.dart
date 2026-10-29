import 'package:flutter/material.dart';

/// Uses the saved policy result, rather than recomputing the order in the UI.
class RestockExplanation extends StatelessWidget {
  final Map<String, dynamic> result;
  const RestockExplanation({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final detail = result['replenishment_explanation'] as Map?;
    String units(dynamic value) => value is num
        ? value.toStringAsFixed(value % 1 == 0 ? 0 : 2)
        : 'Not recorded';
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('Why this replenishment quantity?'),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            [
              'Suggested order: ${units(result['restock_quantity_units'])} units',
              'Forecast demand per day: ${units(result['predicted_demand_units'])} units',
              if (detail != null)
                'Arrival: ${detail['arrival_date']} | Delivery: ${detail['lead_time_days']} days | Review period: ${detail['review_period_days']} days',
              if (detail != null)
                'Safety buffer: ${units(detail['buffer_units'])} units (policy assumption)',
              'Target stock: ${units(result['order_up_to_units'])} units',
              'Stock expected to remain usable at arrival: ${units(result['usable_inventory_at_arrival_units'])} units',
              if (detail != null)
                'Pending deliveries included: ${units(detail['pending_order_units'])} units',
              'Fresh-batch shelf-life cap: ${units(result['new_batch_shelf_life_cap_units'])} units',
              if (detail != null)
                'Order = target minus usable stock minus pending deliveries. ${detail['rounding']}',
              if (detail == null)
                'Run a new forecast to record the arrival date, buffer and pending-delivery breakdown.',
              'FEFO accounts for sales before delivery and lot expiry. Approval plans an order; receive the actual delivery separately.',
            ].join('\n'),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
