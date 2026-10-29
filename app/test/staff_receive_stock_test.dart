import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:freshflow/providers/app_provider.dart';
import 'package:freshflow/services/api_service.dart';
import 'package:freshflow/pages/staff/staff_inventory_page.dart';
import 'package:freshflow/pages/staff/daily_entry_page.dart';

void main() {
  for (final demo in [false, true]) {
    testWidgets(
      'Receiving stock opens the selected product without a false success or stock mutation: demo=$demo',
      (tester) async {
        final previous = ApiService.demoMode;
        ApiService.demoMode = demo;
        final p = AppProvider(connectOnStart: false)..isBackendOnline = true;
        p.aisles = [
          {
            'id': 'SNAP-1',
            'productId': 'PROD_002',
            'label': 'Bananas 1kg',
            'stock': 19,
            'maxStock': 40,
            'status': 'normal',
          },
        ];
        addTearDown(() {
          p.dispose();
          ApiService.demoMode = previous;
        });
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: p,
            child: const MaterialApp(
              home: Scaffold(body: StaffInventoryPage()),
            ),
          ),
        );
        await tester.tap(find.text('Receive stock'));
        await tester.pumpAndSettle();
        expect(find.byType(DailyEntryPage), findsOneWidget);
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                find.byType(DropdownButtonFormField<String>).first,
              )
              .initialValue,
          'PROD_002',
        );
        expect(p.aisles.single['stock'], 19);
        expect(find.byType(SnackBar), findsNothing);
        expect(find.text('Save to database'), findsOneWidget);
      },
    );
  }
}
