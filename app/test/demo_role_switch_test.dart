import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:freshflow/providers/app_provider.dart';
import 'package:freshflow/services/api_service.dart';
import 'package:freshflow/widgets/data_context_bar.dart';

void main() {
  testWidgets(
    'Demo role menu uses the authorized endpoint and updates identity',
    (tester) async {
      final client = ApiService.client;
      final mode = ApiService.demoMode;
      ApiService.demoMode = true;
      final token = ApiService.accessToken;
      ApiService.accessToken = 'staff-session';
      final provider = AppProvider(connectOnStart: false);
      provider.role = 'staff';
      provider.currentUser = {
        'role': 'staff',
        'primary_role': 'staff',
        'available_roles': ['staff', 'customer'],
        'stores': ['STORE_01'],
      };
      var switches = 0;
      ApiService.client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/switch-role')) {
          switches++;
          expect(request.headers['Authorization'], 'Bearer staff-session');
          expect(jsonDecode(request.body), {'role': 'customer'});
          return http.Response(
            jsonEncode({
              'access_token': 'customer-session',
              'expires_at':
                  DateTime.now()
                      .add(const Duration(hours: 1))
                      .millisecondsSinceEpoch /
                  1000,
              'user': {
                'role': 'customer',
                'primary_role': 'staff',
                'available_roles': ['staff', 'customer'],
                'stores': ['STORE_01'],
              },
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/demo/day')) {
          return http.Response(
            jsonEncode({
              'business_date': '2026-10-12',
              'automatic_calendar': true,
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/health')) {
          return http.Response('{}', 200);
        }
        return http.Response('[]', 200);
      });
      var disposed = false;
      addTearDown(() {
        if (!disposed) {
          provider.dispose();
        }
        ApiService.client = client;
        ApiService.accessToken = token;
        ApiService.demoMode = mode;
      });
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: DataContextBar())),
        ),
      );
      await tester.tap(find.byTooltip('Switch Demo role'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use as customer'));
      await tester.pumpAndSettle();
      expect(switches, 1);
      expect(provider.role, 'customer');
      expect(provider.isAccountAdmin, false);
      expect(ApiService.accessToken, 'customer-session');
      await expectLater(provider.switchDemoRole('admin'), throwsStateError);
      ApiService.demoMode = false;
      await tester.pump();
      expect(provider.availableDemoRoles, isEmpty);
      await expectLater(provider.switchDemoRole('staff'), throwsStateError);
      await tester.pumpWidget(const SizedBox.shrink());
      provider.dispose();
      disposed = true;
    },
  );
}
