import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:freshflow/providers/app_provider.dart';
import 'package:freshflow/services/api_service.dart';
import 'package:freshflow/pages/manager/recommendation_review_page.dart';

class QueueProvider extends AppProvider {
  final bool saves;
  QueueProvider(this.saves) : super(connectOnStart: false);
  @override
  Future<bool> approveRecommendation(
    String recId, {
    bool acknowledgeBelowCost = false,
  }) async {
    if (saves) {
      backendRecommendations.first['approval_status'] = 'APPROVED';
      notifyListeners();
    }
    return saves;
  }
}

void main() {
  for (final demo in [false, true]) {
    for (final saves in [false, true]) {
      testWidgets(
        'Approved discount leaves queue only after saving: demo=$demo saves=$saves',
        (tester) async {
          final previous = ApiService.demoMode;
          ApiService.demoMode = demo;
          final provider = QueueProvider(saves)..isBackendOnline = true;
          addTearDown(() {
            provider.dispose();
            ApiService.demoMode = previous;
          });
          provider.backendRecommendations = [
            {
              'recommendation_id': 1,
              'product_id': 'PROD_001',
              'sale_eligible_now': true,
              'approval_status': 'PROPOSED',
              'actions': [
                {'action': 'DISCOUNT'},
              ],
              'prediction': {'predicted_demand_units': 7.49},
              'input_payload': {
                'snapshot': {
                  'product_name': 'Apples',
                  'opening_inventory_units': 33,
                },
              },
              'result': {
                'discount_percent': 20,
                'discount_type': 'REGULAR',
                'below_cost': false,
                'selling_price_usd': 2.37,
                'unit_cost_reference_usd': 2.31,
                'unit_margin_before_other_costs_usd': .06,
                'weather': {'source': 'mock'},
                'reasons': [],
              },
            },
          ];
          await tester.pumpWidget(
            ChangeNotifierProvider<AppProvider>.value(
              value: provider,
              child: const MaterialApp(
                home: Scaffold(
                  body: RecommendationReviewPage(action: 'DISCOUNT'),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Approve'));
          await tester.pumpAndSettle();
          expect(find.text('Approve'), saves ? findsNothing : findsOneWidget);
          expect(
            provider.backendRecommendations.length,
            1,
          ); // Saved history is retained.
          if (saves) {
            expect(
              find.text('No discounts awaiting approval for this selection.'),
              findsOneWidget,
            );
          }
        },
      );
    }
  }
}
