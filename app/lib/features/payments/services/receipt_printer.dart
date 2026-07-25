import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/models/payment.dart';
import '../../../core/models/order_item.dart';
import '../../../core/models/order.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../providers/payment_provider.dart';

class ReceiptPrinter {
  static final _printer = BlueThermalPrinter.instance;

  static Future<List<BluetoothDevice>> getBondedDevices() =>
      _printer.getBondedDevices();

  static Future<void> connect(BluetoothDevice device) =>
      _printer.connect(device);

  static Future<void> disconnect() => _printer.disconnect();

  static Future<bool?> get isConnected => _printer.isConnected;

  static Future<void> savePrinterAddress(String address) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('printer_address', address);
  }

  static Future<String?> getSavedAddress() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('printer_address');
  }

  static Future<void> print({
    required Payment payment,
    List<OrderItem> items = const [],
    required String storeName,
    String? storeAddress,
    String? storePhone,
  }) async {
    final connected = await _printer.isConnected ?? false;
    if (!connected) throw Exception('Printer not connected');

    // align: 0=left, 1=center, 2=right | size: 0=small, 1=normal, 2=large
    await _printer.printNewLine();
    await _printer.printCustom(storeName, 2, 1);
    if (storeAddress != null) await _printer.printCustom(storeAddress, 1, 1);
    if (storePhone != null) await _printer.printCustom(storePhone, 1, 1);
    await _printer.printNewLine();
    await _printer.printCustom('Order #${payment.orderId}', 1, 0);
    await _printer.printCustom(switch (payment.paymentMethod) {
      'cash' => 'Cash',
      'duitnow' => 'DuitNow QR',
      'card' => 'Card',
      _ => payment.paymentMethod,
    }, 1, 0);
    await _printer.printCustom('--------------------------------', 1, 0);
    if (items.isNotEmpty) {
      for (final item in items) {
        await _printer.printLeftRight(
            '${item.productName} x${item.quantity}', formatRM(item.subtotal), 1);
      }
      await _printer.printCustom('--------------------------------', 1, 0);
    }
    await _printer.printLeftRight('Subtotal', formatRM(payment.subtotal), 1);
    if (payment.serviceCharge > 0) {
      await _printer.printLeftRight(
          'Service Charge', formatRM(payment.serviceCharge), 1);
    }
    if (payment.sst > 0) {
      await _printer.printLeftRight('SST', formatRM(payment.sst), 1);
    }
    if (payment.discount > 0) {
      await _printer.printLeftRight(
          'Discount', '- ${formatRM(payment.discount)}', 1);
    }
    await _printer.printCustom('--------------------------------', 1, 0);
    await _printer.printLeftRight('TOTAL', formatRM(payment.grandTotal), 2);
    if (payment.cashReceived != null) {
      await _printer.printLeftRight(
          'Cash', formatRM(payment.cashReceived!), 1);
      await _printer.printLeftRight(
          'Change', formatRM(payment.changeGiven ?? 0), 1);
    }
    await _printer.printNewLine();
    await _printer.printCustom('Thank you!', 1, 1);
    await _printer.printNewLine();
    await _printer.printNewLine();
    await _printer.printNewLine();
  }

  static Future<void> printBill({
    required Order order,
    required CheckoutSummary summary,
    required String storeName,
    String? storeAddress,
    String? storePhone,
  }) async {
    final connected = await _printer.isConnected ?? false;
    if (!connected) throw Exception('Printer not connected');

    final label = order.orderType == 'takeaway'
        ? 'Takeaway'
        : (order.tableName ?? 'Table ${order.tableId}');

    await _printer.printNewLine();
    await _printer.printCustom(storeName, 2, 1);
    if (storeAddress != null) await _printer.printCustom(storeAddress, 1, 1);
    if (storePhone != null) await _printer.printCustom(storePhone, 1, 1);
    await _printer.printNewLine();
    await _printer.printCustom('** BILL **', 1, 1);
    await _printer.printCustom(label, 1, 0);
    await _printer.printCustom('--------------------------------', 1, 0);
    for (final item in order.items) {
      await _printer.printLeftRight(
          '${item.productName} x${item.quantity}', formatRM(item.subtotal), 1);
    }
    await _printer.printCustom('--------------------------------', 1, 0);
    await _printer.printLeftRight('Subtotal', formatRM(summary.subtotal), 1);
    if (summary.serviceCharge > 0) {
      await _printer.printLeftRight(
          'Service Charge', formatRM(summary.serviceCharge), 1);
    }
    if (summary.sst > 0) {
      await _printer.printLeftRight('SST', formatRM(summary.sst), 1);
    }
    if (summary.discount > 0) {
      await _printer.printLeftRight(
          'Discount', '- ${formatRM(summary.discount)}', 1);
    }
    await _printer.printCustom('--------------------------------', 1, 0);
    await _printer.printLeftRight('TOTAL', formatRM(summary.grandTotal), 2);
    await _printer.printNewLine();
    await _printer.printNewLine();
    await _printer.printNewLine();
  }

  static Future<void> printSalarySlip({
    required String workerName,
    required String position,
    required int year,
    required int month,
    required double amount,
    String? note,
    required String storeName,
  }) async {
    final connected = await _printer.isConnected ?? false;
    if (!connected) throw Exception('Printer not connected');

    const months = [
      'January','February','March','April','May','June',
      'July','August','September','October','November','December'
    ];

    await _printer.printNewLine();
    await _printer.printCustom(storeName, 2, 1);
    await _printer.printNewLine();
    await _printer.printCustom('** SALARY SLIP **', 1, 1);
    await _printer.printCustom('${months[month - 1]} $year', 1, 1);
    await _printer.printCustom('--------------------------------', 1, 0);
    await _printer.printLeftRight('Name', workerName, 1);
    if (position.isNotEmpty) {
      await _printer.printLeftRight('Position', position, 1);
    }
    await _printer.printCustom('--------------------------------', 1, 0);
    await _printer.printLeftRight('Salary', formatRM(amount), 2);
    if (note != null && note.isNotEmpty) {
      await _printer.printCustom('Note: $note', 1, 0);
    }
    await _printer.printCustom('--------------------------------', 1, 0);
    await _printer.printNewLine();
    await _printer.printCustom('Received by:', 1, 0);
    await _printer.printNewLine();
    await _printer.printCustom('Signature: ___________________', 1, 0);
    await _printer.printNewLine();
    final now = DateTime.now();
    final printed =
        'Printed: ${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    await _printer.printCustom(printed, 0, 0);
    await _printer.printNewLine();
    await _printer.printNewLine();
    await _printer.printNewLine();
  }

  static Future<void> testPrint() async {
    final connected = await _printer.isConnected ?? false;
    if (!connected) throw Exception('Printer not connected');
    await _printer.printCustom('-- TEST PRINT --', 1, 1);
    await _printer.printNewLine();
    await _printer.printNewLine();
  }
}
