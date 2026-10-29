import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:freshflow/providers/app_provider.dart';
import 'package:freshflow/services/api_service.dart';
import 'package:freshflow/pages/manager/history_page.dart';

void main() {
  testWidgets('History month dropdown reloads scoped records', (tester) async {
    final previous = ApiService.client;
    String? requestedMonth;
    ApiService.client = MockClient((request) async {
      if (request.url.path.endsWith('/months')) {
        return http.Response(jsonEncode(['2026-10', '2026-09']), 200);
      }
      requestedMonth = request.url.queryParameters['month'];
      expect(request.url.queryParameters['store_id'], 'STORE_01');
      return http.Response(
        jsonEncode({
          'total': 1,
          'items': [
            {
              'date': '$requestedMonth-01',
              'product_name': 'Apples 1kg',
              'actual_sales_units': 7,
              'source': 'SYNTHETIC_EXTERNAL_HISTORY',
            },
          ],
        }),
        200,
      );
    });
    addTearDown(() {
      ApiService.client.close();
      ApiService.client = previous;
    });
    final provider = AppProvider(connectOnStart: false);
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: HistoryPage())),
      ),
    );
    await tester.pumpAndSettle();
    expect(requestedMonth, '2026-10');
    expect(find.text('Apples 1kg'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String>).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2026-09').last);
    await tester.pumpAndSettle();
    expect(requestedMonth, '2026-09');
    expect(find.text('2026-09-01'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
