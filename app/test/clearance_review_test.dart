import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:freshflow/providers/app_provider.dart';
import 'package:freshflow/services/api_service.dart';
import 'package:freshflow/pages/manager/recommendation_review_page.dart';

void main() {
  testWidgets('Below-cost clearance needs a second confirmation before sending approval', (tester) async {
    final oldClient=ApiService.client;
    var writes=0;
    ApiService.client=MockClient((request) async {
      writes++;
      expect(jsonDecode(request.body)['acknowledge_below_cost'],true);
      return http.Response('{}',409); // Test the acknowledgement request without a full sync.
    });
    final provider=AppProvider(connectOnStart:false)..isBackendOnline=true;
    addTearDown(() {provider.dispose(); ApiService.client.close(); ApiService.client=oldClient;});
    provider.backendRecommendations=[{
      'recommendation_id':1,'product_id':'PROD_001','sale_eligible_now':true,
      'approval_status':'PROPOSED','actions':[{'action':'DISCOUNT'}],
      'prediction':{'predicted_demand_units':7.49},
      'input_payload':{'snapshot':{'product_name':'Apples','opening_inventory_units':33}},
      'result':{'discount_percent':50,'discount_type':'CLEARANCE','below_cost':true,
        'selling_price_usd':1.48,'unit_cost_reference_usd':2.31,
        'unit_margin_before_other_costs_usd':-.83,'weather':{'source':'mock'},'reasons':[]},
    }];
    await tester.pumpWidget(ChangeNotifierProvider.value(value:provider,
      child:const MaterialApp(home:Scaffold(body:RecommendationReviewPage(action:'DISCOUNT')))));
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(find.text('Approve below-cost clearance?'),findsOneWidget);
    expect(writes,0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(writes,0);
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve clearance'));
    await tester.pumpAndSettle();
    expect(writes,1);
  });
}
