import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../data/store_catalog.dart';

/// One announcement per store/date/forecast during this application session.
class CustomerRainPopup extends StatefulWidget {
  const CustomerRainPopup({super.key});
  @override
  State<CustomerRainPopup> createState() => _CustomerRainPopupState();
}

class _CustomerRainPopupState extends State<CustomerRainPopup> {
  static final Set<String> _seen = {};
  String? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.watch<AppProvider>();
    final run = provider.backendRecommendations.firstOrNull?['run_id'];
    final scope =
        '${ApiService.demoMode}/${provider.selectedStoreId}/${ApiService.defaultDate}/$run/${provider.isSyncingBackend}/${provider.isBackendOnline}';
    if (_scope == scope) return;
    _scope = scope;
    if (!ApiService.demoMode ||
        !provider.isBackendOnline ||
        provider.isSyncingBackend) {
      return;
    }
    final store = provider.selectedStoreId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _check(store, scope));
  }

  Future<void> _check(String store, String scope) async {
    if (!mounted || _scope != scope) return;
    try {
      final response = await ApiService.client
          .get(
            Uri.parse(
              '${ApiService.apiRoot}/api/v1/weather-merchandise',
            ).replace(queryParameters: {'store_id': store}),
            headers: ApiService.requestHeaders,
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 || !mounted || _scope != scope) return;
      final value = jsonDecode(response.body) as Map<String, dynamic>;
      final items = (value['items'] as List)
          .where((item) => (item['stock_units'] as num) > 0)
          .toList();
      final key = '$store/${value['business_date']}/${value['run_id']}';
      if (value['rainy'] != true || items.isEmpty || !_seen.add(key)) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.umbrella_rounded,
                      size: 86,
                      color: Color(0xFF15803D),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'RAINING OUTSIDE?',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Umbrellas available right here!',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF15803D),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Stay dry! Pick up an umbrella or raincoat before heading out.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      storeName(store),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    for (final item in items)
                      Text(
                        '${item['name']} • USD ${(item['adjusted_price_usd'] as num).toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 18, height: 1.7),
                      ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: const Icon(Icons.check),
                        label: const Text('Got it — keep browsing'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    } catch (_) {
      // Optional marketing must never prevent browsing the food deals.
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
