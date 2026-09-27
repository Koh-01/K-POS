import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A minimal finger-drawn signature canvas. Exposes [clear] and [isEmpty]
/// via its [SignaturePadState] so a wrapping screen can drive it without
/// pulling in a third-party signature package.
class SignaturePad extends StatefulWidget {
  final GlobalKey repaintKey;
  final VoidCallback onStrokeStart;
  const SignaturePad({
    super.key,
    required this.repaintKey,
    required this.onStrokeStart,
  });

  @override
  SignaturePadState createState() => SignaturePadState();
}

class SignaturePadState extends State<SignaturePad> {
  final List<List<Offset>> _strokes = [];

  bool get isEmpty => _strokes.isEmpty;

  void clear() => setState(() => _strokes.clear());

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: widget.repaintKey,
      child: Container(
        color: Colors.white,
        width: double.infinity,
        height: double.infinity,
        child: GestureDetector(
          onPanStart: (d) {
            if (_strokes.isEmpty) widget.onStrokeStart();
            setState(() => _strokes.add([d.localPosition]));
          },
          onPanUpdate: (d) {
            setState(() => _strokes.last.add(d.localPosition));
          },
          child: CustomPaint(
            painter: _SignaturePainter(_strokes),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  const _SignaturePainter(this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      for (var i = 0; i < stroke.length - 1; i++) {
        canvas.drawLine(stroke[i], stroke[i + 1], paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) => true;
}

/// Bottom sheet that hosts a [SignaturePad] plus Clear/Cancel/Confirm
/// controls, and resolves to the captured signature as PNG bytes (or null
/// if cancelled).
class SignatureCaptureSheet extends StatefulWidget {
  final String title;
  final String subtitle;
  const SignatureCaptureSheet({
    super.key,
    required this.title,
    required this.subtitle,
  });

  static Future<Uint8List?> show(
    BuildContext context, {
    required String title,
    required String subtitle,
  }) {
    return showModalBottomSheet<Uint8List?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => SignatureCaptureSheet(title: title, subtitle: subtitle),
    );
  }

  @override
  State<SignatureCaptureSheet> createState() => _SignatureCaptureSheetState();
}

class _SignatureCaptureSheetState extends State<SignatureCaptureSheet> {
  final _repaintKey = GlobalKey();
  final _padKey = GlobalKey<SignaturePadState>();
  bool _hasSignature = false;
  bool _exporting = false;

  Future<void> _confirm() async {
    if (!_hasSignature || _exporting) return;
    setState(() => _exporting = true);
    try {
      final boundary =
          _repaintKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();
      if (mounted) Navigator.pop(context, bytes);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        widget.subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _padKey.currentState?.clear();
                    _hasSignature = false;
                  }),
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400),
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    SignaturePad(
                      key: _padKey,
                      repaintKey: _repaintKey,
                      onStrokeStart: () => setState(() => _hasSignature = true),
                    ),
                    if (!_hasSignature)
                      IgnorePointer(
                        child: Center(
                          child: Text(
                            'Sign here',
                            style: TextStyle(
                              color: Colors.grey.shade400,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, null),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: _hasSignature && !_exporting ? _confirm : null,
                    child: _exporting
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Confirm Signature'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
