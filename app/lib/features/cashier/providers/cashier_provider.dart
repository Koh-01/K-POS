import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/api/api_client.dart';
import '../../../core/db/local_db.dart';
import '../../../core/models/order.dart';
import '../../../core/models/order_item.dart';
import '../../../core/models/product.dart';
import '../../../core/models/restaurant_table.dart';

// ── Open orders ────────────────────────────────────────────────────────────

final openOrdersProvider = FutureProvider.autoDispose<List<Order>>((ref) async {
  try {
    final res = await ApiClient.instance.get('/orders?status=open');
    final orders = (res.data as List)
        .map((e) => Order.fromJson(e as Map<String, dynamic>))
        .toList();
    // Keep local cache in sync — failure is non-fatal
    LocalDb.cacheOpenOrders(orders).catchError((_) {});
    return orders;
  } on Exception {
    // Offline: return cached server orders + unsynced offline orders
    try {
      return await LocalDb.getLocalOrders();
    } catch (_) {
      return [];
    }
  }
});

// ── Tables ─────────────────────────────────────────────────────────────────

final tablesProvider =
    FutureProvider.autoDispose<List<RestaurantTable>>((ref) async {
  try {
    final res = await ApiClient.instance.get('/tables');
    final tables = (res.data as List)
        .map((e) => RestaurantTable.fromJson(e as Map<String, dynamic>))
        .toList();
    // Update local cache on every successful fetch — failure is non-fatal
    LocalDb.upsertTables(tables
        .map((t) => {
              'id': t.id,
              'name': t.name,
              'status': t.status,
              'current_order_id': t.currentOrderId,
            })
        .toList()).catchError((_) {});
    return tables;
  } on Exception {
    try {
      final rows = await LocalDb.getTables();
      return rows.map((r) => RestaurantTable.fromJson(r)).toList();
    } catch (_) {
      return [];
    }
  }
});

// ── Cart ───────────────────────────────────────────────────────────────────

class CartState {
  final List<OrderItem> items;
  final int? tableId;
  final String? tableName;
  final String orderType;
  final String? notes;

  const CartState({
    this.items = const [],
    this.tableId,
    this.tableName,
    this.orderType = 'dine_in',
    this.notes,
  });

  CartState copyWith({
    List<OrderItem>? items,
    int? tableId,
    String? tableName,
    String? orderType,
    String? notes,
  }) =>
      CartState(
        items: items ?? this.items,
        tableId: tableId ?? this.tableId,
        tableName: tableName ?? this.tableName,
        orderType: orderType ?? this.orderType,
        notes: notes ?? this.notes,
      );

  double get subtotal => items.fold(0, (s, i) => s + i.subtotal);
  int get totalItems => items.fold(0, (s, i) => s + i.quantity);
}

class CartNotifier extends StateNotifier<CartState> {
  CartNotifier() : super(const CartState());

  void setTable(int id, String name) =>
      state = state.copyWith(tableId: id, tableName: name, orderType: 'dine_in');

  void setCustomTable(String name) =>
      state = state.copyWith(tableId: null, tableName: name, orderType: 'dine_in');

  void setOrderType(String type) => state = state.copyWith(orderType: type);

  void setNotes(String notes) => state = state.copyWith(notes: notes);

  void addProduct(Product p) {
    final idx = state.items.indexWhere((i) => i.productId == p.id);
    if (idx >= 0) {
      final updated = List<OrderItem>.from(state.items);
      updated[idx] = updated[idx].copyWith(quantity: updated[idx].quantity + 1);
      state = state.copyWith(items: updated);
    } else {
      state = state.copyWith(items: [
        ...state.items,
        OrderItem(
          productId: p.id,
          productName: p.name,
          quantity: 1,
          unitPrice: p.price,
        ),
      ]);
    }
  }

  void addWeightProduct(Product p, double weightKg) {
    final idx = state.items.indexWhere((i) => i.productId == p.id);
    if (idx >= 0) {
      final updated = List<OrderItem>.from(state.items);
      updated[idx] = updated[idx].copyWith(weight: weightKg);
      state = state.copyWith(items: updated);
    } else {
      state = state.copyWith(items: [
        ...state.items,
        OrderItem(
          productId: p.id,
          productName: p.name,
          quantity: 1,
          unitPrice: p.price,
          weight: weightKg,
        ),
      ]);
    }
  }

