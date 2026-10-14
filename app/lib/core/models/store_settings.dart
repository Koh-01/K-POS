class StoreSettings {
  final String storeName;
  final String? storeAddress;
  final String? storePhone;
  final String? storeEmail;
  final String? storeSsmNumber;
  final String? taxRegistrationNumber;
  final double sstRate;
  final double serviceChargeRate;
  final bool enableSst;
  final bool enableServiceCharge;
  final bool paymentToCashRecord;
  final bool requireSalarySignature;
  final String? duitnowQrImageUrl;
  final String? storeLogoPath;
  final String receiptHeader;
  final int receiptHeaderSize;
  final int receiptHeaderAlign;
  final String receiptFooter;
  final int receiptFooterSize;
  final int receiptFooterAlign;
  final bool receiptShowLogo;

  /// Categories whose items are shown on open-order cards, e.g. a hotpot
  /// restaurant's soup bases. Empty = show the first items of the order.
  final List<int> orderCardCategoryIds;

  const StoreSettings({
    required this.storeName,
    this.storeAddress,
    this.storePhone,
    this.storeEmail,
    this.storeSsmNumber,
    this.taxRegistrationNumber,
    required this.sstRate,
    required this.serviceChargeRate,
    required this.enableSst,
    required this.enableServiceCharge,
    this.paymentToCashRecord = false,
    this.requireSalarySignature = false,
    this.duitnowQrImageUrl,
    this.storeLogoPath,
    this.receiptHeader = '',
    this.receiptHeaderSize = 1,
    this.receiptHeaderAlign = 1,
    this.receiptFooter = '',
    this.receiptFooterSize = 0,
    this.receiptFooterAlign = 1,
    this.receiptShowLogo = false,
    this.orderCardCategoryIds = const [],
  });

  factory StoreSettings.fromJson(Map<String, dynamic> json) => StoreSettings(
    storeName: json['store_name'] as String? ?? '',
    storeAddress: json['store_address'] as String?,
    storePhone: json['store_phone'] as String?,
    storeEmail: json['store_email'] as String?,
    storeSsmNumber: json['store_ssm_number'] as String?,
    taxRegistrationNumber: json['tax_registration_number'] as String?,
    sstRate: json['sst_rate'] != null
        ? double.parse(json['sst_rate'].toString())
        : 0.06,
    serviceChargeRate: json['service_charge_rate'] != null
        ? double.parse(json['service_charge_rate'].toString())
        : 0.10,
    enableSst: json['sst_enabled'] as bool? ?? false,
    enableServiceCharge: json['service_charge_enabled'] as bool? ?? false,
    paymentToCashRecord: json['payment_to_cash_record'] as bool? ?? false,
    requireSalarySignature: json['require_salary_signature'] as bool? ?? false,
    duitnowQrImageUrl: json['duitnow_qr_image_url'] as String?,
    storeLogoPath: json['store_logo_path'] as String?,
    receiptHeader: json['receipt_header'] as String? ?? '',
    receiptHeaderSize: json['receipt_header_size'] as int? ?? 1,
    receiptHeaderAlign: json['receipt_header_align'] as int? ?? 1,
    receiptFooter: json['receipt_footer'] as String? ?? '',
    receiptFooterSize: json['receipt_footer_size'] as int? ?? 0,
    receiptFooterAlign: json['receipt_footer_align'] as int? ?? 1,
    receiptShowLogo: json['receipt_show_logo'] as bool? ?? false,
    orderCardCategoryIds: [
      for (final id in (json['order_card_category_ids'] as List? ?? const []))
        if (id is int) id,
    ],
  );

  static const StoreSettings defaults = StoreSettings(
    storeName: '',
    sstRate: 0.06,
    serviceChargeRate: 0.10,
    enableSst: false,
    enableServiceCharge: false,
  );
}
