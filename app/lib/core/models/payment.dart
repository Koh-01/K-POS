class Payment {
  final int id;
  final int orderId;
  final String? offlineRef;
  final String paymentMethod; // 'cash' | 'duitnow'
  final double subtotal;
  final double serviceCharge;
  final double sst;
  final double discount;
  final double grandTotal;
  final double? cashReceived;
  final double? changeGiven;
  final String? promoCode;
  final int? promotionId;
  final bool isVoided;
  final DateTime createdAt;

  const Payment({
    required this.id,
    required this.orderId,
    this.offlineRef,
    required this.paymentMethod,
    required this.subtotal,
    required this.serviceCharge,
    required this.sst,
    required this.discount,
    required this.grandTotal,
    this.cashReceived,
    this.changeGiven,
    this.promoCode,
    this.promotionId,
    required this.isVoided,
    required this.createdAt,
  });

  String get receiptNumber {
    final ref = offlineRef?.replaceAll('-', '').toUpperCase() ?? '';
    final end = ref.length > 8 ? 8 : ref.length;
    return ref.isEmpty ? '$id' : 'K-${ref.substring(0, end)}';
  }

  factory Payment.fromJson(Map<String, dynamic> json) => Payment(
    id: json['id'] as int,
    orderId: json['order_id'] as int,
    offlineRef: json['offline_ref'] as String?,
    paymentMethod: json['payment_method'] as String,
    subtotal: double.parse(json['subtotal'].toString()),
    serviceCharge: double.parse(
      (json['service_charge_amount'] ?? json['service_charge'] ?? 0).toString(),
    ),
    sst: double.parse((json['sst_amount'] ?? json['sst'] ?? 0).toString()),
    discount: double.parse(
      (json['discount_amount'] ?? json['discount'] ?? 0).toString(),
    ),
    grandTotal: double.parse(json['grand_total'].toString()),
    cashReceived: (json['cash_tendered'] ?? json['cash_received']) != null
        ? double.parse(
            (json['cash_tendered'] ?? json['cash_received']).toString(),
          )
        : null,
    changeGiven: (json['change_amount'] ?? json['change_given']) != null
        ? double.parse(
            (json['change_amount'] ?? json['change_given']).toString(),
          )
        : null,
    promoCode: json['promo_code'] as String?,
    promotionId: json['promotion_id'] as int?,
    isVoided: (json['is_voided'] as bool?) ?? (json['status'] == 'voided'),
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}
