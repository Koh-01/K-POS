import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/db/local_db.dart';
import '../../../core/models/order.dart';
import '../../../core/models/order_item.dart';
import '../../../core/models/product.dart';
import '../../../core/models/restaurant_table.dart';

// ── Open orders ────────────────────────────────────────────────────────────

final openOrdersProvider = FutureProvider.autoDispose<List<Order>>((ref) async {
  try {
    final res = await ApiClient.instance.get('/orders?status=open');
    final serverOrders = (res.data as List)
        .map((e) => Order.fromJson(e as Map<String, dynamic>))
        .toList();
    var orders = serverOrders;
    try {
      final locallyPaidIds = await LocalDb.getPendingPaidServerOrderIds();
      orders = serverOrders
          .where((order) => !locallyPaidIds.contains(order.id))
          .toList();
    } catch (_) {
      // A local overlay failure must not hide otherwise valid server data.
    }
    // Keep local cache in sync — failure is non-fatal
    LocalDb.cacheOpenOrders(orders).catchError((_) {});
    return orders;
  } on Exception catch (e) {
    if (!ApiException.isOfflineFailure(e)) rethrow;
    // Offline: return cached server orders + unsynced offline orders
    try {
      return await LocalDb.getLocalOrders();
    } catch (_) {
      return [];
    }
  }
});

// ── Tables ─────────────────────────────────────────────────────────────────

final tablesProvider = FutureProvider.autoDispose<List<RestaurantTable>>((
  ref,
) async {
  try {
    final res = await ApiClient.instance.get('/tables');
    final serverTables = (res.data as List)
        .map((e) => RestaurantTable.fromJson(e as Map<String, dynamic>))
        .toList();
    var tables = serverTables;
    try {
      final locallyPaidIds = await LocalDb.getPendingPaidServerOrderIds();
      tables = serverTables.map((table) {
        if (!locallyPaidIds.contains(table.currentOrderId)) return table;
        return RestaurantTable(
          id: table.id,
          name: table.name,
          status: 'available',
        );
      }).toList();
    } catch (_) {
      // Fall back to the server table state if the local cache is unavailable.
    }
    // Update local cache on every successful fetch — failure is non-fatal
    LocalDb.upsertTables(
      tables
          .map(
            (t) => {
              'id': t.id,
              'name': t.name,
              'status': t.status,
              'current_order_id': t.currentOrderId,
            },
          )
          .toList(),
    ).catchError((_) {});
    return tables;
  } on Exception catch (e) {
    if (!ApiException.isOfflineFailure(e)) rethrow;
    try {
      final rows = await LocalDb.getTables();
      return rows.map((r) => RestaurantTable.fromJson(r)).toList();
    } catch (_) {
      return [];
    }
  }
});

