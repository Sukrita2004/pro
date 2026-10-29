import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:freshflow/providers/app_provider.dart';
import 'package:freshflow/services/api_service.dart';

void main() {
  test(
    'Demo signs in with its own session and enforces assigned branches',
    () async {
      final previous = ApiService.client;
      final previousMode = ApiService.demoMode;
      ApiService.demoMode = false;
      final normalToken = ApiService.accessToken;
      ApiService.accessToken = 'normal-test-session';
      ApiService.demoMode = true;
      ApiService.accessToken = null;
      ApiService.demoMode = false;
      final paths = <String>[];
      ApiService.client = MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/demo/api/v1/auth/login') {
          expect(request.headers['Authorization'], isNull);
          return http.Response(
            jsonEncode({
              'access_token': 'demo-test-session',
              'expires_at':
                  DateTime.now()
                      .add(const Duration(hours: 1))
                      .millisecondsSinceEpoch /
                  1000,
              'user': {
                'name': 'Demo Staff',
                'email': 'demo@example.test',
                'role': 'staff',
                'stores': ['STORE_03'],
                'active': 1,
              },
            }),
            200,
          );
        }
        if (request.url.path == '/api/v1/auth/me') {
          expect(
            request.headers['Authorization'],
            'Bearer normal-test-session',
          );
          return http.Response('{}', 200);
        }
        if (request.url.path.endsWith('/demo/day')) {
          return http.Response(
            jsonEncode({
              'business_date': '2026-10-12',
              'automatic_calendar': true,
              'session_started_date': '2026-10-12',
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/health') ||
            request.url.path.endsWith('/summary') ||
            request.url.path.endsWith('/auth/logout')) {
          return http.Response('{}', 200);
        }
        if (request.url.path.endsWith('/deals')) {
          return http.Response(
            '[]',
            200,
          ); // Public offers do not require a bearer token.
        }
        expect(request.headers['Authorization'], 'Bearer demo-test-session');
        return http.Response('[]', 200);
      });
      final p = AppProvider(connectOnStart: false);
      addTearDown(() {
        p.dispose();
        ApiService.client = previous;
        ApiService.demoMode = true;
        ApiService.accessToken = null;
        ApiService.demoMode = false;
        ApiService.accessToken = normalToken;
        ApiService.demoMode = previousMode;
        ApiService.defaultStoreId = 'STORE_01';
      });
      await p.signInAccount('login', {
        'email': 'demo@example.test',
        'password': 'demo-test-password',
      }, demo: true);
      expect(ApiService.demoMode, isTrue);
      expect(p.role, 'staff');
      expect(p.accessibleStoreIds, ['STORE_03']);
      expect(p.selectedStoreId, 'STORE_03');
      expect(p.syncFailures, isEmpty);
      await p.selectStore('STORE_02');
      expect(p.selectedStoreId, 'STORE_03');
      expect(paths, contains('/demo/api/v1/inventory'));
      await ApiService.accountRequest('GET', 'auth/me', null, false);
      p.setRole(null);
      await Future<void>.delayed(Duration.zero);
      expect(paths, contains('/demo/api/v1/auth/logout'));
      expect(ApiService.accessToken, isNull);
      ApiService.demoMode = false;
      expect(ApiService.accessToken, 'normal-test-session');
    },
  );
  test('Normal mode cannot select a role without server authentication', () {
    ApiService.demoMode = false;
    final p = AppProvider(connectOnStart: false);
    addTearDown(p.dispose);
    p.setRole('manager');
    expect(p.role, isNull);
    expect(p.currentUser, isNull);
  });

  test(
    'Server identity controls assigned branches and bearer authorization',
    () async {
      final previous = ApiService.client;
      final previousMode = ApiService.demoMode;
      ApiService.demoMode = false;
      final paths = <String>[];
      final tokens = <String?>[];
      ApiService.client = MockClient((request) async {
        paths.add(request.url.path);
        tokens.add(request.headers['Authorization']);
        if (request.url.path.endsWith('/auth/login')) {
          expect(jsonDecode(request.body)['email'], 'staff@example.test');
          return http.Response(
            jsonEncode({
              'access_token': 'test-session',
              'expires_at':
                  DateTime.now()
                      .add(const Duration(hours: 1))
                      .millisecondsSinceEpoch /
                  1000,
              'user': {
                'name': 'Staff',
                'email': 'staff@example.test',
                'role': 'staff',
                'stores': ['STORE_02'],
                'active': 1,
              },
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/health')) {
          return http.Response('{}', 200);
        }
        if (request.url.path.endsWith('/summary')) {
          return http.Response('{}', 200);
        }
        if (request.url.path.endsWith('/auth/logout')) {
          return http.Response('{}', 200);
        }
        return http.Response('[]', 200);
      });
      final p = AppProvider(connectOnStart: false);
      addTearDown(() {
        p.dispose();
        ApiService.client = previous;
        ApiService.accessToken = null;
        ApiService.demoMode = previousMode;
        ApiService.defaultStoreId = 'STORE_01';
      });
      await p.signInAccount('login', {
        'email': 'staff@example.test',
        'password': 'a-test-password',
      });
      expect(p.role, 'staff');
      expect(p.selectedStoreId, 'STORE_02');
      expect(p.accessibleStoreIds, ['STORE_02']);
      await p.selectStore('STORE_03');
      expect(p.selectedStoreId, 'STORE_02');
      final index = paths.indexOf('/api/v1/inventory');
      expect(index, greaterThanOrEqualTo(0));
      expect(tokens[index], 'Bearer test-session');
      p.setRole(null);
      await Future<void>.delayed(Duration.zero);
      expect(ApiService.accessToken, isNull);
      expect(p.role, isNull);
      expect(paths, contains('/api/v1/auth/logout'));
    },
  );
}
