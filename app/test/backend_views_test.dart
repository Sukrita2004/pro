import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:freshflow/providers/app_provider.dart';
import 'package:freshflow/pages/manager/demand_forecast_page.dart';
import 'package:freshflow/pages/manager/operational_dashboard.dart';
import 'package:freshflow/pages/staff/daily_entry_page.dart';
import 'package:freshflow/widgets/data_context_bar.dart';
import 'package:freshflow/services/api_service.dart';

Widget host(AppProvider provider, Widget page) => ChangeNotifierProvider.value(
  value: provider,
  child: MaterialApp(home: Scaffold(body: page)),
);

void main() {
  testWidgets(
    'Calendar demo explains automatic updates and hides manual day advance',
    (tester) async {
      final previousMode = ApiService.demoMode;
      final previousAuto = ApiService.demoAutomaticCalendar;
      ApiService.demoMode = true;
      ApiService.demoAutomaticCalendar = true;
      final provider = AppProvider(connectOnStart: false);
      addTearDown(() {
        provider.dispose();
        ApiService.demoMode = previousMode;
        ApiService.demoAutomaticCalendar = previousAuto;
      });
      await tester.pumpWidget(
        host(provider, OperationalDashboard(onNavigateTab: (_) {})),
      );
      expect(find.text('Automatic daily demo - Asia/Bangkok'), findsOneWidget);
      expect(find.text('Go to next demo day'), findsNothing);
      expect(find.text('Simulate remaining closures'), findsNothing);
    },
  );
  testWidgets('Demo next-day control requires all products closed', (
    tester,
  ) async {
    final previous = ApiService.demoMode;
    ApiService.demoMode = true;
    final provider = AppProvider(connectOnStart: false)..isBackendOnline = true;
    addTearDown(() {
      provider.dispose();
      ApiService.demoMode = previous;
    });
    provider.backendDashboardSummary = {
      'snapshot_count': 32,
      'closed_product_count': 1,
    };
    await tester.pumpWidget(
      host(provider, OperationalDashboard(onNavigateTab: (_) {})),
    );
    FilledButton nextButton() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Go to next demo day'),
    );
    await tester.scrollUntilVisible(
      find.text('Go to next demo day'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(nextButton().onPressed, isNull);
    provider.backendDashboardSummary = {
      'snapshot_count': 32,
      'closed_product_count': 32,
    };
    provider.notifyListeners();
    await tester.pump();
    expect(nextButton().onPressed, isNotNull);
    ApiService.demoMode = false;
    provider.notifyListeners();
    await tester.pump();
    expect(find.text('Go to next demo day'), findsNothing);
  });
  testWidgets(
    'Dashboard identifies partial daily totals and open-product coverage',
    (tester) async {
      final provider = AppProvider(connectOnStart: false);
      addTearDown(provider.dispose);
      provider.backendDashboardSummary = {
        'snapshot_count': 32,
        'closed_product_count': 1,
        'open_product_count': 31,
        'valid_forecast_count': 31,
        'missing_open_forecast_count': 0,
        'recorded_sales_units': 10,
        'recorded_waste_units': 2,
        'recorded_closing_units': 33,
      };
      await tester.pumpWidget(
        host(provider, OperationalDashboard(onNavigateTab: (_) {})),
      );
      for (final text in [
        'Forecast for unclosed products (31/31)',
        '10 units',
        '2 units',
        '33 units',
      ]) {
        await tester.scrollUntilVisible(
          find.text(text),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(text), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Demo weather selector stays clickable during synchronization', (
    tester,
  ) async {
    final previousMode = ApiService.demoMode;
    final previousWeather = ApiService.weatherMode;
    ApiService.demoMode = true;
    ApiService.weatherMode = 'mock';
    final provider = AppProvider(connectOnStart: false)
      ..isSyncingBackend = true;
    addTearDown(() {
      provider.dispose();
      ApiService.demoMode = previousMode;
      ApiService.weatherMode = previousWeather;
    });
    await tester.pumpWidget(host(provider, const DemandForecastPage()));
    await tester.tap(find.byKey(const ValueKey('weather-source-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenWeather live').last);
    await tester.pumpAndSettle();
    expect(ApiService.weatherMode, 'live');
    expect(find.text('Check live weather now'), findsOneWidget);
  });
  testWidgets('Store selector uses Navigator and replaces scope', (
    tester,
  ) async {
    final provider = AppProvider(connectOnStart: false);
    addTearDown(() async {
      await provider.selectStore('STORE_01');
      provider.dispose();
    });
    await tester.pumpWidget(host(provider, const DataContextBar()));
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FreshFlow Central Chidlom').last);
    await tester.pumpAndSettle();
    expect(provider.selectedStoreId, 'STORE_02');
    expect(provider.aisles.length, 32);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Dashboard fits a narrow viewport', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = AppProvider(connectOnStart: false);
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      host(provider, OperationalDashboard(onNavigateTab: (_) {})),
    );
    expect(find.text('Store overview'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Forecast displays the API prediction and its sources', (
    tester,
  ) async {
    final provider = AppProvider(connectOnStart: false);
    addTearDown(provider.dispose);
    provider.backendRecommendations = [
      {
        'product_id': 'PROD_001',
        'model_version': 'test-model-sha',
        'inventory_source': 'MOCK_INVENTORY',
        'prediction': {'predicted_demand_units': 7.1143},
        'input_payload': {
          'snapshot': {
            'product_name': 'Apples 1kg',
            'opening_inventory_units': 10,
          },
        },
        'result': {
          'weather': {
            'source': 'mock',
            'rain_probability': .1,
            'temperature_c': 28,
            'condition': 'CLEAR',
            'target_date': '2026-10-28',
            'fetched_at': '2026-10-28T00:00:00+00:00',
            'sample_count': 8,
          },
          'restock_quantity_units': 6,
          'discount_percent': 0,
        },
      },
    ];
    await tester.pumpWidget(host(provider, const DemandForecastPage()));
    await tester.scrollUntilVisible(
      find.text('7.11 units'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('7.11 units'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Staff entry requires backend before saving', (tester) async {
    final provider = AppProvider(connectOnStart: false);
    addTearDown(provider.dispose);
    await tester.pumpWidget(host(provider, const DailyEntryPage()));
    await tester.scrollUntilVisible(
      find.text('Save to database'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Save to database'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
