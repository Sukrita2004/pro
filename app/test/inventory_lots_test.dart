import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:freshflow/providers/app_provider.dart';
import 'package:freshflow/widgets/inventory_lots.dart';

void main() {
  testWidgets('Batch instructions identify expired stock and the correct selling order', (tester) async {
    final provider=AppProvider(connectOnStart:false);
    addTearDown(provider.dispose);
    provider.backendInventory=[{
      'snapshot_date':'2026-10-29','product_id':'PROD_001','product_name':'Apples',
      'lots':[
        {'lot_key':'new','batch_id':'NEW','expiry_date':'2026-10-30','units':5,'source':'RECORDED_RECEIPT'},
        {'lot_key':'expired','batch_id':'EXPIRED','expiry_date':'2026-10-28','units':3,'source':'LEGACY_ESTIMATED_OPENING'},
        {'lot_key':'old','batch_id':'OLD','expiry_date':'2026-10-29','units':28,'source':'LEGACY_ESTIMATED_OPENING'},
      ],
    }];
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: InventoryLots())),
        ),
      ),
    );
    await tester.tap(find.text('Which batch should staff sell first?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PROD_001 - Apples'));
    await tester.pumpAndSettle();
    expect(find.text('SELL THESE 28 UNITS FIRST'),findsOneWidget);
    expect(find.text('SELL AFTER BATCH OLD'),findsOneWidget);
    expect(find.text('DO NOT SELL - EXPIRED'),findsOneWidget);
    expect(tester.takeException(),isNull);
  });
}
