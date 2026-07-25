import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/models/payment.dart';
import '../../../core/models/promotion.dart';

class CheckoutSummary {
  final double subtotal;
  final double serviceCharge;
  final double sst;
  final double discount;
  final double grandTotal;
  final int? promotionId;
  final String? promoCode;

  const CheckoutSummary({
    required this.subtotal,
    required this.serviceCharge,
    required this.sst,
    required this.discount,
    required this.grandTotal,
    this.promotionId,
    this.promoCode,
  });
}

class PaymentNotifier extends StateNotifier<AsyncValue<CheckoutSummary?>> {
  PaymentNotifier() : super(const AsyncValue.data(null));

  Future<void> preview(int orderId,
      {int? promotionId, String? promoCode}) async {
    state = const AsyncValue.loading();
    try {
      double discountPct = 0;
      double discountAmt = 0;
      int? resolvedPromoId;
      String? resolvedPromoCode;

      if (promotionId != null ||
          (promoCode != null && promoCode.isNotEmpty)) {
        final body = <String, dynamic>{'order_id': orderId};
        if (promotionId != null) body['promotion_id'] = promotionId;
        if (promoCode != null && promoCode.isNotEmpty) {
          body['promo_code'] = promoCode;
        }
        final promoRes =
            await ApiClient.instance.post('/promotions/apply', data: body);
        final pd = promoRes.data as Map<String, dynamic>;
        discountPct = double.parse(pd['discount_percent'].toString());
        discountAmt = double.parse(pd['discount_amount'].toString());
        resolvedPromoId = pd['promotion_id'] as int?;
        resolvedPromoCode = promoCode;
      }

      final qp = <String, dynamic>{};
      if (discountPct > 0) qp['discount_percent'] = discountPct;
      if (discountAmt > 0) qp['discount_amount'] = discountAmt;

      final res = await ApiClient.instance.get(
        '/orders/$orderId/payment-preview',
        queryParameters: qp,
      );
      final d = res.data as Map<String, dynamic>;
      state = AsyncValue.data(CheckoutSummary(
        subtotal: double.parse(d['subtotal'].toString()),
        serviceCharge:
            double.parse(d['service_charge_amount'].toString()),
        sst: double.parse(d['sst_amount'].toString()),
        discount: double.parse(d['discount_amount'].toString()),
        grandTotal: double.parse(d['grand_total'].toString()),
        promotionId: resolvedPromoId,
        promoCode: resolvedPromoCode,
      ));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<Payment> checkout({
    required int orderId,
    required String paymentMethod,
    required double cashReceived,
    int? promotionId,
    String? promoCode,
  }) async {
    final body = <String, dynamic>{
      'order_id': orderId,
      'payment_method': paymentMethod,
    };
    if (paymentMethod == 'cash') body['cash_tendered'] = cashReceived;
    if (promotionId != null) body['promotion_id'] = promotionId;
    if (promoCode != null && promoCode.isNotEmpty) {
      body['promo_code'] = promoCode;
    }
    final res = await ApiClient.instance.post('/payments', data: body);
    return Payment.fromJson(res.data as Map<String, dynamic>);
  }

  void reset() => state = const AsyncValue.data(null);
}

final paymentProvider = StateNotifierProvider.autoDispose<PaymentNotifier,
    AsyncValue<CheckoutSummary?>>(
  (_) => PaymentNotifier(),
);

final activePromotionsProvider =
    FutureProvider.autoDispose<List<Promotion>>((ref) async {
  final res = await ApiClient.instance.get('/promotions?active=true');
  return (res.data as List)
      .map((e) => Promotion.fromJson(e as Map<String, dynamic>))
      .toList();
});

final paymentsListProvider =
    FutureProvider.autoDispose<List<Payment>>((ref) async {
  final res = await ApiClient.instance.get('/payments');
  return (res.data as List)
      .map((e) => Payment.fromJson(e as Map<String, dynamic>))
      .toList();
});
