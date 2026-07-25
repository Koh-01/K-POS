import 'package:intl/intl.dart';

final _fmt = NumberFormat.currency(locale: 'ms_MY', symbol: 'RM ');

String formatRM(double amount) => _fmt.format(amount);
