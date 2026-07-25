import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../../core/models/payment.dart';
import '../../../core/models/order_item.dart';
import '../../../shared/utils/currency_formatter.dart';

class ReceiptPdfService {
  static Future<void> share({
    required Payment payment,
    List<OrderItem> items = const [],
    required String storeName,
    String? storeAddress,
    String? storePhone,
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
            pw.Center(
              child: pw.Text(storeName,
                  style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold, fontSize: 14)),
            ),
            if (storeAddress != null && storeAddress.isNotEmpty)
              pw.Center(
                  child: pw.Text(storeAddress,
                      style: const pw.TextStyle(fontSize: 10))),
            if (storePhone != null && storePhone.isNotEmpty)
              pw.Center(
                  child: pw.Text(storePhone,
                      style: const pw.TextStyle(fontSize: 10))),
            pw.SizedBox(height: 6),
            pw.Divider(),
            _row('Receipt #', '${payment.id}'),
            _row('Order #', '${payment.orderId}'),
            _row(
              'Date',
              '${payment.createdAt.day}/${payment.createdAt.month}/${payment.createdAt.year} '
                  '${payment.createdAt.hour.toString().padLeft(2, '0')}:${payment.createdAt.minute.toString().padLeft(2, '0')}',
            ),
            _row('Method',
                payment.paymentMethod == 'cash' ? 'Cash' : 'DuitNow QR'),
            if (items.isNotEmpty) ...[
              pw.Divider(),
              ...items.map((item) => _row(
                    '${item.productName} x${item.quantity}',
                    formatRM(item.subtotal),
                  )),
            ],
            pw.Divider(),
            _row('Subtotal', formatRM(payment.subtotal)),
            if (payment.serviceCharge > 0)
              _row('Service Charge', formatRM(payment.serviceCharge)),
            if (payment.sst > 0) _row('SST', formatRM(payment.sst)),
            if (payment.discount > 0)
              _row('Discount', '- ${formatRM(payment.discount)}'),
            pw.Divider(),
            _row('TOTAL', formatRM(payment.grandTotal), bold: true, fontSize: 13),
            if (payment.cashReceived != null) ...[
              pw.SizedBox(height: 4),
              _row('Cash', formatRM(payment.cashReceived!)),
              _row('Change', formatRM(payment.changeGiven ?? 0)),
            ],
            pw.SizedBox(height: 10),
            pw.Divider(),
            pw.Center(
              child: pw.Text('Thank you!',
                  style: pw.TextStyle(
                      fontStyle: pw.FontStyle.italic, fontSize: 11)),
            ),
          ],
        ),
      ),
    );

    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'receipt_${payment.orderId}.pdf',
    );
  }

  static pw.Widget _row(String label, String value,
      {bool bold = false, double fontSize = 11}) {
    final style = pw.TextStyle(
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        fontSize: fontSize);
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
