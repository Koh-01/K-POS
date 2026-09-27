import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/models/order.dart';
import '../../../core/models/order_item.dart';
import '../../../core/models/payment.dart';
import '../../../core/models/store_settings.dart';
import '../../../shared/utils/currency_formatter.dart';
import '../providers/payment_provider.dart';

/// Draws receipts with Flutter fonts before sending them to an ESC/POS
/// printer. This keeps Chinese text legible even when the printer has no
/// Chinese code page installed.
class ThermalReceiptRenderer {
  static const int width = 384;

  static Future<Uint8List> bill({
    required Order order,
    required CheckoutSummary summary,
    required String storeName,
    String? storeAddress,
    String? storePhone,
    StoreSettings? settings,
    String? employeeName,
    String? posName,
  }) {
    final orderLabel = order.orderType == OrderTypes.takeAway
        ? 'Takeaway'
        : (order.tableName ?? 'Table ${order.tableId ?? ''}').trim();
    return _ReceiptCanvas().render(
      storeName: storeName,
      storeAddress: storeAddress,
      storePhone: storePhone,
      ssmNumber: settings?.storeSsmNumber,
      taxNumber: settings?.taxRegistrationNumber,
      headerText: settings?.receiptHeader,
      headerSize: settings?.receiptHeaderSize ?? 1,
      headerAlign: settings?.receiptHeaderAlign ?? 1,
      title: '账单',
      orderLabel: orderLabel,
      employeeName: employeeName,
      posName: posName,
      serviceLabel: order.orderType == OrderTypes.takeAway
          ? 'Takeaway'
          : 'Dine in',
      items: order.items,
      subtotal: summary.subtotal,
      serviceCharge: summary.serviceCharge,
      sst: summary.sst,
      discount: summary.discount,
      total: summary.grandTotal,
      footer: _footer(settings),
      printedAt: DateTime.now(),
    );
  }

  static Future<Uint8List> receipt({
    required Payment payment,
    required List<OrderItem> items,
    required String storeName,
    String? storeAddress,
    String? storePhone,
    StoreSettings? settings,
    String? employeeName,
    String? posName,
  }) {
    final method = switch (payment.paymentMethod) {
      'cash' => 'Cash',
      'duitnow' => 'DuitNow QR',
      'card' => 'Card',
      _ => payment.paymentMethod,
    };
    return _ReceiptCanvas().render(
      storeName: storeName,
      storeAddress: storeAddress,
      storePhone: storePhone,
      ssmNumber: settings?.storeSsmNumber,
      taxNumber: settings?.taxRegistrationNumber,
      headerText: settings?.receiptHeader,
      headerSize: settings?.receiptHeaderSize ?? 1,
      headerAlign: settings?.receiptHeaderAlign ?? 1,
      title: '收据 / RECEIPT',
      receiptNumber: payment.receiptNumber,
      orderLabel: '#${payment.orderId}',
      employeeName: employeeName,
      posName: posName,
      serviceLabel: method,
      items: items,
      subtotal: payment.subtotal,
      serviceCharge: payment.serviceCharge,
      sst: payment.sst,
      discount: payment.discount,
      total: payment.grandTotal,
      cashReceived: payment.cashReceived,
      changeGiven: payment.changeGiven,
      footer: _footer(settings),
      printedAt: payment.createdAt,
    );
  }

  static Future<Uint8List> salarySlip({
    required String workerName,
    required String position,
    required int year,
    required int month,
    required double amount,
    String? note,
    required String storeName,
  }) {
    return _ReceiptCanvas().renderSalarySlip(
      workerName: workerName,
      position: position,
      year: year,
      month: month,
      amount: amount,
      note: note,
      storeName: storeName,
      printedAt: DateTime.now(),
    );
  }

  static String _footer(StoreSettings? settings) {
    final configured = settings?.receiptFooter.trim() ?? '';
    return configured.isEmpty ? 'Thank You. Please come again.' : configured;
  }
}

class _ReceiptCanvas {
  static const double _margin = 15;
  static const List<String> _fontFallback = [
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Noto Sans CJK TC',
    'sans-serif',
  ];

  final ui.PictureRecorder _recorder = ui.PictureRecorder();
  late final Canvas _canvas = Canvas(_recorder);
  double _y = 12;

  double get _contentWidth => ThermalReceiptRenderer.width - (_margin * 2);

