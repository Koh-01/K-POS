import 'payment.dart';
import 'order_item.dart';

class PaymentDetail extends Payment {
  final String? orderNumber;
  final String? tableName;
  final String? orderType;
  final double discountPercent;
  final DateTime updatedAt;
  final List<OrderItem> items;

  const PaymentDetail({
    required super.id,
    required super.orderId,
    required super.paymentMethod,
    required super.subtotal,
    required super.serviceCharge,
    required super.sst,
    required super.discount,
    required super.grandTotal,
    super.cashReceived,
    super.changeGiven,
    super.promoCode,
    super.promotionId,
    required super.isVoided,
    required super.createdAt,
    this.orderNumber,
    this.tableName,
    this.orderType,
    this.discountPercent = 0,
    required this.updatedAt,
    this.items = const [],
  });

  bool get wasEdited =>
      updatedAt.difference(createdAt).inSeconds > 2;

  String get locationLabel {
    if (orderType == 'takeaway') return 'Takeaway';
    return tableName ?? 'Table';
  }

  factory PaymentDetail.fromJson(Map<String, dynamic> json) => PaymentDetail(
        id: json['id'] as int,
        orderId: json['order_id'] as int,
        paymentMethod: json['payment_method'] as String,
        subtotal: double.parse(json['subtotal'].toString()),
        serviceCharge: double.parse(
            (json['service_charge_amount'] ?? json['service_charge'] ?? 0)
                .toString()),
        sst: double.parse(
            (json['sst_amount'] ?? json['sst'] ?? 0).toString()),
        discount: double.parse(
            (json['discount_amount'] ?? json['discount'] ?? 0).toString()),
        grandTotal: double.parse(json['grand_total'].toString()),
        cashReceived:
            (json['cash_tendered'] ?? json['cash_received']) != null
                ? double.parse(
                    (json['cash_tendered'] ?? json['cash_received']).toString())
                : null,
        changeGiven:
            (json['change_amount'] ?? json['change_given']) != null
                ? double.parse(
                    (json['change_amount'] ?? json['change_given']).toString())
                : null,
        promoCode: json['promo_code'] as String?,
        promotionId: json['promotion_id'] as int?,
        isVoided:
            (json['is_voided'] as bool?) ?? (json['status'] == 'voided'),
        createdAt: DateTime.parse(json['created_at'] as String),
        orderNumber: json['order_number'] as String?,
        tableName: json['table_name'] as String?,
        orderType: json['order_type'] as String?,
        discountPercent: double.parse(
            (json['discount_percent'] ?? 0).toString()),
        updatedAt: DateTime.parse(json['updated_at'] as String),
        items: (json['items'] as List<dynamic>?)
                ?.map((e) => OrderItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}
