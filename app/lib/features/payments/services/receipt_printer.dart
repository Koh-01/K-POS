import 'dart:async';

import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/models/payment.dart';
import '../../../core/models/order_item.dart';
import '../../../core/models/order.dart';
import '../../../core/models/store_settings.dart';
import '../providers/payment_provider.dart';
import 'thermal_receipt_renderer.dart';

class ReceiptPrinter {
  static final _printer = BlueThermalPrinter.instance;
  static const _statusTimeout = Duration(seconds: 3);
  static const _scanTimeout = Duration(seconds: 6);
  static const _connectTimeout = Duration(seconds: 12);
  static const _printTimeout = Duration(seconds: 8);

  static Future<List<BluetoothDevice>> getBondedDevices() =>
      _printer.getBondedDevices().timeout(
        _scanTimeout,
        onTimeout: () => throw TimeoutException(
          'Bluetooth device scan timed out. Check that Bluetooth is enabled.',
        ),
      );

  static Future<void> connect(BluetoothDevice device) async {
    await _printer
        .connect(device)
        .timeout(
          _connectTimeout,
          onTimeout: () => throw TimeoutException(
            'Printer connection timed out. Check that the printer is on and nearby.',
          ),
        );
  }

  static Future<void> disconnect() async {
    await _printer.disconnect().timeout(_statusTimeout);
  }

  static Future<bool?> get isConnected =>
      _printer.isConnected.timeout(_statusTimeout, onTimeout: () => false);

  static Future<void> savePrinterAddress(String address) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('printer_address', address);
  }

  static Future<String?> getSavedAddress() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('printer_address');
  }

  static Future<void> ensureConnected() async {
    if (await isConnected ?? false) return;

    final savedAddress = await getSavedAddress();
    if (savedAddress == null || savedAddress.isEmpty) {
      throw Exception(
        'No Bluetooth thermal printer is configured in POS Settings.',
      );
    }

    final devices = await getBondedDevices();
    BluetoothDevice? savedDevice;
    for (final device in devices) {
      if (device.address == savedAddress) {
        savedDevice = device;
        break;
      }
    }
    if (savedDevice == null) {
      throw Exception(
        'The saved Bluetooth thermal printer is no longer paired with this device.',
      );
    }

    await connect(savedDevice);
    if (!(await isConnected ?? false)) {
      throw Exception('Could not connect to the Bluetooth thermal printer.');
    }
  }

  static Future<void> print({
    required Payment payment,
    List<OrderItem> items = const [],
    required String storeName,
    String? storeAddress,
    String? storePhone,
    StoreSettings? settings,
    String? employeeName,
    String? posName,
  }) async {
    final image = await ThermalReceiptRenderer.receipt(
      payment: payment,
      items: items,
      storeName: storeName,
      storeAddress: storeAddress,
      storePhone: storePhone,
      settings: settings,
      employeeName: employeeName,
      posName: posName,
    );
    await ensureConnected();
    await _printer.printImageBytes(image);
    await _printer.printNewLine();
  }

  static Future<void> printBill({
    required Order order,
    required CheckoutSummary summary,
    required String storeName,
    String? storeAddress,
    String? storePhone,
    StoreSettings? settings,
    String? employeeName,
    String? posName,
  }) async {
    final image = await ThermalReceiptRenderer.bill(
      order: order,
      summary: summary,
      storeName: storeName,
      storeAddress: storeAddress,
      storePhone: storePhone,
      settings: settings,
      employeeName: employeeName,
      posName: posName,
    );
    await ensureConnected();
    await _printer.printImageBytes(image);
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
    final image = await ThermalReceiptRenderer.salarySlip(
      workerName: workerName,
      position: position,
      year: year,
      month: month,
      amount: amount,
      note: note,
      storeName: storeName,
    );
    await ensureConnected();
    await _printer.printImageBytes(image).timeout(_printTimeout);
    await _printer.printNewLine().timeout(_printTimeout);
  }

  static Future<void> testPrint() async {
    // Settings must only test the active connection. Automatically trying to
    // reconnect an offline saved printer here can leave the Bluetooth plugin
    // waiting for the socket until Android's much longer system timeout.
    if (!(await isConnected ?? false)) {
      throw StateError(
        'Printer is not connected. Scan and connect it before testing.',
      );
    }
    await _printer.printCustom('-- TEST PRINT --', 1, 1).timeout(_printTimeout);
    await _printer.printNewLine().timeout(_printTimeout);
    await _printer.printNewLine().timeout(_printTimeout);
  }
}
