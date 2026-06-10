// lib/widgets/brand_wordmark.dart
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// "Chuk Chat" wordmark rendered from the frozen brand SVG
/// (assets/wordmark.svg, vectorized from the website's Courier New
/// nav render) so it looks identical on every platform regardless of
/// which fonts are installed.
///
/// [height] is the ink height of the glyphs. The previous plain-text
/// wordmark was 20px w700; its glyph ink height is ~15px, so 15 is the
/// drop-in default.
class BrandWordmark extends StatelessWidget {
  final Color color;
  final double height;

  const BrandWordmark({super.key, required this.color, this.height = 15});

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/wordmark.svg',
      height: height,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      semanticsLabel: 'Chuk Chat',
    );
  }
}
