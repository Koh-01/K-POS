import 'dart:typed_data';

/// Converts a rendered receipt into ESC/POS raster commands (`GS v 0`).
///
/// The image is split into horizontal bands so that cheap Bluetooth printers
/// with small receive buffers are never sent one huge block, which is what
/// used to make long receipts stall or print garbage halfway through.
abstract final class EscPosRaster {
  /// Rows per `GS v 0` command.
  static const int bandHeight = 128;

  /// Channel value above which a pixel counts as white paper.
  static const int _whiteThreshold = 160;

  /// ESC @ — reset the printer so styles left over from a previous job
  /// (alignment, double size, ...) cannot shift this receipt.
  static final Uint8List reset = Uint8List.fromList([0x1B, 0x40]);

  /// ESC d n — feed [lines] blank lines so the tear bar clears the text.
  static Uint8List feed(int lines) => Uint8List.fromList([0x1B, 0x64, lines]);

  /// Encodes RGBA pixels ([width] x [height]) into banded raster commands.
  static List<Uint8List> encode(Uint8List rgba, int width, int height) {
    if (rgba.length < width * height * 4) {
      throw ArgumentError('RGBA buffer is smaller than $width x $height');
    }
    final bytesPerRow = (width + 7) >> 3;
    final bands = <Uint8List>[];
    for (var top = 0; top < height; top += bandHeight) {
      final rows = (height - top) < bandHeight ? height - top : bandHeight;
      final band = Uint8List(8 + bytesPerRow * rows);
      band
        ..[0] = 0x1D
        ..[1] = 0x76
        ..[2] = 0x30
        ..[3] = 0x00
        ..[4] = bytesPerRow & 0xFF
        ..[5] = (bytesPerRow >> 8) & 0xFF
        ..[6] = rows & 0xFF
        ..[7] = (rows >> 8) & 0xFF;
      var out = 8;
      for (var y = top; y < top + rows; y++) {
        final rowStart = y * width * 4;
        for (var byteIndex = 0; byteIndex < bytesPerRow; byteIndex++) {
          var bits = 0;
          for (var bit = 0; bit < 8; bit++) {
            final x = (byteIndex << 3) + bit;
            if (x < width && _isDark(rgba, rowStart + x * 4)) {
              bits |= 0x80 >> bit;
            }
          }
          band[out++] = bits;
        }
      }
      bands.add(band);
    }
    return bands;
  }

  static bool _isDark(Uint8List rgba, int i) {
    // Transparent pixels are blank paper.
    if (rgba[i + 3] < 128) return false;
    return !(rgba[i] > _whiteThreshold &&
        rgba[i + 1] > _whiteThreshold &&
        rgba[i + 2] > _whiteThreshold);
  }
}
