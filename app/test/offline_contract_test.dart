import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/core/api/api_exception.dart';
import 'package:pos_app/core/models/order.dart';
import 'package:pos_app/core/models/order_item.dart';
import 'package:pos_app/core/models/store_settings.dart';
import 'package:pos_app/features/payments/providers/payment_provider.dart';

void main() {
  test('weighted order item uses weight instead of quantity', () {
    const item = OrderItem(
      productId: 1,
      productName: 'Fish',
      quantity: 1,
      unitPrice: 12.50,
      weight: 1.2,
    );
    expect(item.subtotal, 15.0);
  });

  test('quantity order item uses quantity', () {
    const item = OrderItem(
      productId: 2,
      productName: 'Drink',
      quantity: 3,
      unitPrice: 2.50,
    );
    expect(item.subtotal, 7.5);
  });

  test('canonical takeaway value is retained in an order', () {
    final order = Order.fromJson({
      'order_type': 'take_away',
      'status': 'open',
      'items': <Object>[],
    });
    expect(order.orderType, OrderTypes.takeAway);
  });

  test('only network and gateway failures are queued as offline', () {
    expect(
      ApiException.isOfflineFailure(
        const ApiException('offline', isNetworkError: true),
      ),
      isTrue,
    );
    expect(
      ApiException.isOfflineFailure(
        const ApiException('invalid', statusCode: 422),
      ),
      isFalse,
    );
  });

  test('unpaid bill uses the same cached charge calculation as checkout', () {
    const settings = StoreSettings(
      storeName: 'KTS',
      sstRate: 0.06,
      serviceChargeRate: 0.10,
      enableSst: true,
      enableServiceCharge: true,
    );
    const items = [
      OrderItem(productId: 1, productName: 'Item', quantity: 1, unitPrice: 10),
    ];
    final bill = calculateOfflineCheckout(items, settings);
    expect(bill.subtotal, 10);
    expect(bill.serviceCharge, 1);
    expect(bill.serviceChargeRate, 0.10);
    expect(bill.sst, 0.66);
    expect(bill.sstRate, 0.06);
    expect(bill.grandTotal, 11.66);
  });
}
