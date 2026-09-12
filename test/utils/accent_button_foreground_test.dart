import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';

void main() {
  ThemeData themeWithIcon(Color iconColor) => ThemeData(
    iconTheme: IconThemeData(color: iconColor),
  );

  group('accentButtonForeground', () {
    test('takes the app icon colour when it reads against the accent', () {
      final theme = themeWithIcon(const Color(0xFFF5F0E8));
      // The orange accent: a near-white glyph is legible on it, so the
      // button matches every other icon instead of flipping to black.
      expect(
        theme.accentButtonForeground(const Color(0xFFFF8C00)),
        const Color(0xFFF5F0E8),
      );
    });

    test('falls back to the contrast pick on a pale accent', () {
      final theme = themeWithIcon(const Color(0xFFF5F0E8));
      // Near-white on near-white would be an invisible glyph. Legibility is
      // not a matter of taste, so this one goes black.
      expect(
        theme.accentButtonForeground(const Color(0xFFFFF9C4)),
        Colors.black,
      );
    });

    test('falls back to white on a pale-fill dark-icon theme', () {
      final theme = themeWithIcon(const Color(0xFF101010));
      expect(
        theme.accentButtonForeground(const Color(0xFF151515)),
        Colors.white,
      );
    });
  });
}
