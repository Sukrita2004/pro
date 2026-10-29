import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:freshflow/providers/app_provider.dart';
import 'package:freshflow/services/api_service.dart';
import 'package:freshflow/widgets/customer_rain_popup.dart';

void main() {
  for (final rainy in [false, true]) {
    testWidgets('Customer rain announcement rainy=$rainy', (tester) async {
      final previous = ApiService.client;
      final previousMode = ApiService.demoMode;
      ApiService.demoMode = true;
      ApiService.client = MockClient((request) async {
        expect(request.url.queryParameters['store_id'], 'STORE_01');
        return http.Response(jsonEncode({
          'rainy': rainy, 'run_id': rainy ? 902 : 901, 'business_date':'2026-10-28',
          'items':[{'name':'Umbrella','stock_units':18,'adjusted_price_usd':10.4}],
        }),200);
      });
      addTearDown(() { ApiService.client.close(); ApiService.client=previous; ApiService.demoMode=previousMode; });
      final provider = AppProvider(connectOnStart:false)..isBackendOnline=true;
      addTearDown(provider.dispose);
      await tester.pumpWidget(ChangeNotifierProvider.value(value:provider,
        child:const MaterialApp(home:Scaffold(body:CustomerRainPopup()))));
      await tester.pumpAndSettle();
      expect(find.text('Umbrellas available right here!'), rainy ? findsOneWidget : findsNothing);
      if (rainy) {
        expect(find.text('Umbrella • USD 10.40'),findsOneWidget);
        await tester.tap(find.text('Got it — keep browsing'));
        await tester.pumpAndSettle();
        provider.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.byType(Dialog),findsNothing);
      }
    });
  }
}
