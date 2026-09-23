/// A coworker's face (§16.1). Identity you can pick out of a roster at a
/// glance, built from what the app already knows — no image fetch, no network.
///
/// Hermes Bot Mode leans on avatars because a roster of a dozen same-looking
/// rows is unreadable; a stable colour plus the name's initials is the cheapest
/// thing that reads as identity. The colour is **derived from a seed** (the
/// agent id, which never changes), so the same coworker is the same colour on
/// every screen and across restarts — it is not random and not re-rolled.
///
/// This is deliberately the "generated blob face" tier only. Uploaded and
/// AI-generated portraits (the other tiers §16.1 lists) need a byte store the
/// controller does not have yet; when it does, this widget takes an optional
/// image and falls back to the monogram, so nothing downstream changes.
library;

import 'package:flutter/material.dart';

class AgentAvatar extends StatelessWidget {
  const AgentAvatar({
    super.key,
    required this.seed,
    required this.label,
    this.radius = 16,
    this.dimmed = false,
  });

  /// The stable identity the colour is derived from — pass the agent id, not
  /// the name, so a rename keeps the face.
  final String seed;

  /// The text the monogram is taken from — pass the display name.
  final String label;

  final double radius;

  /// A hidden coworker is shown faded in the "show hidden" list.
  final bool dimmed;

  /// The monogram: the first character of the name, upper-cased, or '?' when
  /// the name is empty. One glyph — two initials from an `adjective-noun`
  /// auto-name would just be the same two letters for everyone.
  static String monogramOf(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.characters.first.toUpperCase();
  }

  /// A stable hue in [0, 360) from the seed. A plain FNV-1a hash over the code
  /// units — deterministic, no dependency, good enough spread for a palette of
  /// distinct colours.
  static double hueOf(String seed) {
    var hash = 0x811c9dc5;
    for (final unit in seed.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return (hash % 360).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final hue = hueOf(seed);
    // Fixed saturation/lightness so every face carries the same weight and
    // only the hue tells them apart. Darker fill in dark mode so white text
    // stays legible; the values are picked for contrast, not taste.
    final background = HSLColor.fromAHSL(
      1,
      hue,
      0.45,
      brightness == Brightness.dark ? 0.42 : 0.62,
    ).toColor();
    final opacity = dimmed ? 0.4 : 1.0;
    return CircleAvatar(
      radius: radius,
      backgroundColor: background.withValues(alpha: opacity),
      child: Text(
        monogramOf(label),
        style: TextStyle(
          color: Colors.white.withValues(alpha: opacity),
          fontSize: radius * 0.9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
