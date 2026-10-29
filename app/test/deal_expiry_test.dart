import 'package:flutter_test/flutter_test.dart';
import 'package:freshflow/providers/app_provider.dart';
import 'package:freshflow/services/api_service.dart';

void main() {
  test('Demo deal eligibility stays isolated from real-date offers', () {
    final provider = AppProvider(connectOnStart: false);
    addTearDown(provider.dispose);
    addTearDown(() {
      ApiService.demoMode = false;
    });
    final demo = <String, dynamic>{
      'status': 'active',
      'saleAllowed': true,
      'stock': 5,
      'expiryDate': '2026-10-13',
      'demoMode': true,
    };
    ApiService.demoMode = false;
    expect(provider.isDealAvailable(demo), false);
    ApiService.demoMode = true;
    expect(provider.isDealAvailable(demo), true);
    expect(
      provider.isDealAvailable({...demo, 'expiryDate': '2026-10-11'}),
      false,
    );
    expect(provider.isDealAvailable({...demo, 'demoMode': false}), false);
  });
  test(
    'Expired, unapproved and out-of-stock offers cannot be shown or claimed',
    () {
      final provider = AppProvider(connectOnStart: false);
      addTearDown(provider.dispose);
      final bangkok = DateTime.now().toUtc().add(const Duration(hours: 7));
      final today = DateTime.utc(bangkok.year, bangkok.month, bangkok.day);
      String day(int offset) =>
          today.add(Duration(days: offset)).toIso8601String().substring(0, 10);
      Map<String, dynamic> offer(
        String id,
        int expiry, {
        int stock = 5,
        String status = 'active',
      }) => {
        'id': id,
        'productId': 'PROD_001',
        'status': status,
        'saleAllowed': true,
        'stock': stock,
        'expiryDate': day(expiry),
        'discountPercent': 20,
        'finalPrice': 2.0,
      };
      provider.discounts = [
        offer('expired', -1),
        offer('valid', 1),
        offer('today', 0),
        offer('sold-out', 1, stock: 0),
        offer('proposed', 1, status: 'proposed'),
      ];
      expect(provider.customerDeals.map((d) => d['id']), ['valid', 'today']);
      expect(provider.claimDeal('expired'), isNull);
      expect(provider.claimDeal('sold-out'), isNull);
      expect(provider.claimDeal('proposed'), isNull);
      expect(provider.claimDeal('valid'), isNotNull);
      // A locally previewed voucher must not pretend a physical sale occurred.
      expect(
        provider.discounts.firstWhere((d) => d['id'] == 'valid')['stock'],
        5,
      );
    },
  );
}
