import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/product_catalog.dart';
import '../../providers/app_provider.dart';
import '../../services/api_service.dart';

/// Staff enter business facts. Feature engineering remains on the server.
class DailyEntryPage extends StatefulWidget {
  final String? initialProductId;
  const DailyEntryPage({super.key, this.initialProductId});
  @override
  State<DailyEntryPage> createState() => _DailyEntryPageState();
}

class _DailyEntryPageState extends State<DailyEntryPage> {
  final _form = GlobalKey<FormState>();
  final _day = TextEditingController(text: ApiService.defaultDate);
  final _batch = TextEditingController();
  final _expiry = TextEditingController();
  final _quantity = TextEditingController();
  final _cost = TextEditingController();
  final _waste = TextEditingController(text: '0');
  final _closing = TextEditingController();
  final _discount = TextEditingController(text: '0');
  String _product = 'PROD_001';
  bool _close = false,
      _saving = false,
      _stockout = false,
      _promotion = false,
      _holiday = false;
  String? _message, _requestId, _lastPayload;

  @override
  void initState() {
    super.initState();
    if (trainingProducts.any((p) => p['id'] == widget.initialProductId)) {
      _product = widget.initialProductId!;
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _day,
      _batch,
      _expiry,
      _quantity,
      _cost,
      _waste,
      _closing,
      _discount,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    bool integer = false,
    bool decimal = false,
    bool date = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        keyboardType: integer || decimal
            ? TextInputType.number
            : TextInputType.text,
        validator: (value) {
          final text = value?.trim() ?? '';
          if (text.isEmpty) return 'Required';
          if (integer && (int.tryParse(text) == null || int.parse(text) < 0)) {
            return 'Enter a nonnegative whole number';
          }
          final number = double.tryParse(text);
          if (decimal && (number == null || !number.isFinite || number < 0)) {
            return 'Enter a nonnegative number';
          }
          if (date) {
            final parsed = DateTime.tryParse(text);
            if (parsed == null ||
                parsed.toIso8601String().substring(0, 10) != text) {
              return 'Use YYYY-MM-DD';
            }
          }
          return null;
        },
      ),
    );
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final provider = context.read<AppProvider>();
    final payload = <String, dynamic>{
      'store_id': provider.selectedStoreId,
      'product_id': _product,
    };
    if (_close) {
      payload.addAll({
        'date': _day.text.trim(),
        'actual_sales_units': int.parse(_quantity.text),
        'units_wasted': int.parse(_waste.text),
        'closing_inventory_units': int.parse(_closing.text),
        'out_of_stock_flag': _stockout ? 1 : 0,
        'promotion_active': _promotion ? 1 : 0,
        'is_holiday': _holiday ? 1 : 0,
        'applied_discount_percent': double.parse(_discount.text),
      });
    } else {
      payload.addAll({
        'received_date': _day.text.trim(),
        'batch_id': _batch.text.trim(),
        'expiry_date': _expiry.text.trim(),
        'quantity': int.parse(_quantity.text),
        'cost_price_usd': double.parse(_cost.text),
      });
    }
    final signature = jsonEncode(payload);
    if (signature != _lastPayload) {
      _requestId = 'staff-${DateTime.now().microsecondsSinceEpoch}';
      _lastPayload = signature;
    }
    payload['request_id'] = _requestId;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final response = _close
          ? await ApiService.closeDay(payload)
          : await ApiService.receiveStock(payload);
      await provider.syncWithBackend();
      if (!mounted) return;
      setState(() {
        _message =
            'Saved to database: ${response['status']}. Inventory recommendations must be regenerated after a change.';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = error.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Daily inventory entry — ${provider.selectedStoreId}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        const Text(
          'Receive deliveries by batch, then close each product after the trading day. '
          'The server creates historical features; never enter predicted or baseline demand as actual sales.',
        ),
        const SizedBox(height: 16),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: false,
              label: Text('Receive stock'),
              icon: Icon(Icons.add_box_outlined),
            ),
            ButtonSegment(
              value: true,
              label: Text('Close day'),
              icon: Icon(Icons.fact_check_outlined),
            ),
          ],
          selected: {_close},
          onSelectionChanged: _saving
              ? null
              : (values) => setState(() {
                  _close = values.first;
                  _message = null;
                }),
        ),
        const SizedBox(height: 20),
        Form(
          key: _form,
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                initialValue: _product,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Product',
                  border: OutlineInputBorder(),
                ),
                items: trainingProducts
                    .map(
                      (product) => DropdownMenuItem(
                        value: product['id'] as String,
                        child: Text(
                          '${product['id']} — ${product['name']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) setState(() => _product = value);
                      },
              ),
              const SizedBox(height: 14),
              _field('Business date (YYYY-MM-DD)', _day, date: true),
              if (!_close) ...[
                _field('Batch / lot ID', _batch),
                _field('Expiry date (YYYY-MM-DD)', _expiry, date: true),
                _field('Units received (> 0)', _quantity, integer: true),
                _field('Actual unit cost (USD)', _cost, decimal: true),
              ] else ...[
                _field('Actual units sold', _quantity, integer: true),
                _field('Units wasted', _waste, integer: true),
                _field('Closing stock (units)', _closing, integer: true),
                _field('Applied markdown (%)', _discount, decimal: true),
                SwitchListTile(
                  title: const Text('Stockout occurred'),
                  value: _stockout,
                  onChanged: (v) => setState(() => _stockout = v),
                ),
                SwitchListTile(
                  title: const Text('Campaign was active'),
                  value: _promotion,
                  onChanged: (v) => setState(() => _promotion = v),
                ),
                SwitchListTile(
                  title: const Text('Holiday'),
                  value: _holiday,
                  onChanged: (v) => setState(() => _holiday = v),
                ),
                const Text(
                  'Close once per product/day. Opening = sold + wasted + closing. '
                  'Remaining stock is carried forward with conservative scalar expiry; batches are not fully reconciled yet.',
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _saving || !provider.isBackendOnline ? null : _save,
                icon: Icon(_saving ? Icons.hourglass_top : Icons.save_outlined),
                label: Text(_saving ? 'Saving…' : 'Save to database'),
              ),
              if (!provider.isBackendOnline)
                const Text('Connect the backend before saving.'),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(_message!),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
