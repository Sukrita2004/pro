import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Central Service for communicating with FreshFlow FastAPI Backend
class ApiService {
  // Base configuration
  // For Web & Desktop: http://127.0.0.1:8000
  // For Android Emulator: http://10.0.2.2:8000
  static String baseUrl = 'http://127.0.0.1:8000';

  // API key header (Default local admin key for demo)
  static String apiKey = 'your_local_admin_key';

  // Demo snapshot date & store configured in backend seed-demo
  static String demoDate = '2026-10-12';
  static String demoSessionDate = '';
  static bool demoAutomaticCalendar = false;
  static String defaultDate = '2026-10-12';
  static String defaultStoreId = 'STORE_01';
  static bool demoMode = false;
  static http.Client client = http.Client();
  static String? _normalAccessToken;
  static String? _demoAccessToken;
  static String? get accessToken =>
      demoMode ? _demoAccessToken : _normalAccessToken;
  static set accessToken(String? value) {
    if (demoMode) {
      _demoAccessToken = value;
    } else {
      _normalAccessToken = value;
    }
  }

  static Map<String, String> get requestHeaders => _headers;
  static String get apiRoot => demoMode ? '$baseUrl/demo' : baseUrl;
  static int plannedPromotion = 0;
  static int holiday = 0;
  static String weatherMode = 'mock';
  static double? latitude;
  static double? longitude;

  static Map<String, String> get _headers => _headersFor(demoMode);
  static Map<String, String> _headersFor(bool demo) => {
    'Content-Type': 'application/json',
    'X-API-Key': apiKey,
    if ((demo ? _demoAccessToken : _normalAccessToken) != null)
      'Authorization': 'Bearer ${demo ? _demoAccessToken : _normalAccessToken}',
  };