  Future<Uint8List> render({
    required String storeName,
    String? storeAddress,
    String? storePhone,
    String? ssmNumber,
    String? taxNumber,
    String? headerText,
    int headerSize = 1,
    int headerAlign = 1,
    required String title,
    String? receiptNumber,
    required String orderLabel,
    String? employeeName,
    String? posName,
    required String serviceLabel,
    required List<OrderItem> items,
    required double subtotal,
    required double serviceCharge,
    required double sst,
    required double discount,
    required double total,
    double? cashReceived,
    double? changeGiven,
    required String footer,
    required DateTime printedAt,
  }) async {
    _canvas.drawRect(
      Rect.fromLTWH(0, 0, ThermalReceiptRenderer.width.toDouble(), 20000),
      Paint()..color = Colors.white,
    );

    if (headerText?.trim().isNotEmpty ?? false) {
      _text(
        headerText!.trim(),
        size: switch (headerSize) {
          0 => 17,
          2 => 25,
          _ => 20,
        },
        weight: FontWeight.w600,
        align: switch (headerAlign) {
          0 => TextAlign.left,
          2 => TextAlign.right,
          _ => TextAlign.center,
        },
      );
      _space(5);
    }

    final nameParts = _splitStoreName(storeName);
    if (nameParts.english.isNotEmpty) {
      _text(
        nameParts.english,
        size: 25,
        weight: FontWeight.w700,
        align: TextAlign.center,
      );
    }
    if (nameParts.chinese.isNotEmpty) {
      _text(
        nameParts.chinese,
        size: 24,
        weight: FontWeight.w700,
        align: TextAlign.center,
      );
    }
    if (nameParts.english.isEmpty && nameParts.chinese.isEmpty) {
      _text(
        storeName,
        size: 25,
        weight: FontWeight.w700,
        align: TextAlign.center,
      );
    }
    if (storeAddress?.trim().isNotEmpty ?? false) {
      _text(storeAddress!.trim(), size: 19, align: TextAlign.center);
    }
    if (storePhone?.trim().isNotEmpty ?? false) {
      _text('Tel: ${storePhone!.trim()}', size: 19, align: TextAlign.center);
    }
    if (ssmNumber?.trim().isNotEmpty ?? false) {
      _text('SSM No: ${ssmNumber!.trim()}', size: 17, align: TextAlign.center);
    }
    if (taxNumber?.trim().isNotEmpty ?? false) {
      _text('Tax No: ${taxNumber!.trim()}', size: 17, align: TextAlign.center);
    }

    _space(12);
    _text(title, size: 27, weight: FontWeight.w700, align: TextAlign.center);
    _space(12);
    _text('订单: $orderLabel', size: 20, weight: FontWeight.w600);
    if (employeeName?.trim().isNotEmpty ?? false) {
      _text('员工: ${employeeName!.trim()}', size: 20);
    }
    if (posName?.trim().isNotEmpty ?? false) {
      _text('POS: ${posName!.trim()}', size: 20);
    }
    _separator();
    _text(serviceLabel, size: 20, weight: FontWeight.w600);
    _separator();

    for (final item in items) {
      _leftRight(
        item.productName,
        formatRM(item.subtotal),
        size: 21,
        weight: FontWeight.w600,
      );
      final detail = item.weight != null
          ? '${item.weight!.toStringAsFixed(3)} kg x ${formatRM(item.unitPrice)}/kg'
          : '${item.quantity} x ${formatRM(item.unitPrice)}';
      _text(detail, size: 19);
      _space(9);
    }

    _separator();
    final hasAdjustments = serviceCharge > 0 || sst > 0 || discount > 0;
    if (hasAdjustments) {
      _leftRight('小计 / Subtotal', formatRM(subtotal), size: 19);
      if (serviceCharge > 0) {
        _leftRight('服务费 / Service', formatRM(serviceCharge), size: 19);
      }
      if (sst > 0) _leftRight('SST', formatRM(sst), size: 19);
      if (discount > 0) {
        _leftRight('折扣 / Discount', '-${formatRM(discount)}', size: 19);
      }
      _space(4);
    }
    _leftRight('应收', formatRM(total), size: 28, weight: FontWeight.w800);
    if (cashReceived != null) {
      _leftRight('现金 / Cash', formatRM(cashReceived), size: 19);
      _leftRight('找零 / Change', formatRM(changeGiven ?? 0), size: 19);
    }
    _separator();
    _text(footer, size: 19, align: TextAlign.center);
    _space(5);
    final dateText = DateFormat('dd/MM/yyyy HH:mm').format(printedAt.toLocal());
    if (receiptNumber != null && receiptNumber.isNotEmpty) {
      _leftRight(dateText, 'Receipt No: $receiptNumber', size: 17);
    } else {
      _text(dateText, size: 18, align: TextAlign.center);
    }
    // Thermal printers cut close to the last raster line. Keep enough blank
    // paper below the important details so tearing cannot remove them.
    _space(80);

    return _finish();
  }

