import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../services/api_service.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  String _source = 'application', _type = 'sales';
  String? _month, _scope, _error;
  List<String> _months = [];
  List<Map<String, dynamic>> _items = [];
  int _offset = 0, _total = 0, _generation = 0;
  bool _loading = false;
  static const _types = {
    'sales': 'Daily sales',
    'receipts': 'Stock receipts',
    'daily_closures': 'Daily closures',
    'forecast_runs': 'Forecast runs',
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = context.watch<AppProvider>().selectedStoreId;
    final scope = '$store/${ApiService.demoMode}';
    if (_scope != scope) {
      _scope = scope;
      _loadMonths();
    }
  }

  Future<void> _loadMonths() async {
    final generation = ++_generation;
    final store = context.read<AppProvider>().selectedStoreId;
    setState(() {
      _loading = true;
      _error = null;
      _items = [];
      _offset = 0;
      _total = 0;
      _month = null;
      _months = [];
    });
    try {
      final months = await ApiService.getHistoryMonths(_source, _type, store);
      if (!mounted || generation != _generation) return;
      setState(() {
        _months = months;
        _month = months.isEmpty ? null : months.first;
      });
      if (_month != null) await _loadRecords();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadRecords() async {
    if (_month == null) return;
    final generation = _generation;
    final store = context.read<AppProvider>().selectedStoreId;
    setState(() {
      _loading = true;
      _error = null;
      _items = [];
    });
    try {
      final value = await ApiService.getHistory(
        _source,
        _type,
        _month!,
        store,
        _offset,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = List<Map<String, dynamic>>.from(value['items']);
        _total = value['total'] as int;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppProvider>().selectedStoreId;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'History — $store',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        const Text(
          'Training data: inventory_management_ref.csv (synthetic, 2025). '
          'Application sales history: external synthetic data (2026). Initial application stock is mock. '
          'Receipts and closures entered later retain their own source.',
        ),
        if (ApiService.demoMode)
          const Text(
            'DEMO DATABASE — these application records are isolated test records.',
            style: TextStyle(
              color: Colors.deepOrange,
              fontWeight: FontWeight.bold,
            ),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 20,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<String>(
              value: _source,
              items: const [
                DropdownMenuItem(
                  value: 'application',
                  child: Text('Application records'),
                ),
                DropdownMenuItem(
                  value: 'training',
                  child: Text('Training dataset (2025)'),
                ),
              ],
              onChanged: _loading
                  ? null
                  : (v) {
                      setState(() {
                        _source = v!;
                        if (_source == 'training') _type = 'sales';
                      });
                      _loadMonths();
                    },
            ),
            DropdownButton<String>(
              value: _type,
              items: _types.entries
                  .where(
                    (entry) => _source != 'training' || entry.key == 'sales',
                  )
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
              onChanged: _loading
                  ? null
                  : (v) {
                      setState(() => _type = v!);
                      _loadMonths();
                    },
            ),
            DropdownButton<String>(
              value: _month,
              hint: const Text('Select month'),
              items: _months
                  .map(
                    (month) =>
                        DropdownMenuItem(value: month, child: Text(month)),
                  )
                  .toList(),
              onChanged: _loading
                  ? null
                  : (v) {
                      setState(() {
                        _month = v;
                        _offset = 0;
                      });
                      _loadRecords();
                    },
            ),
            IconButton(
              onPressed: _loading ? null : _loadMonths,
              icon: const Icon(Icons.refresh),
              tooltip: 'Reload history',
            ),
          ],
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          SelectableText(_error!, style: const TextStyle(color: Colors.red)),
        if (!_loading && _items.isEmpty && _error == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No records for this selection. Nothing is fabricated for missing months.',
            ),
          ),
        if (_items.isNotEmpty) ...[
          Text(
            '$_total records • showing ${_offset + 1}–${_offset + _items.length}',
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Business date')),
                DataColumn(label: Text('Product / run')),
                DataColumn(label: Text('Units / products')),
                DataColumn(label: Text('Waste units')),
                DataColumn(label: Text('Closing units')),
              ],
              rows: _items
                  .map(
                    (item) => DataRow(
                      cells: [
                        DataCell(
                          Text(
                            '${item['date'] ?? item['received_date'] ?? item['snapshot_date']}',
                          ),
                        ),
                        DataCell(
                          Text(
                            '${item['product_name'] ?? "Run #${item['run_id']}"}',
                          ),
                        ),
                        DataCell(
                          Text(
                            '${item['actual_sales_units'] ?? item['quantity'] ?? item['product_count'] ?? "—"}',
                          ),
                        ),
                        DataCell(Text('${item['units_wasted'] ?? "-"}')),
                        DataCell(
                          Text('${item['closing_inventory_units'] ?? "-"}'),
                        ),
                      ],
                    ),
                  )
                  .toList(),
            ),
          ),
          Row(
            children: [
              TextButton(
                onPressed: _loading || _offset == 0
                    ? null
                    : () {
                        setState(() => _offset -= 50);
                        _loadRecords();
                      },
                child: const Text('Previous'),
              ),
              TextButton(
                onPressed: _loading || _offset + _items.length >= _total
                    ? null
                    : () {
                        setState(() => _offset += 50);
                        _loadRecords();
                      },
                child: const Text('Next'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
