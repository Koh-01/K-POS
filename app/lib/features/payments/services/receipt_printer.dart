import 'dart:async';

import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/models/payment.dart';
import '../../../core/models/order_item.dart';
import '../../../core/models/order.dart';
import '../../../core/models/store_settings.dart';
import '../providers/payment_provider.dart';
import 'escpos_raster.dart';
import 'thermal_receipt_renderer.dart';

class ReceiptPrinter {
  static final _printer = BlueThermalPrinter.instance;
  static const _statusTimeout = Duration(seconds: 3);
  static const _scanTimeout = Duration(seconds: 6);
  // Secure RFCOMM, then the insecure fallback, can each take several seconds.
  static const _connectTimeout = Duration(seconds: 20);
  static const _writeTimeout = Duration(seconds: 8);
  static const _addressKey = 'printer_address';
  static const _nameKey = 'printer_name';
  static const _paperKey = 'printer_paper_mm';

  /// Print jobs and connection attempts run one at a time; two jobs writing
  /// to the socket together interleave bytes and garble both receipts.
  static Future<void> _queue = Future.value();
  static bool _autoConnecting = false;

  static Future<T> _exclusive<T>(Future<T> Function() task) {
    final run = _queue.then((_) => task());
    _queue = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  static Future<List<BluetoothDevice>> getBondedDevices() =>
      _printer.getBondedDevices().timeout(
        _scanTimeout,
        onTimeout: () => throw TimeoutException(
          'Bluetooth device scan timed out. Check that Bluetooth is enabled.',
        ),
      );

  static Future<void> connect(BluetoothDevice device) =>
      _exclusive(() => _connect(device));

  static Future<void> _connect(BluetoothDevice device) async {
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

  static Future<void> savePrinterAddress(String address, {String? name}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_addressKey, address);
    if (name != null) await prefs.setString(_nameKey, name);
  }

  static Future<String?> getSavedAddress() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_addressKey);
  }

  /// Receipt paper width in millimetres (58 or 80).
  static Future<int> getPaperWidthMm() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_paperKey) == 80 ? 80 : 58;
  }

  static Future<void> setPaperWidthMm(int mm) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_paperKey, mm >= 80 ? 80 : 58);
  }

  static Future<int> _paperDots() async =>
      ThermalReceiptRenderer.dotsForPaper(await getPaperWidthMm());

  /// Quietly reconnects to the saved printer: on app start, when the app
  /// returns to the foreground and periodically. Never shows anything and
  /// never asks for permissions — it only reuses a printer the user already
  /// connected in Settings.
  static Future<void> autoConnect() async {
    if (_autoConnecting) return;
    _autoConnecting = true;
    try {
      await _exclusive(() async {
        if (await isConnected ?? false) return;
        await _connectSaved();
      });
    } catch (e) {
      debugPrint('[printer] auto-connect skipped: $e');
    } finally {
      _autoConnecting = false;
    }
  }

  static Future<void> ensureConnected() => _exclusive(_ensureConnected);

  static Future<void> _ensureConnected() async {
    if (await isConnected ?? false) return;
    await _connectSaved();
    if (!(await isConnected ?? false)) {
      throw Exception('Could not connect to the Bluetooth thermal printer.');
    }
  }

  static Future<void> _connectSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final address = prefs.getString(_addressKey);
    if (address == null || address.isEmpty) {
      throw Exception(
        'No Bluetooth thermal printer is configured in POS Settings.',
      );
    }
    // Connecting by address avoids listing paired devices, which on
    // Android 12+ would pop a permission dialog during background reconnects.
    await _connect(BluetoothDevice(prefs.getString(_nameKey), address));
  }

  /// Sends a rendered receipt. If the very first block cannot be written (the
  /// link had silently dropped) it reconnects and retries once. A failure
  /// part-way through is reported instead, so a half receipt is never
  /// followed by an automatic duplicate.
  static Future<void> _printRaster(ReceiptRaster raster) =>
      _exclusive(() async {
        final bands = EscPosRaster.encode(
          raster.rgba,
          raster.width,
          raster.height,
        );
        final job = [EscPosRaster.reset, ...bands, EscPosRaster.feed(3)];
        await _ensureConnected();
        var sent = 0;
        try {
          for (final chunk in job) {
            await _write(chunk);
            sent++;
          }
        } catch (e) {
          if (sent > 0) {
            throw Exception(
              'The printer stopped part-way through. Check it and print again.',
            );
          }
          await disconnect().catchError((_) {});
          await _connectSaved();
          for (final chunk in job) {
            await _write(chunk);
          }
        }
      });

  static Future<void> _write(Uint8List bytes) async {
    await _printer
        .writeBytes(bytes)
        .timeout(
          _writeTimeout,
          onTimeout: () => throw TimeoutException('Printer did not respond.'),
        );
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
    final raster = await ThermalReceiptRenderer.receipt(
      payment: payment,
      items: items,
      storeName: storeName,
      storeAddress: storeAddress,
      storePhone: storePhone,
      settings: settings,
      employeeName: employeeName,
      posName: posName,
      width: await _paperDots(),
    );
    await _printRaster(raster);
  }

  static Future<void> printBill({
    required Order order,
    required CheckoutSummary summary,
    required String storeName,
    String? placeLabel,
    String? storeAddress,
    String? storePhone,
    StoreSettings? settings,
    String? employeeName,
    String? posName,
  }) async {
    final raster = await ThermalReceiptRenderer.bill(
      order: order,
      summary: summary,
      placeLabel: placeLabel,
      storeName: storeName,
      storeAddress: storeAddress,
      storePhone: storePhone,
      settings: settings,
      employeeName: employeeName,
      posName: posName,
      width: await _paperDots(),
    );
    await _printRaster(raster);
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
    final raster = await ThermalReceiptRenderer.salarySlip(
      workerName: workerName,
      position: position,
      year: year,
      month: month,
      amount: amount,
      note: note,
      storeName: storeName,
      width: await _paperDots(),
    );
    await _printRaster(raster);
  }

  static Future<void> testPrint() => _exclusive(() async {
    // Settings must only test the active connection. Automatically trying to
    // reconnect an offline saved printer here can leave the Bluetooth plugin
    // waiting for the socket until Android's much longer system timeout.
    if (!(await isConnected ?? false)) {
      throw StateError(
        'Printer is not connected. Scan and connect it before testing.',
      );
    }
    final mm = await getPaperWidthMm();
    await _printer
        .printCustom('-- TEST PRINT ($mm mm) --', 1, 1)
        .timeout(_writeTimeout);
    await _printer.printNewLine().timeout(_writeTimeout);
    await _printer.printNewLine().timeout(_writeTimeout);
  });
}