  void updateQuantity(int productId, int qty) {
    if (qty <= 0) {
      state = state.copyWith(
          items: state.items.where((i) => i.productId != productId).toList());
    } else {
      final updated = state.items
          .map((i) => i.productId == productId ? i.copyWith(quantity: qty) : i)
          .toList();
      state = state.copyWith(items: updated);
    }
  }

  void clear() => state = const CartState();

  void loadFromOrder(Order order) {
    state = CartState(
      items: order.items,
      tableId: order.tableId,
      tableName: order.tableName,
      orderType: order.orderType,
      notes: order.notes,
    );
  }
}

final cartProvider = StateNotifierProvider<CartNotifier, CartState>(
  (_) => CartNotifier(),
);

// ── Order actions ──────────────────────────────────────────────────────────

class OrderService {
  static Future<Order> createOrUpdate(CartState cart,
      {int? existingOrderId}) async {
    final payload = {
      'table_id': cart.tableId,
      'table_name': cart.tableName,
      'order_type': cart.orderType,
      'notes': cart.notes,
      'items': cart.items
          .map((i) => {
                'product_id': i.productId,
                'quantity': i.quantity,
                'unit_price': i.unitPrice,
                if (i.weight != null) 'weight_kg': i.weight,
              })
          .toList(),
    };

    try {
      if (existingOrderId != null) {
        final res = await ApiClient.instance
            .put('/orders/$existingOrderId', data: payload);
        return Order.fromJson(res.data as Map<String, dynamic>);
      } else {
        final res = await ApiClient.instance.post('/orders', data: payload);
        return Order.fromJson(res.data as Map<String, dynamic>);
      }
    } on Exception {
      // Offline: queue locally with product names for display
      final ref = const Uuid().v4();
      await LocalDb.savePendingOrder({
        'offline_ref': ref,
        'table_id': cart.tableId,
        'order_type': cart.orderType,
        'notes': cart.notes,
        'items_json': jsonEncode(cart.items
            .map((i) => {
                  'product_id': i.productId,
                  'product_name': i.productName,
                  'quantity': i.quantity,
                  'unit_price': i.unitPrice,
                  if (i.weight != null) 'weight_kg': i.weight,
                })
            .toList()),
        'created_at': DateTime.now().toIso8601String(),
        'synced': 0,
      });
      return Order(
        offlineRef: ref,
        orderType: cart.orderType,
        status: 'open',
        items: cart.items,
        tableId: cart.tableId,
        tableName: cart.tableName,
        notes: cart.notes,
      );
    }
  }

  static Future<Order> fetchOrder(int orderId) async {
    final res = await ApiClient.instance.get('/orders/$orderId');
    return Order.fromJson(res.data as Map<String, dynamic>);
  }

  static Future<void> deleteOrder(int orderId) async {
    await ApiClient.instance.delete('/orders/$orderId');
  }

  static Future<void> syncPendingOrders() async {
    final pending = await LocalDb.getPendingOrders();
    for (final row in pending) {
      try {
        // Strip product_name before sending to server (server doesn't need it)
        final rawItems =
            jsonDecode(row['items_json'] as String) as List;
        final serverItems = rawItems.map((item) {
          final m = item as Map<String, dynamic>;
          return {
            'product_id': m['product_id'],
            'quantity': m['quantity'],
            'unit_price': m['unit_price'],
            if (m['weight_kg'] != null) 'weight_kg': m['weight_kg'],
          };
        }).toList();

        final res = await ApiClient.instance.post('/sync/orders', data: {
          'offline_ref': row['offline_ref'],
          'table_id': row['table_id'],
          'order_type': row['order_type'],
          'notes': row['notes'],
          'items': serverItems,
          'created_at': row['created_at'],
        });
        await LocalDb.markOrderSynced(row['offline_ref'] as String);

        final realOrderId =
            (res.data as Map<String, dynamic>)['order_id'] as int?;
        if (realOrderId != null) {
          await _syncPaymentForOrder(
              row['offline_ref'] as String, realOrderId);
        }
      } catch (_) {
        break; // still offline
      }
    }
  }

  static Future<void> _syncPaymentForOrder(
      String orderOfflineRef, int orderId) async {
    final payments =
        await LocalDb.getPendingPaymentsForOrder(orderOfflineRef);
    for (final p in payments) {
      try {
        await ApiClient.instance.post('/payments', data: {
          'order_id': orderId,
          'payment_method': p['payment_method'],
          if (p['cash_tendered'] != null)
            'cash_tendered': p['cash_tendered'],
        });
        await LocalDb.markPaymentSynced(p['offline_ref'] as String);
      } catch (_) {
        // leave for next sync
      }
    }
  }
}
