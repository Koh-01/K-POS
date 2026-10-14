import 'dart:async';

import 'package:flutter/material.dart';

OverlayEntry? _current;
Timer? _timer;

/// Shows a short message at the top of the screen.
///
/// Used instead of SnackBars, which appear at the bottom and covered the
/// checkout / payment / save buttons. The toast ignores touches, so the
/// screen underneath stays fully usable while it is visible.
void showToast(
  BuildContext context,
  String message, {
  bool error = false,
  Duration? duration,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _dismiss();

  final top = MediaQuery.paddingOf(context).top + 8;
  final entry = OverlayEntry(
    builder: (_) => Positioned(
      top: top,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: _Toast(message: message, error: error),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  _current = entry;
  _timer = Timer(
    duration ?? Duration(milliseconds: error ? 4000 : 2500),
    _dismiss,
  );
}

void _dismiss() {
  _timer?.cancel();
  _timer = null;
  _current?.remove();
  _current = null;
}

class _Toast extends StatelessWidget {
  final String message;
  final bool error;

  const _Toast({required this.message, required this.error});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * -12),
          child: child,
        ),
      ),
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        color: error ? const Color(0xFFB42318) : const Color(0xFF1E293B),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                error ? Icons.error_outline : Icons.check_circle_outline,
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  message,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
