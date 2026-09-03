// Tests that buildAppTheme's new contrast/uiFont parameters keep the default
// look identical and behave monotonically.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/chat_font_resolver.dart';

void main() {
  test('contrastFactor maps the default midpoint to identity (1.0)', () {
    expect(contrastFactor(kDefaultContrast), 1.0);
    expect(contrastFactor(kMinContrast), 0.5);
    expect(contrastFactor(kMaxContrast), 1.5);
    // Out-of-range values are clamped.
    expect(contrastFactor(-1.0), 0.5);
    expect(contrastFactor(2.0), 1.5);
  });

  test('default contrast reproduces the original dark surface ladder', () {
    const bg = kDefaultBgColor;
    const iconFg = kDefaultIconFgColor;
    final theme = buildAppTheme(
      accent: kDefaultAccentColor,
      iconFg: iconFg,
      bg: bg,
      brightness: Brightness.dark,
    );
    final cs = theme.colorScheme;

    // These are the exact literals the pre-change builder used.
    expect(cs.surfaceContainerLowest, bg.darken(0.02));
    expect(cs.surfaceContainerLow, bg.lighten(0.03));
    expect(cs.surfaceContainer, bg.lighten(0.06));
    expect(cs.surfaceContainerHigh, bg.lighten(0.10));
    expect(cs.surfaceContainerHighest, bg.lighten(0.14));
    expect(cs.secondaryContainer, bg.lighten(0.18));
    expect(cs.outline, iconFg.withValues(alpha: 0.55));
    expect(cs.outlineVariant, iconFg.withValues(alpha: 0.25));
    expect(cs.onSurfaceVariant, iconFg.withValues(alpha: 0.82));
    expect(cs.surface, bg);
    expect(cs.onSurface, iconFg);
  });

  test('default contrast reproduces the original light surface ladder', () {
    const bg = Color(0xFFFAFAFA);
    const iconFg = Color(0xFF1A1A1A);
    final theme = buildAppTheme(
      accent: kDefaultAccentColor,
      iconFg: iconFg,
      bg: bg,
      brightness: Brightness.light,
    );
    final cs = theme.colorScheme;

    expect(cs.surfaceContainerLowest, bg.lighten(0.02));
    expect(cs.surfaceContainerLow, bg.darken(0.03));
    expect(cs.surfaceContainer, bg.darken(0.05));
    expect(cs.surfaceContainerHigh, bg.darken(0.08));
    expect(cs.surfaceContainerHighest, bg.darken(0.12));
    expect(cs.secondaryContainer, bg.darken(0.15));
  });

  test('higher contrast increases the surface separation (dark)', () {
    const bg = kDefaultBgColor;
    final low = buildAppTheme(
      accent: kDefaultAccentColor,
      iconFg: kDefaultIconFgColor,
      bg: bg,
      brightness: Brightness.dark,
      contrast: kMinContrast,
    );
    final high = buildAppTheme(
      accent: kDefaultAccentColor,
      iconFg: kDefaultIconFgColor,
      bg: bg,
      brightness: Brightness.dark,
      contrast: kMaxContrast,
    );

    double lightnessOf(Color c) => HSLColor.fromColor(c).lightness;
    // In dark mode the containers are lightened from bg; a higher factor
    // lifts them further, so the high-contrast surface is lighter.
    expect(
      lightnessOf(high.colorScheme.surfaceContainerHighest),
      greaterThan(lightnessOf(low.colorScheme.surfaceContainerHighest)),
    );
    // And the outline is more opaque at higher contrast.
    expect(
      high.colorScheme.outline.a,
      greaterThan(low.colorScheme.outline.a),
    );
  });

  test('uiFont null/system does not apply a bundled family', () {
    // With fontFamily unset, ThemeData falls back to the platform default
    // typography (e.g. Roboto), not to any of our bundled fonts. The
    // invariant is that "system" behaves exactly like passing nothing.
    final none = buildAppTheme(
      accent: kDefaultAccentColor,
      iconFg: kDefaultIconFgColor,
      bg: kDefaultBgColor,
      brightness: Brightness.dark,
    );
    final system = buildAppTheme(
      accent: kDefaultAccentColor,
      iconFg: kDefaultIconFgColor,
      bg: kDefaultBgColor,
      brightness: Brightness.dark,
      uiFont: kChatFontFamilySystem,
    );

    expect(
      system.textTheme.bodyMedium?.fontFamily,
      none.textTheme.bodyMedium?.fontFamily,
    );
    expect(
      none.textTheme.bodyMedium?.fontFamily,
      isNot(kFontFamilyMerriweather),
    );
    expect(
      none.textTheme.bodyMedium?.fontFamily,
      isNot(kFontFamilyJetBrainsMono),
    );
  });

  test('uiFont with a bundled id applies that family to the text theme', () {
    final theme = buildAppTheme(
      accent: kDefaultAccentColor,
      iconFg: kDefaultIconFgColor,
      bg: kDefaultBgColor,
      brightness: Brightness.dark,
      uiFont: kChatFontFamilyJetBrainsMono,
    );
    expect(theme.textTheme.bodyMedium?.fontFamily, kFontFamilyJetBrainsMono);
  });

  test('resolveUiFontFamily maps ids to families, system/unknown to null', () {
    expect(resolveUiFontFamily(kChatFontFamilySystem), isNull);
    expect(resolveUiFontFamily(null), isNull);
    expect(resolveUiFontFamily('nonsense'), isNull);
    expect(resolveUiFontFamily(kChatFontFamilyArimo), kFontFamilyArimo);
    expect(
      resolveUiFontFamily(kChatFontFamilyMerriweather),
      kFontFamilyMerriweather,
    );
  });

  test('sanitizeUiFontFamily normalises unknown ids to the system default', () {
    expect(sanitizeUiFontFamily(null), kDefaultUiFontFamily);
    expect(sanitizeUiFontFamily('garbage'), kDefaultUiFontFamily);
    expect(
      sanitizeUiFontFamily(kChatFontFamilyMerriweather),
      kChatFontFamilyMerriweather,
    );
    for (final id in kSupportedUiFontFamilies) {
      expect(sanitizeUiFontFamily(id), id);
    }
  });
}
