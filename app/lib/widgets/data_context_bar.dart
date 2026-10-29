import '../data/store_catalog.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../pages/account_settings_page.dart';

class DataContextBar extends StatelessWidget {
  const DataContextBar({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    return Material(
      color: const Color(0xFFEFF6FF),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            FilterChip(
              label: Text(
                ApiService.demoMode
                    ? (ApiService.demoAutomaticCalendar
                          ? 'DEMO | Thailand date ${ApiService.demoDate} | Auto update'
                          : 'DEMO started ${ApiService.demoSessionDate} | Day ${ApiService.demoDate}')
                    : 'Try Demo Deals',
              ),
              selected: ApiService.demoMode,
              selectedColor: const Color(0xFFFFD180),
              onSelected: provider.isSyncingBackend
                  ? null
                  : (enabled) async {
                      await provider.setDealDemo(enabled);
                      if (context.mounted &&
                          provider.lastBackendError != null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(provider.lastBackendError!)),
                        );
                      }
                    },
            ),
            DropdownButton<String>(
              value: provider.selectedStoreId,
              items: [
                for (final store in provider.accessibleStoreIds)
                  DropdownMenuItem(value: store, child: Text(storeName(store))),
              ],
              onChanged: provider.isSyncingBackend
                  ? null
                  : (value) {
                      if (value != null) provider.selectStore(value);
                    },
            ),
            Text('Snapshot: ${ApiService.defaultDate} • Prices: USD'),
            if (ApiService.accessToken != null)
              IconButton(
                tooltip: 'Account settings',
                icon: const Icon(Icons.manage_accounts_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AccountSettingsPage(),
                  ),
                ),
              ),
            IconButton(
              tooltip: 'Choose business date',
              onPressed: provider.isSyncingBackend || ApiService.demoMode
                  ? null
                  : () async {
                      final selected = await showDatePicker(
                        context: context,
                        initialDate: DateTime.parse(ApiService.defaultDate),
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                      );
                      if (selected != null) {
                        await provider.selectDate(
                          selected.toIso8601String().substring(0, 10),
                        );
                      }
                    },
              icon: const Icon(Icons.calendar_month_outlined),
            ),
            Text(
              provider.isPreview
                  ? 'MOCK inventory preview • no live predictions'
                  : provider.backendStatusMessage,
              style: const TextStyle(fontSize: 12),
            ),
            TextButton.icon(
              onPressed: provider.isSyncingBackend
                  ? null
                  : () => provider.checkBackendConnection(),
              icon: const Icon(Icons.refresh),
              label: const Text('Reconnect API'),
            ),
          ],
        ),
      ),
    );
  }
}
