// lib/widgets/brand_wordmark.dart
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:chuk_chat/services/agents/agents_chat_core.dart';

/// Brand lockup rendered from the frozen brand SVG (assets/wordmark.svg,
/// vectorized from the website's nav render — "Chuk Chat" with the
/// "Private and Secure. Always." slogan beneath) so it looks identical
/// on every platform regardless of which fonts are installed.
/// Regenerate via scripts/generate_wordmark_svg.py.
///
/// [height] is the ink height of the "Chuk Chat" line. The previous
/// plain-text wordmark was 20px w700; its glyph ink height is ~15px,
/// so 15 is the drop-in default. The slogan line extends below that —
/// the rendered widget is [height] * [_lockupRatio] tall, so hosts must
/// not clamp it to the wordmark line alone.
class BrandWordmark extends StatelessWidget {
  final Color color;
  final double height;

  /// Full-lockup height / "Chuk Chat" ink height, printed by
  /// scripts/generate_wordmark_svg.py for the current SVG.
  static const double _lockupRatio = 1.907822;

  const BrandWordmark({super.key, required this.color, this.height = 15});

  @override
  Widget build(BuildContext context) {
    if (agentsChatCore) {
      // The Agents app draws the name as text in the UI font, in the same box
      // the lockup takes, and has no slogan line.
      return SizedBox(
        height: height * _lockupRatio,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Chuk Chat',
            style: TextStyle(
              // 20px text has ~15px ink height; keep that ratio.
              fontSize: height / 0.75,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      );
    }
    return SvgPicture.asset(
      'assets/wordmark.svg',
      height: height * _lockupRatio,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      semanticsLabel: 'Chuk Chat — Private and Secure. Always.',
    );
  }
}
