import 'package:flutter_test/flutter_test.dart';
import 'package:freshflow/providers/app_provider.dart';

void main() {
  test(
    'Changing stores replaces the scope without duplicating products',
    () async {
      final provider = AppProvider(connectOnStart: false);
      addTearDown(provider.dispose);
      expect(provider.aisles.length, 32);
      expect(
        provider.aisles.every((row) => row['storeId'] == 'STORE_01'),
        isTrue,
      );
      await provider.selectStore('STORE_02');
      expect(provider.aisles.length, 32);
      expect(
        provider.aisles.every((row) => row['storeId'] == 'STORE_02'),
        isTrue,
      );
      expect(provider.aisles.map((row) => row['productId']).toSet().length, 32);
      expect(provider.discounts, isEmpty);
      expect(provider.alerts, isEmpty);
      // Restore the shared API scope so subsequent tests remain independent.
      await provider.selectStore('STORE_01');
    },
  );

  test(
    'Offline approval does not report a successful database write',
    () async {
      final provider = AppProvider(connectOnStart: false);
      addTearDown(provider.dispose);
      expect(await provider.approveRecommendation('unknown'), isFalse);
      expect(await provider.rejectRecommendation('unknown'), isFalse);
    },
  );
}
