import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/restock_explanation.dart';

class RecommendationReviewPage extends StatefulWidget {
  final String action;
  const RecommendationReviewPage({super.key, required this.action});
  @override
  State<RecommendationReviewPage> createState() =>
      _RecommendationReviewPageState();
}

class _RecommendationReviewPageState extends State<RecommendationReviewPage> {
  bool _saving = false;
  String _discountFilter = 'ALL';

  Future<void> _decide(AppProvider provider, String id, bool approve) async {
    var acknowledged = false;
    final row = provider.backendRecommendations.firstWhere(
      (r) => r['recommendation_id'].toString() == id,
    );
    if (approve && row['result']['below_cost'] == true) {
      final result = row['result'];
      acknowledged =
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Approve below-cost clearance?'),
              content: Text(
                'Selling price: USD ${result['selling_price_usd']}\nLot cost reference: USD ${result['unit_cost_reference_usd']}\nMargin before other costs: USD ${result['unit_margin_before_other_costs_usd']} per unit.\nThis recovers revenue before expiry; it does not guarantee profit. Approval applies to this recommendation and its actions.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Approve clearance'),
                ),
              ],
            ),
          ) ??
          false;
      if (!acknowledged || !mounted) return;
    }
    setState(() => _saving = true);
    try {
      final saved = approve
          ? await provider.approveRecommendation(
              id,
              acknowledgeBelowCost: acknowledged,
            )
          : await provider.rejectRecommendation(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              saved
                  ? 'Decision saved. Approval is not a delivery or automatic price change.'
                  : 'Could not save. The recommendation may be stale; refresh and run again.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final rows = provider.backendRecommendations
        .where(
          (r) =>
              widget.action != 'DISCOUNT' || r['approval_status'] != 'APPROVED',
        )
        .where(
          (r) =>
              (r['actions'] as List).any((a) => a['action'] == widget.action) &&
              (widget.action != 'DISCOUNT' || r['sale_eligible_now'] == true),
        )
        .where(
          (r) =>
              widget.action != 'DISCOUNT' ||
              _discountFilter == 'ALL' ||
              r['result']['discount_type'] == _discountFilter,
        )
        .toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          widget.action == 'RESTOCK' ? 'Restock review' : 'Markdown review',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const Text(
          'Review a saved recommendation before publishing a deal or planning replenishment. '
          'Approval does not add inventory. Actual deliveries are recorded through Staff → Daily entry.',
        ),
        const SizedBox(height: 16),
        if (widget.action == 'DISCOUNT' && ApiService.demoMode)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset discount approvals (Demo)'),
              onPressed:
                  _saving ||
                      provider.isSyncingBackend ||
                      !provider.isBackendOnline
                  ? null
                  : () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Reset demo discount approvals?'),
                          content: const Text(
                            'Approved discounts for the selected store and date will return to review and disappear from customer deals. Inventory and daily records are unchanged. Other actions on the same recommendation share its approval status.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, true),
                              child: const Text('Reset approvals'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true || !mounted) return;
                      final message = await provider.runDemoDayAction(
                        'reset-discount-approvals',
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(message)));
                      }
                    },
            ),
          ),
        if (widget.action == 'DISCOUNT')
          Wrap(
            spacing: 8,
            children: [
              for (final entry in {
                'ALL': 'All discounts',
                'REGULAR': 'Regular discount',
                'CLEARANCE': 'Clearance discount',
              }.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: _discountFilter == entry.key,
                  onSelected: (_) =>
                      setState(() => _discountFilter = entry.key),
                ),
            ],
          ),
        if (rows.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                widget.action == 'DISCOUNT'
                    ? 'No discounts awaiting approval for this selection.'
                    : 'No valid restock actions for this selection.',
              ),
            ),
          ),
        ...rows.map((row) {
          final snapshot = row['input_payload']['snapshot'];
          final result = row['result'];
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${row['product_id']} — ${snapshot['product_name']}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    'Demand: ${(row['prediction']['predicted_demand_units'] as num).toStringAsFixed(2)} units • Stock: ${snapshot['opening_inventory_units']}',
                  ),
                  Text(
                    widget.action == 'RESTOCK'
                        ? 'Suggested replenishment: ${result['restock_quantity_units']} units'
                        : 'Markdown: ${result['discount_percent']}%',
                  ),
                  Text(
                    'Status: ${row['approval_status']} • Weather: ${result['weather']['source']}',
                  ),
                  Text((result['reasons'] as List).join(', ')),
                  if (widget.action == 'RESTOCK')
                    RestockExplanation(
                      result: Map<String, dynamic>.from(result),
                    ),
                  if (widget.action == 'DISCOUNT' &&
                      result['discount_type'] != null) ...[
                    Text(
                      result['discount_type'] == 'CLEARANCE'
                          ? 'CLEARANCE DISCOUNT - sell before expiry'
                          : 'REGULAR DISCOUNT - cost floor protected',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Selling price: USD ${result['selling_price_usd']} | Lot cost reference: USD ${result['unit_cost_reference_usd']}',
                    ),
                    Text(
                      'Margin before other costs: USD ${result['unit_margin_before_other_costs_usd']} per unit',
                    ),
                    if (result['below_cost'] == true)
                      const Text(
                        'BELOW COST - explicit clearance approval required.',
                        style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                  if (result['inventory_method'] != null)
                    Text(
                      'Inventory: FEFO by batch. Usable on arrival: ${result['usable_inventory_at_arrival_units']} units.',
                    ),
                  if (widget.action == 'DISCOUNT' &&
                      result['discount_eligible_units'] != null)
                    Text(
                      'Markdown applies to ${row['discount_units_now'] ?? result['discount_eligible_units']} units in batches: ${(result['discount_batch_ids'] as List).join(', ')}',
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    children: [
                      FilledButton(
                        onPressed: _saving || provider.isSyncingBackend
                            ? null
                            : () => _decide(
                                provider,
                                row['recommendation_id'].toString(),
                                true,
                              ),
                        child: const Text('Approve'),
                      ),
                      OutlinedButton(
                        onPressed: _saving || provider.isSyncingBackend
                            ? null
                            : () => _decide(
                                provider,
                                row['recommendation_id'].toString(),
                                false,
                              ),
                        child: const Text('Reject'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}
