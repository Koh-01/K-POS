class Worker {
  final int id;
  final String name;
  final String? icNumber;
  final String? phone;
  final String? position;
  final bool isActive;
  final DateTime createdAt;

  const Worker({
    required this.id,
    required this.name,
    this.icNumber,
    this.phone,
    this.position,
    required this.isActive,
    required this.createdAt,
  });

  factory Worker.fromJson(Map<String, dynamic> json) => Worker(
    id: json['id'] as int,
    name: json['name'] as String,
    icNumber: json['ic_number'] as String?,
    phone: json['phone'] as String?,
    position: json['position'] as String?,
    isActive: json['is_active'] as bool? ?? true,
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}
