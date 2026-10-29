import 'dart:convert';
import '../../widgets/weather_merchandise.dart';
import 'package:flutter/material.dart';
import '../../widgets/restock_explanation.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../services/api_service.dart';

class DemandForecastPage extends StatefulWidget {
  const DemandForecastPage({super.key});
  @override
  State<DemandForecastPage> createState() => _DemandForecastPageState();
}

class _DemandForecastPageState extends State<DemandForecastPage> {
  String _scenario = 'normal';
  Future<void> _run(AppProvider provider) async {
    final ok = await provider.triggerBackendScenario(_scenario);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Forecast saved. ML output and recommendation source are shown below.'
              : provider.lastBackendError ?? 'Backend unavailable.',
        ),
      ),
    );
    if (ok && ApiService.demoMode) {
      try {
        await WeatherMerchandise.showRecommendation(
          context,
          provider.selectedStoreId,
        );
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Forecast saved; weather suggestion could not be loaded.',
              ),
            ),
          );
        }
      }
    }
  }

  Future<void> _checkCurrent(AppProvider provider) async {
    final store = provider.selectedStoreId;
    try {
      final response = await ApiService.client
          .get(
            Uri.parse(
              '${ApiService.apiRoot}/api/v1/weather/current',
            ).replace(queryParameters: {'store_id': store}),
            headers: ApiService.requestHeaders,
          )
          .timeout(const Duration(seconds: 40));
      final value = jsonDecode(response.body);
      if (response.statusCode != 200) {
        throw Exception(value['detail'] ?? 'Weather unavailable');
      }
      if (!mounted || provider.selectedStoreId != store) return;
      final weather = value['weather'];
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Live weather - ${value['branch']['name']}'),
          content: SelectableText(
            '${weather['condition']} | ${weather['temperature_c']} C\nWeather date: ${weather['target_date']}\nSource: ${weather['source']}\nFetched: ${weather['fetched_at']}\nCurrent observation, separate from the demand forecast date.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final rows = provider.backendRecommendations;
    final total = rows.fold<double>(
      0,
      (value, row) =>
          value +
          (row['prediction']['predicted_demand_units'] as num).toDouble(),
    );
    final maxDemand = rows.fold<double>(1, (value, row) {
      final demand = (row['prediction']['predicted_demand_units'] as num)
          .toDouble();
      return demand > value ? demand : value;
    });
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const WeatherMerchandise(),
        Text(
          'Next-day demand forecast',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const Text(
          'Daily baseline demand before markdown. Campaign plans are model inputs; weather informs the replenishment buffer.',
        ),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${provider.selectedStoreId} • Target ${ApiService.defaultDate}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Wrap(
                  spacing: 16,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilterChip(
                      label: const Text('Planned campaign'),
                      selected: ApiService.plannedPromotion == 1,
                      onSelected: provider.isSyncingBackend
                          ? null
                          : (v) => setState(
                              () => ApiService.plannedPromotion = v ? 1 : 0,
                            ),
                    ),
                    FilterChip(
                      label: const Text('Holiday'),
                      selected: ApiService.holiday == 1,
                      onSelected: provider.isSyncingBackend
                          ? null
                          : (v) =>
                                setState(() => ApiService.holiday = v ? 1 : 0),
                    ),
                    DropdownButton<String>(
                      value: ApiService.weatherMode,
                      items: const [
                        DropdownMenuItem(
                          value: 'mock',
                          child: Text('Mock weather'),
                        ),
                        DropdownMenuItem(
                          value: 'live',
                          child: Text('OpenWeather live'),
                        ),
                      ],
                      key: const ValueKey('weather-source-selector'),
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => ApiService.weatherMode = v);
                        }
                      },
                    ),
                    if (ApiService.weatherMode == 'mock')
                      DropdownButton<String>(
                        value: _scenario,
                        items: ['normal', 'rainy', 'hot', 'hot_rainy']
                            .map(
                              (s) => DropdownMenuItem(value: s, child: Text(s)),
                            )
                            .toList(),
                        onChanged: provider.isSyncingBackend
                            ? null
                            : (v) => setState(() => _scenario = v!),
                      ),
                  ],
                ),
                if (ApiService.weatherMode == 'live') ...[
                  const Text(
                    'Location is selected automatically from the store. API key stays on the backend.',
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.cloud_outlined),
                    label: const Text('Check live weather now'),
                    onPressed: provider.isSyncingBackend
                        ? null
                        : () => _checkCurrent(provider),
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed:
                      !provider.isBackendOnline || provider.isSyncingBackend
                      ? null
                      : () => _run(provider),
                  icon: const Icon(Icons.auto_graph),
                  label: Text(
                    provider.isSyncingBackend
                        ? 'Calculating…'
                        : 'Run model & recommendations',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (rows.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No valid forecast for this store/date. Connect the backend and run the model. A receipt invalidates the affected recommendation until recalculated.',
              ),
            ),
          )
        else ...[
          Text(
            '${rows.length} product forecasts • ${total.toStringAsFixed(1)} units total',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          SelectableText('Model SHA256: ${rows.first['model_version']}'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Weather source: ${rows.first['result']['weather']['source']}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Date: ${rows.first['result']['weather']['target_date']} | ${rows.first['result']['weather']['condition']} | ${rows.first['result']['weather']['temperature_c']} C',
                  ),
                  Text(
                    'Rain probability: ${((rows.first['result']['weather']['rain_probability'] as num) * 100).toStringAsFixed(0)}%',
                  ),
                  SelectableText(
                    'Fetched at: ${rows.first['result']['weather']['fetched_at']} | Samples: ${rows.first['result']['weather']['sample_count']}',
                  ),
                ],
              ),
            ),
          ),
          Text(
            'Prediction: ML • Weather: ${rows.first['result']['weather']['source']} • Stock: ${rows.first['inventory_source']}',
          ),
          const SizedBox(height: 12),
          ...rows.map((row) {
            final prediction =
                (row['prediction']['predicted_demand_units'] as num).toDouble();
            final snapshot = row['input_payload']['snapshot'];
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${row['product_id']} — ${snapshot['product_name']}',
                          ),
                        ),
                        Text(
                          '${prediction.toStringAsFixed(2)} units',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: prediction / maxDemand,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Stock: ${snapshot['opening_inventory_units']} • Restock: ${row['result']['restock_quantity_units']} • ${row['sale_eligible_now'] == true ? "Markdown: ${row['result']['discount_percent']}%" : "Not offered for sale now (historical / expired / unavailable)"}',
                    ),
                    RestockExplanation(
                      result: Map<String, dynamic>.from(row['result']),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
        const SizedBox(height: 16),
        const Text(
          'Reference evaluation on synthetic data: MAE 4.4781 units; RMSE 6.0225; WMAPE 27.8883%. These are historical evaluation results, not accuracy for the forecasts shown above.',
        ),
      ],
    );
  }
}