  Future<Uint8List> renderSalarySlip({
    required String workerName,
    required String position,
    required int year,
    required int month,
    required double amount,
    String? note,
    required String storeName,
    required DateTime printedAt,
  }) async {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    _canvas.drawRect(
      Rect.fromLTWH(0, 0, ThermalReceiptRenderer.width.toDouble(), 20000),
      Paint()..color = Colors.white,
    );
    final nameParts = _splitStoreName(storeName);
    if (nameParts.english.isNotEmpty) {
      _text(
        nameParts.english,
        size: 25,
        weight: FontWeight.w700,
        align: TextAlign.center,
      );
    }
    if (nameParts.chinese.isNotEmpty) {
      _text(
        nameParts.chinese,
        size: 24,
        weight: FontWeight.w700,
        align: TextAlign.center,
      );
    }
    _space(10);
    _text(
      'SALARY SLIP / 薪资单',
      size: 25,
      weight: FontWeight.w700,
      align: TextAlign.center,
    );
    _separator();
    _leftRight('Name / 姓名', workerName, size: 20);
    if (position.trim().isNotEmpty) {
      _leftRight('Position / 职位', position.trim(), size: 20);
    }
    _leftRight('Period / 月份', '${months[month - 1]} $year', size: 20);
    _separator();
    _leftRight(
      'Salary / 薪资',
      formatRM(amount),
      size: 27,
      weight: FontWeight.w800,
    );
    if (note?.trim().isNotEmpty ?? false) {
      _space(7);
      _text('Note / 备注: ${note!.trim()}', size: 19);
    }
    _separator();
    _text('Received by / 收款人:', size: 19);
    _space(32);
    _text('Signature / 签名: __________________', size: 19);
    _space(12);
    _text(
      DateFormat('dd/MM/yyyy HH:mm').format(printedAt.toLocal()),
      size: 17,
      align: TextAlign.center,
    );
    _space(80);

    return _finish();
  }

  Future<Uint8List> _finish() async {
    final picture = _recorder.endRecording();
    final image = await picture.toImage(
      ThermalReceiptRenderer.width,
      _y.ceil().clamp(1, 20000),
    );
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (byteData == null) throw StateError('Could not render receipt image.');
    return byteData.buffer.asUint8List();
  }

  void _text(
    String value, {
    required double size,
    FontWeight weight = FontWeight.w400,
    TextAlign align = TextAlign.left,
  }) {
    final painter = _painter(
      value,
      size: size,
      weight: weight,
      align: align,
      maxWidth: _contentWidth,
    );
    painter.paint(_canvas, Offset(_margin, _y));
    _y += painter.height + 2;
  }

  void _leftRight(
    String left,
    String right, {
    required double size,
    FontWeight weight = FontWeight.w400,
  }) {
    final rightPainter = _painter(
      right,
      size: size,
      weight: weight,
      align: TextAlign.right,
      maxWidth: 132,
    );
    final leftWidth = _contentWidth - rightPainter.width - 10;
    final leftPainter = _painter(
      left,
      size: size,
      weight: weight,
      maxWidth: leftWidth.clamp(100, _contentWidth),
    );
    leftPainter.paint(_canvas, Offset(_margin, _y));
    rightPainter.paint(
      _canvas,
      Offset(ThermalReceiptRenderer.width - _margin - rightPainter.width, _y),
    );
    _y +=
        (leftPainter.height > rightPainter.height
            ? leftPainter.height
            : rightPainter.height) +
        2;
  }

  TextPainter _painter(
    String value, {
    required double size,
    required FontWeight weight,
    TextAlign align = TextAlign.left,
    required double maxWidth,
  }) {
    return TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: Colors.black,
          fontSize: size,
          fontWeight: weight,
          height: 1.18,
          fontFamilyFallback: _fontFallback,
        ),
      ),
      textAlign: align,
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
  }

  void _separator() {
    _space(5);
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1.5;
    for (
      double x = _margin;
      x < ThermalReceiptRenderer.width - _margin;
      x += 7
    ) {
      _canvas.drawLine(Offset(x, _y), Offset(x + 3.5, _y), paint);
    }
    _y += 8;
  }

  void _space(double height) => _y += height;

  ({String english, String chinese}) _splitStoreName(String value) {
    final matches = RegExp(r'[\u3400-\u9FFF]+').allMatches(value);
    final chinese = matches.map((match) => match.group(0)!).join(' ');
    final english = value
        .replaceAll(RegExp(r'[\u3400-\u9FFF]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return (english: english, chinese: chinese);
  }
}
