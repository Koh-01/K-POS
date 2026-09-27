class CashRecord {
  final int id;
  final String type; // 'cash_in' | 'cash_out'
  final double amount;
  final String description;
  final String? category;
  final String? reference;
  final String? receiptImagePath;
  final DateTime createdAt;

  const CashRecord({
    required this.id,
    required this.type,
    required this.amount,
    required this.description,
    this.category,
    this.reference,
    this.receiptImagePath,
    required this.createdAt,
  });

  factory CashRecord.fromJson(Map<String, dynamic> json) => CashRecord(
    id: json['id'] as int,
    type: json['type'] as String,
    amount: double.parse(json['amount'].toString()),
    description: json['description'] as String? ?? '',
    category: json['category'] as String?,
    reference: json['reference'] as String?,
    receiptImagePath: json['receipt_image_path'] as String?,
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  bool get isCashIn => type == 'cash_in';
}