final pendingSyncCountProvider = FutureProvider.autoDispose<int>((ref) async {
  try {
    return await LocalDb.getPendingSyncCount();
  } catch (_) {
    return 0;
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
  }) => CartState(
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

  void setTable(int id, String name) => state = state.copyWith(
    tableId: id,
    tableName: name,
    orderType: 'dine_in',
  );

  void setCustomTable(String name) => state = state.copyWith(
    tableId: null,
    tableName: name,
    orderType: 'dine_in',
  );

  void setOrderType(String type) => state = state.copyWith(orderType: type);

  void setNotes(String notes) => state = state.copyWith(notes: notes);

  void addProduct(Product p) {
    final idx = state.items.indexWhere((i) => i.productId == p.id);
    if (idx >= 0) {
      final updated = List<OrderItem>.from(state.items);
      updated[idx] = updated[idx].copyWith(quantity: updated[idx].quantity + 1);
      state = state.copyWith(items: updated);
    } else {
      state = state.copyWith(
        items: [
          ...state.items,
          OrderItem(
            productId: p.id,
            productName: p.name,
            quantity: 1,
            unitPrice: p.price,
          ),
        ],
      );
    }
  }

  void addWeightProduct(Product p, double weightKg) {
    final idx = state.items.indexWhere((i) => i.productId == p.id);
    if (idx >= 0) {
      final updated = List<OrderItem>.from(state.items);
      updated[idx] = updated[idx].copyWith(weight: weightKg);
      state = state.copyWith(items: updated);
    } else {
      state = state.copyWith(
        items: [
          ...state.items,
          OrderItem(
            productId: p.id,
            productName: p.name,
            quantity: 1,
            unitPrice: p.price,
            weight: weightKg,
          ),
        ],
      );
    }
  }

  void updateQuantity(int productId, int qty) {
    if (qty <= 0) {
      state = state.copyWith(
        items: state.items.where((i) => i.productId != productId).toList(),
      );
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
  static Future<void>? _checkoutSyncInFlight;

  /// [offlineRef] should be the ref returned by a *previous* offline call
  /// for this same order-editing session (e.g. stored on the order screen's
  /// state), so repeated offline auto-saves update the one queued order
  /// instead of piling up a new one on every edit.
  static Future<Order> createOrUpdate(
    CartState cart, {
    int? existingOrderId,
    String? offlineRef,
  }) async {
    final requestOfflineRef = existingOrderId == null
        ? (offlineRef ?? const Uuid().v4())
        : offlineRef;
    final payload = {
      if (existingOrderId == null) 'offline_ref': requestOfflineRef,
      'table_id': cart.tableId,
      'table_name': cart.tableName,
      'order_type': cart.orderType,
      'notes': cart.notes,
      'items': cart.items
          .map(
            (i) => {
              'product_id': i.productId,
              'quantity': i.quantity,
              'unit_price': i.unitPrice,
              if (i.weight != null) 'weight_kg': i.weight,
            },
          )
          .toList(),
    };

    try {
      if (existingOrderId != null) {
        final res = await ApiClient.instance.put(
          '/orders/$existingOrderId',
          data: payload,
        );
        return Order.fromJson(res.data as Map<String, dynamic>);
      } else {
        final res = await ApiClient.instance.post('/orders', data: payload);
        return Order.fromJson(res.data as Map<String, dynamic>);
      }
    } on Exception catch (e) {
      if (!ApiException.isOfflineFailure(e)) rethrow;
      if (existingOrderId != null) {
        // This order already has a real server ID — queue the edit keyed
        // by that id (not a new offline_ref) so it overwrites itself on
        // every retry instead of duplicating, and survives navigating
        // away before the connection comes back.
        await LocalDb.upsertPendingOrderUpdate(
          orderId: existingOrderId,
          tableId: cart.tableId,
          tableName: cart.tableName,
          orderType: cart.orderType,
          notes: cart.notes,
          itemsJson: jsonEncode(
            cart.items
                .map(
                  (i) => {
                    'product_id': i.productId,
                    'product_name': i.productName,
                    'quantity': i.quantity,
                    'unit_price': i.unitPrice,
                    if (i.weight != null) 'weight_kg': i.weight,
                  },
                )
                .toList(),
          ),
        );
        return Order(
          id: existingOrderId,
          orderType: cart.orderType,
          status: 'open',
          items: cart.items,
          tableId: cart.tableId,
          tableName: cart.tableName,
          notes: cart.notes,
        );
      }
      // Offline, brand-new order: queue/update the *same* local row across
      // repeated auto-saves instead of inserting a fresh one every time.
      final ref = requestOfflineRef!;
      await LocalDb.upsertPendingOrder(
        offlineRef: ref,
        tableId: cart.tableId,
        tableName: cart.tableName,
        orderType: cart.orderType,
        notes: cart.notes,
        itemsJson: jsonEncode(
          cart.items
              .map(
                (i) => {
                  'product_id': i.productId,
                  'product_name': i.productName,
                  'quantity': i.quantity,
                  'unit_price': i.unitPrice,
                  if (i.weight != null) 'weight_kg': i.weight,
                },
              )
              .toList(),
        ),
      );
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

  // POST /sync/orders is a batch endpoint: it takes a JSON *array* and
  // returns one result per item (matched by offline_ref), so every pending
  // order is sent in a single request rather than one call each.
  static Future<void> syncPendingOrders() async {
    final pending = await LocalDb.getPendingOrders();
    if (pending.isEmpty) return;

    final payload = pending.map((row) {
      // Strip product_name before sending to server (server doesn't need it)
      final rawItems = jsonDecode(row['items_json'] as String) as List;
      final serverItems = rawItems.map((item) {
        final m = item as Map<String, dynamic>;
        return {
          'product_id': m['product_id'],
          'quantity': m['quantity'],
          'unit_price': m['unit_price'],
          if (m['weight_kg'] != null) 'weight_kg': m['weight_kg'],
        };
      }).toList();
      return {
        'offline_ref': row['offline_ref'],
        'table_id': row['table_id'],
        'table_name': row['table_name'],
        'order_type': row['order_type'],
        'notes': row['notes'],
        'paid_locally': row['paid'] == 1,
        'items': serverItems,
        'device_created_at': row['created_at'],
      };
    }).toList();

    try {
      final res = await ApiClient.instance.post('/sync/orders', data: payload);
      final results = res.data as List;
      for (final r in results) {
        final m = r as Map<String, dynamic>;
        final offlineRef = m['offline_ref'] as String;
        if (m['action'] == 'error') {
          await LocalDb.markOrderSyncError(
            offlineRef,
            m['error']?.toString() ?? 'Unknown sync error',
          );
          continue;
        }
        final realOrderId = m['order_id'] as int?;
        if (realOrderId == null) continue;
        await LocalDb.markOrderSynced(offlineRef, realOrderId);
        await _syncPaymentForOrder(offlineRef, realOrderId);
      }
    } catch (e) {
      if (!ApiException.isOfflineFailure(e)) rethrow;
      // Still offline (or the whole batch call failed) — everything stays
      // queued and the next periodic retry will pick it back up.
    }
  }

  /// Replays edits made while offline to orders that already had a real
  /// server ID (so they were never in pending_orders to begin with).
  static Future<void> syncPendingOrderUpdates() async {
    final pending = await LocalDb.getAllPendingOrderUpdates();
    for (final row in pending) {
      try {
        final rawItems = jsonDecode(row['items_json'] as String) as List;
        final items = rawItems.map((item) {
          final m = item as Map<String, dynamic>;
          return {
            'product_id': m['product_id'],
            'quantity': m['quantity'],
            'unit_price': m['unit_price'],
            if (m['weight_kg'] != null) 'weight_kg': m['weight_kg'],
          };
        }).toList();
        await ApiClient.instance.put(
          '/orders/${row['order_id']}',
          data: {
            'table_id': row['table_id'],
            'table_name': row['table_name'],
            'order_type': row['order_type'],
            'notes': row['notes'],
            'items': items,
          },
        );
        await LocalDb.deletePendingOrderUpdate(row['order_id'] as int);
      } catch (e) {
        if (ApiException.isOfflineFailure(e)) return;
        await LocalDb.markOrderUpdateSyncError(
          row['order_id'] as int,
          e.toString(),
        );
      }
    }
  }

  /// Replays payments that were taken offline for orders which already had
  /// a real server ID at the time (the order itself never needed syncing —
  /// only the payment was queued because the connection dropped right
  /// before checkout).
  static Future<void> syncPendingPaymentsForKnownOrders() async {
    final pending = await LocalDb.getPendingPaymentsForRealOrders();
    await _syncPaymentRows(pending);
  }

  /// Runs the checkout-related queues in dependency order and coalesces
  /// concurrent triggers from checkout, connectivity changes, and the retry
  /// timer into one background operation.
  static Future<void> syncPendingCheckoutQueue() {
    final active = _checkoutSyncInFlight;
    if (active != null) return active;

    late final Future<void> run;
    run = _runPendingCheckoutSync().whenComplete(() {
      if (identical(_checkoutSyncInFlight, run)) {
        _checkoutSyncInFlight = null;
      }
    });
    _checkoutSyncInFlight = run;
    return run;
  }

  static Future<void> _runPendingCheckoutSync() async {
    final actions = <Future<void> Function()>[
      syncPendingOrders,
      syncPendingOrderUpdates,
      syncPendingPaymentsForKnownOrders,
    ];
    for (final action in actions) {
      try {
        await action();
      } catch (_) {
        // A rejected row remains queued with its error for inspection/retry;
        // it must not stop independent checkout queues from progressing.
      }
    }
  }

  static Future<void> _syncPaymentForOrder(
    String orderOfflineRef,
    int orderId,
  ) async {
    final payments = await LocalDb.getPendingPaymentsForOrder(orderOfflineRef);
    await _syncPaymentRows(
      payments.map((p) => {...p, 'order_id': orderId}).toList(),
    );
  }

  static Future<void> _syncPaymentRows(
    List<Map<String, dynamic>> payments,
  ) async {
    if (payments.isEmpty) return;
    try {
      final payload = payments
          .map(
            (p) => {
              'offline_ref': p['offline_ref'],
              'order_id': p['order_id'],
              'payment_method': p['payment_method'],
              if (p['promotion_id'] != null) 'promotion_id': p['promotion_id'],
              'subtotal': p['subtotal'],
              'discount_percent': p['discount_percent'] ?? 0,
              'discount_amount': p['discount_amount'],
              'service_charge_rate': p['service_charge_rate'] ?? 0,
              'service_charge_amount': p['service_charge_amount'],
              'sst_rate': p['sst_rate'] ?? 0,
              'sst_amount': p['sst_amount'],
              'grand_total': p['grand_total'],
              if (p['cash_tendered'] != null)
                'cash_tendered': p['cash_tendered'],
              'device_created_at': p['created_at'],
            },
          )
          .toList();
      final res = await ApiClient.instance.post(
        '/sync/payments',
        data: payload,
      );
      for (final raw in res.data as List) {
        final result = raw as Map<String, dynamic>;
        final ref = result['offline_ref'] as String;
        if (result['action'] == 'error') {
          await LocalDb.markPaymentSyncError(
            ref,
            result['error']?.toString() ?? 'Unknown sync error',
          );
        } else {
          await LocalDb.markPaymentSynced(ref);
        }
      }
    } catch (e) {
      if (!ApiException.isOfflineFailure(e)) rethrow;
      // Connectivity failures remain queued and are retried by the timer.
    }
  }
}
