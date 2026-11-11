// The on-accent colour rule (UI audit 2026-10-05, R-1 to R-3): keep the
// reader's own foreground on an accent fill unless it falls below 2 : 1, then
// black or white; and a darker accent ink for text on light surfaces.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

// The pastel-blue look these rules were written for (the app default until
// the Plane pack, now the Aya pack's dark variant).
const Color _kPastelAccent = Color(0xFFA8C7FA);
const Color _kPastelIconFg = Color(0xFFE2E2E9);
const Color _kPastelBg = Color(0xFF111318);

void main() {
  // The owner's look: an orange accent with white text and icons.
  const Color ownerOrange = Color(0xFFE07A5F);
  const Color white = Color(0xFFFFFFFF);
  const Color black = Color(0xFF000000);

  group('readableOnFill', () {
    test('white on the owner orange stays white (about 2.95 : 1)', () {
      expect(contrastRatio(white, ownerOrange), closeTo(2.95, 0.05));
      expect(readableOnFill(ownerOrange, white), white);
    });

    test('the default icon colour on the pastel default flips to black', () {
      expect(
        contrastRatio(_kPastelIconFg, _kPastelAccent),
        lessThan(kMinOnFillContrast),
      );
      expect(readableOnFill(_kPastelAccent, _kPastelIconFg), black);
    });

    test('a dark fill with a dark preferred colour flips to white', () {
      expect(
        readableOnFill(const Color(0xFF1A237E), const Color(0xFF202020)),
        white,
      );
    });

    test('a colour that already reads is kept as is', () {
      const Color navy = Color(0xFF0A0D13);
      expect(readableOnFill(_kPastelAccent, navy), navy);
    });
  });

  group('buildAppTheme onPrimary', () {
    ThemeData theme(
      Color accent,
      Color iconFg,
      Brightness b, {
      Color? bg,
    }) => buildAppTheme(
      accent: accent,
      iconFg: iconFg,
      bg: bg ?? (b == Brightness.dark ? _kPastelBg : const Color(0xFFF7F9FF)),
      brightness: b,
    );

    test('orange accent with white icons keeps white on the accent', () {
      for (final Brightness b in Brightness.values) {
        expect(theme(ownerOrange, white, b).colorScheme.onPrimary, white);
      }
    });

    test('pastel blue default gets dark text on the accent (dark mode)', () {
      final ColorScheme cs = theme(
        _kPastelAccent,
        _kPastelIconFg,
        Brightness.dark,
      ).colorScheme;
      expect(cs.onPrimary, black);
      expect(contrastRatio(cs.onPrimary, cs.primary), greaterThan(4.5));
    });

    test('a light theme with dark icons keeps its icon colour', () {
      const Color ink = Color(0xFF1A1B1F);
      expect(
        theme(
          const Color(0xFF8AB4F8),
          ink,
          Brightness.light,
        ).colorScheme.onPrimary,
        ink,
      );
    });
  });

  group('user bubble fill (accent at 80 % over the page)', () {
    Color bubbleText(Color accent, Color iconFg, Color bg) => readableOnFill(
      Color.alphaBlend(accent.withValues(alpha: .8), bg),
      iconFg,
    );

    test('owner orange with white text stays white on a dark page', () {
      expect(bubbleText(ownerOrange, white, _kPastelBg), white);
    });

    test('pastel default on the dark page flips to dark text', () {
      expect(bubbleText(_kPastelAccent, _kPastelIconFg, _kPastelBg), black);
    });
  });

  group('accentForegroundFor', () {
    const Color lightPage = Color(0xFFF7F9FF);

    test('pastel accent on a light page gets a darker shade at 3 : 1', () {
      final Color ink = accentForegroundFor(_kPastelAccent, lightPage);
      expect(ink, isNot(_kPastelAccent));
      expect(
        contrastRatio(ink, lightPage),
        greaterThanOrEqualTo(kMinAccentForegroundContrast),
      );
      // Still the accent's hue, only darker.
      expect(
        (HSLColor.fromColor(ink).hue - HSLColor.fromColor(_kPastelAccent).hue)
            .abs(),
        lessThan(2),
      );
    });

    test('an accent that already reads is returned unchanged', () {
      expect(accentForegroundFor(_kPastelAccent, _kPastelBg), _kPastelAccent);
      expect(accentForegroundFor(ownerOrange, _kPastelBg), ownerOrange);
    });

    test('the theme getter uses the scaffold background by default', () {
      final ThemeData t = buildAppTheme(
        accent: _kPastelAccent,
        iconFg: const Color(0xFF1A1B1F),
        bg: lightPage,
        brightness: Brightness.light,
      );
      expect(
        t.accentForegroundOn(),
        accentForegroundFor(_kPastelAccent, t.scaffoldBackgroundColor),
      );
      expect(
        contrastRatio(t.accentForegroundOn(), t.scaffoldBackgroundColor),
        greaterThanOrEqualTo(kMinAccentForegroundContrast),
      );
    });
  });
}
