import 'package:intl/intl.dart';

final _fmt = NumberFormat.currency(locale: 'ms_MY', symbol: 'RM ');

String formatRM(double amount) => _fmt.format(amount);

/// Quantity without trailing zeros: "3.000" -> "3", "1.250" -> "1.25".
String formatQty(Object? value) {
  final qty = double.tryParse('${value ?? 0}') ?? 0;
  if (qty == qty.roundToDouble()) return qty.toStringAsFixed(0);
  return qty.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
}
