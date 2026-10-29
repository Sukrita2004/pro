import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../data/store_catalog.dart';

/// Non-food sandbox examples use transparent rules, never the food ML model.
class WeatherMerchandise extends StatelessWidget {
  const WeatherMerchandise({super.key});

  static Future<void> showRecommendation(
    BuildContext context,
    String store,
  ) async {
    if (!ApiService.demoMode) return;
    final value = await const WeatherMerchandise()._load(store);
    if (!context.mounted || (value['items'] as List).isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          '${storeName(store)}\n${value['rainy'] == true ? 'Rain essentials' : 'Sun protection'}',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final item in value['items'])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${item['name']} - USD ${(item['adjusted_price_usd'] as num).toStringAsFixed(2)}\nStock: ${item['stock_units']} | Price +${item['price_increase_percent']}%',
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<Map<String, dynamic>> _load(String store) async {
    final uri = Uri.parse(
      '${ApiService.apiRoot}/api/v1/weather-merchandise',
    ).replace(queryParameters: {'store_id': store});
    final response = await ApiService.client
        .get(uri, headers: ApiService.requestHeaders)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('Weather offers unavailable');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body));
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    if (!ApiService.demoMode || !provider.isBackendOnline) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<Map<String, dynamic>>(
      future: _load(provider.selectedStoreId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Text(
            'Weather essentials unavailable. Reconnect and retry.',
          );
        }
        if (!snapshot.hasData || (snapshot.data!['items'] as List).isEmpty) {
          return const SizedBox.shrink();
        }
        final value = snapshot.data!;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Weather essentials — DEMO',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  value['rainy'] == true
                      ? 'Rain: price adjustment +30%'
                      : 'Normal scenario: regular prices.',
                ),
                for (final item in value['items'])
                  ListTile(
                    leading: Icon(
                      item['name'] == 'Umbrella'
                          ? Icons.umbrella
                          : Icons.water_drop,
                    ),
                    title: Text(
                      '${item['name']} • ${item['stock_units']} in stock',
                    ),
                    subtitle: Text(
                      'USD ${(item['adjusted_price_usd'] as num).toStringAsFixed(2)} • Price +${item['price_increase_percent']}% • Suggested restock ${item['suggested_restock_units']}',
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
