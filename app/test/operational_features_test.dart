import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:freshflow/providers/app_provider.dart';
import 'package:freshflow/services/api_service.dart';
import 'package:freshflow/widgets/daily_work_overview.dart';
import 'package:freshflow/widgets/restock_explanation.dart';
import 'package:freshflow/pages/customer/deal_detail_modal.dart';

Widget host(AppProvider p, Widget child) => ChangeNotifierProvider.value(
  value: p,
  child: MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  testWidgets(
    'Normal mode shows actionable data gaps and routes pending reviews',
    (tester) async {
      final oldMode = ApiService.demoMode;
      ApiService.demoMode = false;
      final p = AppProvider(connectOnStart: false)..isBackendOnline = true;
      addTearDown(() {
        p.dispose();
        ApiService.demoMode = oldMode;
      });
      p.backendDashboardSummary = {
        'previous_business_date': '2026-10-28',
        'previous_unclosed_product_count': 3,
        'latest_history_date': '2026-10-27',
        'missing_open_forecast_count': 2,
      };
      p.backendInventory = [
        {
          'product_id': 'PROD_001',
          'opening_inventory_units': 33,
          'days_to_expiry': 1,
          'snapshot_source': 'STAFF_RECEIPT',
        },
      ];
      p.backendRecommendations = [
        {
          'approval_status': 'PROPOSED',
          'sale_eligible_now': true,
          'actions': [
            {'action': 'DISCOUNT'},
          ],
          'result': {
            'weather': {'source': 'mock'},
          },
        },
      ];
      int? tab;
      await tester.pumpWidget(
        host(p, DailyWorkOverview(onNavigateTab: (v) => tab = v)),
      );
      expect(find.textContaining('3 products were not closed'), findsOneWidget);
      expect(
        find.textContaining('Complete missing daily records'),
        findsOneWidget,
      );
      expect(find.textContaining('use mock weather'), findsOneWidget);
      await tester.tap(find.text('Review pending discounts (1)'));
      expect(tab, 4);
      p.syncFailures = ['Inventory'];
      p.notifyListeners();
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(
                OutlinedButton,
                'Review pending discounts (1)',
              ),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'Saved policy explains usable stock instead of subtracting total stock',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RestockExplanation(
                result: {
                  'restock_quantity_units': 12,
                  'predicted_demand_units': 7.49,
                  'order_up_to_units': 16.478,
                  'usable_inventory_at_arrival_units': 5,
                  'new_batch_shelf_life_cap_units': 44,
                  'replenishment_explanation': {
                    'arrival_date': '2026-10-30',
                    'lead_time_days': 1,
                    'review_period_days': 1,
                    'buffer_units': 1.498,
                    'pending_order_units': 0,
                    'rounding': 'Round up, then cap.',
                  },
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Why this replenishment quantity?'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('remain usable at arrival: 5 units'),
        findsOneWidget,
      );
      expect(find.textContaining('Suggested order: 12 units'), findsOneWidget);
    },
  );

  testWidgets(
    'Customer saves an offer without a QR or reservation and withdrawal disables it',
    (tester) async {
      final oldMode = ApiService.demoMode;
      ApiService.demoMode = false;
      final p = AppProvider(connectOnStart: false)..isBackendOnline = true;
      addTearDown(() {
        p.dispose();
        ApiService.demoMode = oldMode;
      });
      final offer = <String, dynamic>{
        'id': 'offer-1',
        'status': 'active',
        'saleAllowed': true,
        'stock': 5,
        'expiryDate': '2099-12-31',
        'storeId': 'STORE_01',
        'demoMode': false,
        'finalPrice': 1.48,
        'originalPrice': 2.96,
        'discountPercent': 50,
        'productName': 'Apples',
      };
      p.discounts = [offer];
      await tester.pumpWidget(
        host(
          p,
          DealDetailModal(
            deal: offer,
            product: const {'name': 'Apples'},
            aisle: const {},
          ),
        ),
      );
      expect(find.textContaining('does not reserve stock'), findsOneWidget);
      expect(find.byIcon(Icons.qr_code_2), findsNothing);
      await tester.ensureVisible(find.text('Save offer for this session'));
      await tester.tap(find.text('Save offer for this session'));
      await tester.pump();
      expect(p.savedDealIds, contains('offer-1'));
      expect(p.claimedVouchers, isEmpty);
      p.discounts = [];
      p.notifyListeners();
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Remove saved offer'),
            )
            .onPressed,
        isNull,
      );
    },
  );
}
