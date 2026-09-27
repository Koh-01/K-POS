import '../api/api_client.dart';

class SalaryPayment {
  final int id;
  final int workerId;
  final String workerName;
  final int year;
  final int month;
  final double amount;
  final String? note;
  final int? cashRecordId;
  final String? signatureImageUrl;
  final DateTime createdAt;

  const SalaryPayment({
    required this.id,
    required this.workerId,
    required this.workerName,
    required this.year,
    required this.month,
    required this.amount,
    this.note,
    this.cashRecordId,
    this.signatureImageUrl,
    required this.createdAt,
  });

  factory SalaryPayment.fromJson(Map<String, dynamic> json) => SalaryPayment(
    id: json['id'] as int,
    workerId: json['worker_id'] as int,
    workerName: json['worker_name'] as String? ?? '',
    year: json['year'] as int,
    month: json['month'] as int,
    amount: double.parse(json['amount'].toString()),
    note: json['note'] as String?,
    cashRecordId: json['cash_record_id'] as int?,
    signatureImageUrl: ApiClient.resolveUrl(
      json['signature_image_path'] as String?,
    ),
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  String get monthLabel => '${_months[month - 1]} $year';
}
