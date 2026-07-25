class Promotion {
  final int id;
  final String name;
  final String type;
  final Map<String, dynamic> conditions;
  final bool isActive;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final int usageCount;

  const Promotion({
    required this.id,
    required this.name,
    required this.type,
    required this.conditions,
    required this.isActive,
    this.startsAt,
    this.endsAt,
    this.usageCount = 0,
  });

  factory Promotion.fromJson(Map<String, dynamic> json) => Promotion(
        id: json['id'] as int,
        name: json['name'] as String,
        type: json['type'] as String,
        conditions: (json['conditions'] as Map<String, dynamic>?) ?? {},
        isActive: json['is_active'] as bool? ?? true,
        startsAt: json['starts_at'] != null
            ? DateTime.tryParse(json['starts_at'] as String)
            : null,
        endsAt: json['ends_at'] != null
            ? DateTime.tryParse(json['ends_at'] as String)
            : null,
        usageCount: json['usage_count'] as int? ?? 0,
      );

  // convenience getters
  double get percent =>
      double.tryParse(conditions['percent']?.toString() ?? '') ?? 0.0;

  String? get promoCode => conditions['code'] as String?;

  String get typeLabel => switch (type) {
        'discount_pct' => 'Discount %',
        'b1f1' => 'Buy 1 Free 1',
        'happy_hour' => 'Happy Hour',
        'promo_code' => 'Promo Code',
        _ => type,
      };

  int? get b1f1ProductId => conditions['product_id'] as int?;

  String get summary => switch (type) {
        'discount_pct' => '${percent.toStringAsFixed(0)}% off entire order',
        'b1f1' => 'Product #${b1f1ProductId ?? '?'} — Buy 1 Get 1 Free',
        'happy_hour' =>
          '${conditions['start_time'] ?? ''}-${conditions['end_time'] ?? ''} · ${percent.toStringAsFixed(0)}% off',
        'promo_code' => 'Code: ${promoCode ?? ''} · ${percent.toStringAsFixed(0)}% off',
        _ => type,
      };
}
