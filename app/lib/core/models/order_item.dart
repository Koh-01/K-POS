class OrderItem {
  final int? id;
  final int? orderId;
  final int productId;
  final String productName;
  final int quantity;
  final double unitPrice;
  final double? weight; // kg for weight-based products
  final String? notes;

  const OrderItem({
    this.id,
    this.orderId,
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.unitPrice,
    this.weight,
    this.notes,
  });

  double get subtotal =>
      weight != null ? weight! * unitPrice : unitPrice * quantity;

  factory OrderItem.fromJson(Map<String, dynamic> json) => OrderItem(
    id: json['id'] as int?,
    orderId: json['order_id'] as int?,
    productId: json['product_id'] as int,
    productName: json['product_name'] as String? ?? '',
    quantity: json['quantity'] as int,
    unitPrice: double.parse(json['unit_price'].toString()),
    weight: json['weight_kg'] != null
        ? double.parse(json['weight_kg'].toString())
        : null,
    notes: json['notes'] as String?,
  );

  OrderItem copyWith({int? quantity, double? weight}) => OrderItem(
    id: id,
    orderId: orderId,
    productId: productId,
    productName: productName,
    quantity: quantity ?? this.quantity,
    unitPrice: unitPrice,
    weight: weight ?? this.weight,
    notes: notes,
  );
}
