class RestaurantTable {
  final int id;
  final String name;
  final String status; // 'available' | 'occupied'
  final int? currentOrderId;

  const RestaurantTable({
    required this.id,
    required this.name,
    required this.status,
    this.currentOrderId,
  });

  factory RestaurantTable.fromJson(Map<String, dynamic> json) =>
      RestaurantTable(
        id: json['id'] as int,
        name: json['name'] as String,
        status: json['status'] as String? ?? 'available',
        currentOrderId: json['current_order_id'] as int?,
      );

  bool get isOccupied => status == 'occupied';
}
