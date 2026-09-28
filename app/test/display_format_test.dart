import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/core/models/order.dart';
import 'package:pos_app/core/models/restaurant_table.dart';
import 'package:pos_app/features/cashier/providers/cashier_provider.dart';
import 'package:pos_app/shared/utils/currency_formatter.dart';

void main() {
  const tables = [
    RestaurantTable(id: 12, name: 'A3', status: 'occupied'),
  ];

  test('orders show the table name, never the internal id', () {
    expect(
      orderPlaceLabel(orderType: 'dine_in', tableId: 12, tables: tables),
      'A3',
    );
    expect(
      orderPlaceLabel(orderType: 'dine_in', tableId: 12),
      'Dine in',
    );
    expect(orderPlaceLabel(orderType: 'dine_in'), 'No table');
    expect(
      orderPlaceLabel(orderType: 'dine_in', tableName: 'Patio', tableId: 12),
      'Patio',
    );
    expect(orderPlaceLabel(orderType: OrderTypes.takeAway), 'Takeaway');
  });

  test('quantities drop trailing zeros', () {
    expect(formatQty('3.000'), '3');
    expect(formatQty('1.250'), '1.25');
    expect(formatQty('0.500'), '0.5');
    expect(formatQty(null), '0');
  });
}
