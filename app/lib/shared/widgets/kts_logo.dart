import 'package:flutter/material.dart';

class KtsLogo extends StatelessWidget {
  final double size;
  final bool onDark;

  const KtsLogo({super.key, this.size = 72, this.onDark = true});

  @override
  Widget build(BuildContext context) {
    final bg = onDark
        ? Colors.white.withValues(alpha: 0.13)
        : const Color(0xFF5A5A5A);
    final fg = Colors.white;
    final fgDim = Colors.white.withValues(alpha: 0.5);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(size * 0.18),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chevron_right, color: fg, size: size * 0.22),
              Container(
                width: size * 0.14,
                height: size * 0.025,
                margin: EdgeInsets.only(bottom: size * 0.03),
                color: fg,
              ),
            ],
          ),
          SizedBox(height: size * 0.02),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '{',
                style: TextStyle(
                  color: fgDim,
                  fontSize: size * 0.23,
                  fontWeight: FontWeight.w300,
                  height: 1,
                ),
              ),
              Text(
                'KTS',
                style: TextStyle(
                  color: fg,
                  fontSize: size * 0.23,
                  fontWeight: FontWeight.w800,
                  letterSpacing: size * 0.012,
                  height: 1,
                ),
              ),
              Text(
                '}',
                style: TextStyle(
                  color: fgDim,
                  fontSize: size * 0.23,
                  fontWeight: FontWeight.w300,
                  height: 1,
                ),
              ),
            ],
          ),
          SizedBox(height: size * 0.05),
          Icon(Icons.settings_outlined, color: fgDim, size: size * 0.2),
        ],
      ),
    );
  }
}
