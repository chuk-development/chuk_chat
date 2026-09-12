import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';

void main() {
  ThemeData themeWithIcon(Color iconColor) =>
      ThemeData(iconTheme: IconThemeData(color: iconColor));

  // The shipped defaults: a muted warm tan on a mid orange.
  const Color mutedTan = Color(0xFF9D937B);
  const Color orange = Color(0xFFFE8019);

  group('accentButtonForeground', () {
    test('is the icon colour, unchanged', () {
      final theme = themeWithIcon(mutedTan);
      // Not lightened, not swapped for black or white: the send button and
      // the new-chat button carry the same colour as every other icon on
      // screen, which is the whole point of the helper.
      expect(theme.accentButtonForeground(orange), mutedTan);
    });

    test('does not change with the fill', () {
      final theme = themeWithIcon(mutedTan);
      expect(
        theme.accentButtonForeground(const Color(0xFFFFF9C4)),
        theme.accentButtonForeground(const Color(0xFF101010)),
      );
    });

  });
}
