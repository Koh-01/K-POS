import 'package:flutter/material.dart';

class KtsLogo extends StatelessWidget {
  final double size;
  final bool onDark;

  const KtsLogo({super.key, this.size = 72, this.onDark = true});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.18),
      child: Image.asset(
        'assets/images/k_pos_logo.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        semanticLabel: 'K POS logo',
      ),
    );
  }
}
