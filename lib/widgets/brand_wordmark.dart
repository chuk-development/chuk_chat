// COWORK STUB. Upstream: chuk_chat/lib/widgets/brand_wordmark.dart.
// Reason: upstream renders the frozen brand lockup from assets/wordmark.svg,
// which reads "Chuk Chat — Private and Secure. Always." This build has no such
// vector asset, so the wordmark is drawn as text at the same ink height.
// `SbBrand` only reaches this widget when its label is literally 'Chuk Chat'
// (see widgets/sidebar/sidebar_chrome.dart). The product name is Chuk Chat;
// CoWork is a mode inside it and never appears here.
import 'package:flutter/material.dart';

/// Text stand-in for the frozen brand lockup.
///
/// [height] is the ink height of the wordmark line, matching the upstream API.
class BrandWordmark extends StatelessWidget {
  final Color color;
  final double height;

  /// Full-lockup height / wordmark ink height. Kept from upstream so hosts
  /// that reserve vertical space compute the same box.
  static const double _lockupRatio = 1.907822;

  const BrandWordmark({super.key, required this.color, this.height = 15});

  @override
  Widget build(BuildContext context) {
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
}
