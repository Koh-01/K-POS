import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../../core/models/payment.dart';
import '../../../core/models/order_item.dart';
import '../../../core/models/store_settings.dart';
import '../../../shared/utils/currency_formatter.dart';

class ReceiptPdfService {
  static Future<void> share({
    required Payment payment,
    List<OrderItem> items = const [],
    required String storeName,
    String? storeAddress,
    String? storePhone,
    StoreSettings? settings,
  }) async {
    final doc = pw.Document();

    doc.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(
          80 * PdfPageFormat.mm,
          double.infinity,
          marginAll: 6 * PdfPageFormat.mm,
        ),
        build: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            if (settings != null && settings.receiptHeader.isNotEmpty)
              pw.Align(
                alignment: switch (settings.receiptHeaderAlign) {
                  0 => pw.Alignment.centerLeft,
                  2 => pw.Alignment.centerRight,
                  _ => pw.Alignment.center,
                },
                child: pw.Text(
                  settings.receiptHeader,
                  style: pw.TextStyle(
                    fontSize: switch (settings.receiptHeaderSize) {
                      0 => 9,
                      2 => 14,
                      _ => 11,
                    },
                  ),
                ),
              ),
            pw.Center(
              child: pw.Text(
                storeName,
                style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
            if (storeAddress != null && storeAddress.isNotEmpty)
              pw.Center(
                child: pw.Text(
                  storeAddress,
                  style: const pw.TextStyle(fontSize: 10),
                ),
              ),
            if (storePhone != null && storePhone.isNotEmpty)
              pw.Center(
                child: pw.Text(
                  storePhone,
                  style: const pw.TextStyle(fontSize: 10),
                ),
              ),
            if (settings?.storeSsmNumber?.isNotEmpty ?? false)
              pw.Center(
                child: pw.Text(
                  'SSM No: ${settings!.storeSsmNumber}',
                  style: const pw.TextStyle(fontSize: 9),
                ),
              ),
            if (settings?.taxRegistrationNumber?.isNotEmpty ?? false)
              pw.Center(
                child: pw.Text(
                  'Tax No: ${settings!.taxRegistrationNumber}',
                  style: const pw.TextStyle(fontSize: 9),
                ),
              ),
            pw.SizedBox(height: 6),
            pw.Divider(),
            _row('Order #', '${payment.orderId}'),
            _row(
              '${payment.createdAt.day}/${payment.createdAt.month}/${payment.createdAt.year} '
                  '${payment.createdAt.hour.toString().padLeft(2, '0')}:${payment.createdAt.minute.toString().padLeft(2, '0')}',
              'Receipt No: ${payment.receiptNumber}',
            ),
            _row(
              'Method',
              payment.paymentMethod == 'cash' ? 'Cash' : 'DuitNow QR',
            ),
            if (items.isNotEmpty) ...[
              pw.Divider(),
              ...items.map(
                (item) => _row(
                  item.weight != null
                      ? '${item.productName} ${item.weight!.toStringAsFixed(3)}kg'
                      : '${item.productName} x${item.quantity}',
                  formatRM(item.subtotal),
                ),
              ),
            ],
            pw.Divider(),
            _row('Subtotal', formatRM(payment.subtotal)),
            if (payment.serviceCharge > 0)
              _row('Service Charge', formatRM(payment.serviceCharge)),
            if (payment.sst > 0) _row('SST', formatRM(payment.sst)),
            if (payment.discount > 0)
              _row('Discount', '- ${formatRM(payment.discount)}'),
            pw.Divider(),
            _row(
              'TOTAL',
              formatRM(payment.grandTotal),
              bold: true,
              fontSize: 13,
            ),
            if (payment.cashReceived != null) ...[
              pw.SizedBox(height: 4),
              _row('Cash', formatRM(payment.cashReceived!)),
              _row('Change', formatRM(payment.changeGiven ?? 0)),
            ],
            pw.SizedBox(height: 10),
            pw.Divider(),
            if ((settings?.receiptFooter ?? 'Thank you!').isNotEmpty)
              pw.Center(
                child: pw.Text(
                  settings?.receiptFooter ?? 'Thank you!',
                  style: pw.TextStyle(
                    fontStyle: pw.FontStyle.italic,
                    fontSize: 11,
                  ),
                ),
              ),
            pw.SizedBox(height: 18 * PdfPageFormat.mm),
          ],
        ),
      ),
    );

    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'receipt_${payment.orderId}.pdf',
    );
  }

  static pw.Widget _row(
    String label,
    String value, {
    bool bold = false,
    double fontSize = 11,
  }) {
    final style = pw.TextStyle(
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      fontSize: fontSize,
    );
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: style),
          pw.Text(value, style: style),
        ],
      ),
    );
  }
}
