import 'package:flutter_test/flutter_test.dart';
import 'package:freshflow/data/product_catalog.dart';
import 'package:freshflow/data/inventory_preview.dart';

void main() {
  test('Catalog preserves training identities and scope', () {
    expect(trainingProducts.length, 32);
    expect(trainingProducts.map((p) => p['id']).toSet().length, 32);
    expect(
      trainingProducts.firstWhere((p) => p['id'] == 'PROD_001')['name'],
      'Apples 1kg',
    );
    for (final category in ['Bakery', 'Produce', 'Dairy', 'Meat']) {
      expect(
        trainingProducts.where((p) => p['category'] == category).length,
        8,
      );
    }
  });

  test('Preview has 32 unique products in each of four stores', () {
    expect(previewInventory.length, 128);
    for (var store = 1; store <= 4; store++) {
      final rows = previewInventory.where(
        (r) => r['storeId'] == 'STORE_0$store',
      );
      expect(rows.length, 32);
      expect(rows.map((r) => r['productId']).toSet().length, 32);
    }
  });
}