  static Future<dynamic> accountRequest(
    String method,
    String path, [
    Map<String, dynamic>? body,
    bool? demo,
  ]) async {
    final targetDemo = demo ?? demoMode;
    final uri = Uri.parse('$baseUrl${targetDemo ? '/demo' : ''}/api/v1/$path');
    final request = http.Request(method, uri)
      ..headers.addAll(_headersFor(targetDemo));
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await client.send(request).timeout(const Duration(seconds: 60)),
    );
    final value = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode >= 400) {
      throw Exception(
        value is Map && value['detail'] is String
            ? value['detail']
            : 'Request could not be completed (${response.statusCode}).',
      );
    }
    return value;
  }

  /// 1. Health check â€” Verify connection with FastAPI server
  static Future<bool> checkHealth() async {
    try {
      final uri = Uri.parse('$apiRoot/health');
      final res = await client.get(uri).timeout(const Duration(seconds: 10));
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[ApiService] Health check failed: $e');
      return false;
    }
  }

  /// 2. Get Inventory Snapshots
  static Future<List<Map<String, dynamic>>> getInventory({
    String? date,
    String? storeId,
    int? maxDays,
    bool inStockOnly = false,
    int limit = 200,
  }) async {
    final queryParams = <String, String>{
      'date': date ?? defaultDate,
      'limit': limit.toString(),
      if (inStockOnly) 'in_stock_only': 'true',
    };
    queryParams['store_id'] = storeId ?? defaultStoreId;
    if (maxDays != null) queryParams['max_days'] = maxDays.toString();

    final uri = Uri.parse(
      '$apiRoot/api/v1/inventory',
    ).replace(queryParameters: queryParams);
    final res = await client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 5));

    if (res.statusCode == 200) {
      final dynamic data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is List) {
        return List<Map<String, dynamic>>.from(data);
      } else if (data is Map && data['items'] is List) {
        return List<Map<String, dynamic>>.from(data['items']);
      }
      return [];
    }
    throw Exception(
      'Failed to load inventory (${res.statusCode}): ${res.body}',
    );
  }

  /// 3. Get Dashboard Summary
  static Future<Map<String, dynamic>> getDashboardSummary({
    String? date,
    String? storeId,
  }) async {
    final queryParams = <String, String>{
      'date': date ?? defaultDate,
      'store_id': storeId ?? defaultStoreId,
    };

    final uri = Uri.parse(
      '$apiRoot/api/v1/dashboard/summary',
    ).replace(queryParameters: queryParams);
    final res = await client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 5));

    if (res.statusCode == 200) {
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
    }
    throw Exception(
      'Failed to load dashboard summary (${res.statusCode}): ${res.body}',
    );
  }

  /// 4. Get Recommendations (Pricing & Restock proposals)
  static Future<List<Map<String, dynamic>>> getRecommendations({
    String? date,
    String? storeId,
  }) async {
    final queryParams = <String, String>{
      'date': date ?? defaultDate,
      'store_id': storeId ?? defaultStoreId,
    };

    final uri = Uri.parse(
      '$apiRoot/api/v1/recommendations',
    ).replace(queryParameters: queryParams);
    final res = await client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 5));

    if (res.statusCode == 200) {
      final dynamic data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is List) {
        return List<Map<String, dynamic>>.from(data);
      } else if (data is Map && data['items'] is List) {
        return List<Map<String, dynamic>>.from(data['items']);
      }
      return [];
    }
    throw Exception(
      'Failed to load recommendations (${res.statusCode}): ${res.body}',
    );
  }

  /// 5. Trigger new Recommendation Run (e.g. for rain or clear scenario)
  static Future<Map<String, dynamic>> createRecommendationRun({
    required String scenarioId,
    String? date,
    String? storeId,
  }) async {
    final uri = Uri.parse('$apiRoot/api/v1/recommendation-runs');
    final payload = {
      'request_id': 'run-${DateTime.now().millisecondsSinceEpoch}',
      'snapshot_date': date ?? defaultDate,
      'store_id': storeId ?? defaultStoreId,
      'scenario_id': scenarioId, // 'clear-demo' or 'rain-demo'
      'rule_version': 'generator-aligned-v2',
      'prediction_source': 'ML',
      'holiday': holiday,
      'planned_promotion': plannedPromotion,
      'weather_mode': weatherMode,
    };

    final res = await client
        .post(uri, headers: _headers, body: jsonEncode(payload))
        .timeout(const Duration(seconds: 60));

    if (res.statusCode == 200 || res.statusCode == 201) {
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
    }
    throw Exception(
      'Failed to run recommendation (${res.statusCode}): ${res.body}',
    );
  }

  /// 6. Approve or Reject Recommendation
  static Future<bool> updateRecommendationStatus({
    required String recommendationId,
    required String status, // 'APPROVED' or 'REJECTED'
    bool acknowledgeBelowCost = false,
  }) async {
    final uri = Uri.parse(
      '$apiRoot/api/v1/recommendations/$recommendationId/status',
    );
    final res = await client
        .patch(
          uri,
          headers: _headers,
          body: jsonEncode({
            'status': status,
            'acknowledge_below_cost': acknowledgeBelowCost,
          }),
        )
        .timeout(const Duration(seconds: 5));

    return res.statusCode == 200;
  }

  /// 7. Get Customer Deals (Public endpoint)
  static Future<List<Map<String, dynamic>>> getDeals({String? date}) async {
    final queryParams = <String, String>{
      'date': date ?? defaultDate,
      'store_id': defaultStoreId,
    };

    final uri = Uri.parse(
      '$apiRoot/api/v1/deals',
    ).replace(queryParameters: queryParams);
    final res = await client.get(uri).timeout(const Duration(seconds: 5));

    if (res.statusCode == 200) {
      final dynamic data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is List) {
        return List<Map<String, dynamic>>.from(data);
      } else if (data is Map && data['items'] is List) {
        return List<Map<String, dynamic>>.from(data['items']);
      }
      return [];
    }
    throw Exception('Failed to load deals (${res.statusCode}): ${res.body}');
  }

  /// 8. Get Stores
  static Future<List<Map<String, dynamic>>> getStores() async {
    final uri = Uri.parse('$apiRoot/api/v1/stores');
    final res = await client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 5));

    if (res.statusCode == 200) {
      final dynamic data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is List) {
        return List<Map<String, dynamic>>.from(data);
      }
      return [];
    }
    throw Exception('Failed to load stores (${res.statusCode})');
  }

  /// 9. Get Notifications
  static Future<List<Map<String, dynamic>>> getNotifications() async {
    final uri = Uri.parse('$apiRoot/api/v1/notifications');
    final res = await client
        .get(
          uri.replace(
            queryParameters: {'date': defaultDate, 'store_id': defaultStoreId},
          ),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 5));

    if (res.statusCode == 200) {
      final dynamic data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is List) {
        return List<Map<String, dynamic>>.from(data);
      } else if (data is Map && data['items'] is List) {
        return List<Map<String, dynamic>>.from(data['items']);
      }
      return [];
    }
    throw Exception('Failed to load notifications (${res.statusCode})');
  }

  /// 10. Mark Notification as read
  static Future<Map<String, dynamic>> setupDealDemo() async {
    final response = await client
        .post(Uri.parse('$baseUrl/api/v1/demo/setup'), headers: _headers)
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw Exception('Demo setup failed: ${response.body}');
    }
    return Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)),
    );
  }

  static Future<Map<String, dynamic>> demoDayAction(
    String action,
    String store,
  ) async {
    final uri = Uri.parse('$baseUrl/demo/api/v1/demo/$action');
    final response = action == 'day'
        ? await client
              .get(
                uri.replace(queryParameters: {'store_id': store}),
                headers: _headers,
              )
              .timeout(const Duration(seconds: 60))
        : await client
              .post(
                uri,
                headers: _headers,
                body: jsonEncode({'store_id': store, 'date': defaultDate}),
              )
              .timeout(const Duration(seconds: 60));
    final value = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)),
    );
    if (response.statusCode != 200) {
      throw Exception(value['detail'] ?? 'Demo action failed');
    }
    return value;
  }

  static Future<dynamic> _getRecordJson(
    String path,
    Map<String, String> parameters,
  ) async {
    final uri = Uri.parse(
      '$apiRoot/api/v1/$path',
    ).replace(queryParameters: parameters);
    final response = await client
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('History fetch failed: ${response.body}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  static Future<List<String>> getHistoryMonths(
    String source,
    String type,
    String store,
  ) async {
    final value = await _getRecordJson('history/months', {
      'source': source,
      'record_type': type,
      'store_id': store,
    });
    return List<String>.from(value as List);
  }

  static Future<Map<String, dynamic>> getHistory(
    String source,
    String type,
    String month,
    String store,
    int offset,
  ) async {
    final value = await _getRecordJson('history', {
      'source': source,
      'record_type': type,
      'month': month,
      'store_id': store,
      'limit': '50',
      'offset': '$offset',
    });
    return Map<String, dynamic>.from(value as Map);
  }

  static Future<Map<String, dynamic>> getHistoricalRun(
    int runId,
    String store,
  ) async {
    final value = await _getRecordJson('history/runs/$runId', {
      'store_id': store,
    });
    return Map<String, dynamic>.from(value as Map);
  }

  static Future<bool> markNotificationRead(String id) async {
    final uri = Uri.parse('$apiRoot/api/v1/notifications/$id/read');
    final res = await client
        .patch(uri, headers: _headers)
        .timeout(const Duration(seconds: 5));
    return res.statusCode == 200;
  }

  static Future<Map<String, dynamic>> receiveStock(
    Map<String, dynamic> payload,
  ) async {
    return _postInventory('receipts', payload);
  }

  static Future<Map<String, dynamic>> closeDay(
    Map<String, dynamic> payload,
  ) async {
    return _postInventory('daily-closures', payload);
  }

  static Future<Map<String, dynamic>> _postInventory(
    String resource,
    Map<String, dynamic> payload,
  ) async {
    final response = await client
        .post(
          Uri.parse('$apiRoot/api/v1/$resource'),
          headers: _headers,
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Save failed (${response.statusCode}): ${response.body}');
    }
    return Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)),
    );
  }
}
