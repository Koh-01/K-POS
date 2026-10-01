import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/core/models/order_item.dart';
import 'package:pos_app/core/models/payment.dart';
import 'package:pos_app/features/payments/services/escpos_raster.dart';
import 'package:pos_app/features/payments/services/thermal_receipt_renderer.dart';

Uint8List _image(int width, int height, {bool Function(int x, int y)? dark}) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      final v = (dark?.call(x, y) ?? false) ? 0 : 255;
      rgba
        ..[i] = v
        ..[i + 1] = v
        ..[i + 2] = v
        ..[i + 3] = 255;
    }
  }
  return rgba;
}

void main() {
  test('raster bands use little-endian width/height (tall receipts)', () {
    // 300 rows: the old plugin encoded any height >= 256 incorrectly.
    final bands = EscPosRaster.encode(_image(384, 300), 384, 300);
    expect(bands.length, 3); // 128 + 128 + 44
    final last = bands.last;
    expect(last.sublist(0, 4), [0x1D, 0x76, 0x30, 0x00]);
    expect(last[4] | (last[5] << 8), 48); // 384 dots = 48 bytes per row
    expect(last[6] | (last[7] << 8), 44);
    expect(last.length, 8 + 48 * 44);
  });

  test('dark pixels map to set bits, MSB first', () {
    final rgba = _image(16, 1, dark: (x, _) => x == 0 || x == 9);
    final band = EscPosRaster.encode(rgba, 16, 1).single;
    expect(band.sublist(8), [0x80, 0x40]);
  });

  test('widths that are not a multiple of 8 are padded', () {
    final band = EscPosRaster.encode(_image(10, 2), 10, 2).single;
    expect(band[4], 2);
    expect(band.length, 8 + 2 * 2);
  });

  Future<ReceiptRaster> render(int width) => ThermalReceiptRenderer.receipt(
    payment: Payment(
      id: 1,
      orderId: 7,
      paymentMethod: 'cash',
      subtotal: 10,
      serviceCharge: 0,
      sst: 0,
      discount: 0,
      grandTotal: 10,
      isVoided: false,
      createdAt: DateTime(2026, 10, 1, 12),
    ),
    items: const [
      OrderItem(productId: 1, productName: 'Tea', quantity: 1, unitPrice: 10),
    ],
    storeName: 'ABC',
    width: width,
  );

  test('receipt width follows the paper setting', () async {
    expect((await render(ThermalReceiptRenderer.dots58mm)).width, 384);
    expect((await render(ThermalReceiptRenderer.dots80mm)).width, 576);
  });

  test('store name is centred, not flush left', () async {
    final raster = await render(ThermalReceiptRenderer.dots80mm);
    // The store name is the first text block; find its dark pixels.
    var minX = raster.width, maxX = -1;
    for (var y = 0; y < 45; y++) {
      for (var x = 0; x < raster.width; x++) {
        final i = (y * raster.width + x) * 4;
        if (raster.rgba[i] < 128) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
        }
      }
    }
    expect(maxX, greaterThan(minX), reason: 'store name was not drawn');
    final centre = (minX + maxX) / 2;
    expect((centre - raster.width / 2).abs(), lessThan(12));
  });
}
