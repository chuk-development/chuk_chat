import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';

double contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  ThemeData themeWithIcon(Color iconColor) =>
      ThemeData(iconTheme: IconThemeData(color: iconColor));

  // The shipped defaults: a muted warm tan on a mid orange. Contrast between
  // the two is 1.2, so this is the case that used to hand back a flat black
  // glyph on the one accent-filled button in the composer.
  const Color mutedTan = Color(0xFF9D937B);
  const Color orange = Color(0xFFFE8019);

  group('accentButtonForeground', () {
    test('keeps the icon colour when it already reads on the accent', () {
      final theme = themeWithIcon(const Color(0xFFF5F0E8));
      expect(theme.accentButtonForeground(orange), const Color(0xFFF5F0E8));
    });

    test('lightens a muted icon colour instead of turning it black', () {
      final theme = themeWithIcon(mutedTan);
      final Color glyph = theme.accentButtonForeground(orange);

      // Light, not dark: the point of the change.
      expect(glyph.computeLuminance(), greaterThan(orange.computeLuminance()));
      expect(contrast(glyph, orange), greaterThanOrEqualTo(2.0));
      // And still warm — it is the icon colour lightened, not plain white.
      expect(glyph.r, greaterThan(glyph.b));
    });

    test('stops as soon as it reads, rather than going all the way', () {
      final theme = themeWithIcon(mutedTan);
      final Color glyph = theme.accentButtonForeground(orange);
      expect(glyph, isNot(Colors.white));
    });

    test('goes dark when no light glyph could read on a pale accent', () {
      final theme = themeWithIcon(const Color(0xFFF5F0E8));
      const Color paleYellow = Color(0xFFFFF9C4);
      final Color glyph = theme.accentButtonForeground(paleYellow);

      expect(
        glyph.computeLuminance(),
        lessThan(paleYellow.computeLuminance()),
      );
      expect(contrast(glyph, paleYellow), greaterThanOrEqualTo(2.0));
    });

    test('lightens a dark icon colour on a dark fill', () {
      final theme = themeWithIcon(const Color(0xFF101010));
      const Color darkFill = Color(0xFF151515);
      final Color glyph = theme.accentButtonForeground(darkFill);

      expect(glyph.computeLuminance(), greaterThan(darkFill.computeLuminance()));
      expect(contrast(glyph, darkFill), greaterThanOrEqualTo(2.0));
    });
  });
}
