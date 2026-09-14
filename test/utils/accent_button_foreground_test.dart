import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';

void main() {
  ThemeData themeWithIcon(Color iconColor) =>
      ThemeData(iconTheme: IconThemeData(color: iconColor));

  // The shipped defaults: a muted warm tan icon colour on a mid orange fill.
  const Color mutedTan = Color(0xFF9D937B);
  const Color orange = Color(0xFFFE8019);

  group('accentButtonForeground', () {
    test('reads against the fill, not with the icon colour', () {
      final theme = themeWithIcon(mutedTan);
      // The tan on the orange was a contrast of about 1.2 and made the
      // phone's send button look washed out beside the desktop's.
      expect(theme.accentButtonForeground(orange), Colors.black);
      expect(theme.accentButtonForeground(orange), isNot(mutedTan));
    });

    test('follows the fill: black on a light one, white on a dark one', () {
      final theme = themeWithIcon(mutedTan);
      expect(
        theme.accentButtonForeground(const Color(0xFFFFF9C4)),
        Colors.black,
      );
      expect(
        theme.accentButtonForeground(const Color(0xFF101010)),
        Colors.white,
      );
    });

    test('the same fill gives the same glyph under any icon colour', () {
      // One decision for both platforms: the desktop send button and the
      // phone one must not drift apart because a theme sets a different
      // icon colour.
      expect(
        themeWithIcon(mutedTan).accentButtonForeground(orange),
        themeWithIcon(Colors.white).accentButtonForeground(orange),
      );
    });
  });
}
