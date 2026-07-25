import 'order_item.dart';

class Order {
  final int? id;
  final int? tableId;
  final String? tableName;
  final String orderType; // 'dine_in' | 'takeaway'
  final String status; // 'open' | 'paid' | 'voided'
  final String? notes;
  final List<OrderItem> items;
  final DateTime? createdAt;
  final String? offlineRef;

  const Order({
    this.id,
    this.tableId,
    this.tableName,
    required this.orderType,
    required this.status,
    this.notes,
    required this.items,
    this.createdAt,
    this.offlineRef,
  });

  factory Order.fromJson(Map<String, dynamic> json) => Order(
        id: json['id'] as int?,
        tableId: json['table_id'] as int?,
        tableName: json['table_name'] as String?,
        orderType: json['order_type'] as String? ?? 'dine_in',
        status: json['status'] as String? ?? 'open',
        notes: json['notes'] as String?,
        items: (json['items'] as List<dynamic>?)
                ?.map((e) => OrderItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        createdAt: json['created_at'] != null
            ? DateTime.parse(json['created_at'] as String)
            : null,
        offlineRef: json['offline_ref'] as String?,
      );

  double get subtotal => items.fold(0, (sum, i) => sum + i.subtotal);
}
