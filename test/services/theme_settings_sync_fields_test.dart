// A theme pack is the three colours plus the contrast and the app font. All of
// them have to survive the round trip through Supabase, or a second device
// shows the pack's palette while the theme page calls it "Custom" — which is
// exactly the bug these tests pin down.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/theme_settings_service.dart';
import 'package:chuk_chat/theme/theme_presets.dart';

void main() {
  const String userId = 'user-1';

  ThemePreset presetNamed(String name) =>
      kThemePresets.firstWhere((ThemePreset p) => p.name == name);

  test('the whole look survives a write and a read', () {
    final ThemeVariant variant =
        presetNamed('Clawed').variantFor(Brightness.dark);

    final ThemeSettings written = ThemeSettings(
      userId: userId,
      themeMode: Brightness.dark,
      accentColor: variant.accent,
      iconColor: variant.iconFg,
      backgroundColor: variant.bg,
      contrast: variant.contrast,
      uiFont: variant.uiFont,
      dynamicColor: false,
    );

    final ThemeSettings read = ThemeSettings.fromMap(userId, written.toMap());

    expect(read.accentColor, variant.accent);
    expect(read.iconColor, variant.iconFg);
    expect(read.backgroundColor, variant.bg);
    expect(read.contrast, variant.contrast);
    expect(read.uiFont, variant.uiFont);
    expect(read.dynamicColor, isFalse);
  });

  test('a pack read back from the database is still recognised as that pack',
      () {
    final ThemePreset clawed = presetNamed('Clawed');
    final ThemeVariant variant = clawed.variantFor(Brightness.dark);

    final ThemeSettings read = ThemeSettings.fromMap(
      userId,
      ThemeSettings(
        userId: userId,
        themeMode: Brightness.dark,
        accentColor: variant.accent,
        iconColor: variant.iconFg,
        backgroundColor: variant.bg,
        contrast: variant.contrast,
        uiFont: variant.uiFont,
        dynamicColor: false,
      ).toMap(),
    );

    expect(
      clawed.matches(
        brightness: Brightness.dark,
        accent: read.accentColor,
        iconFg: read.iconColor,
        bg: read.backgroundColor,
        contrast: read.contrast!,
        uiFont: read.uiFont!,
      ),
      isTrue,
    );
  });

  test('a row written before the columns existed reports them as unset', () {
    final ThemeSettings read = ThemeSettings.fromMap(userId, <String, dynamic>{
      'theme_mode': 'dark',
      'accent_color': '#D97757',
      'icon_color': '#E8E4D8',
      'background_color': '#262624',
    });

    // Null, not the default: the caller keeps the device's own values instead
    // of resetting them on the first sync after the upgrade.
    expect(read.contrast, isNull);
    expect(read.uiFont, isNull);
    expect(read.dynamicColor, isNull);
  });

  test('an unknown font id and an out-of-range contrast are repaired', () {
    final ThemeSettings read = ThemeSettings.fromMap(userId, <String, dynamic>{
      'theme_mode': 'dark',
      'accent_color': '#D97757',
      'icon_color': '#E8E4D8',
      'background_color': '#262624',
      'contrast': 9.5,
      'ui_font': 'comic-sans-from-the-future',
      'dynamic_color': true,
    });

    expect(read.contrast, kMaxContrast);
    expect(read.uiFont, kDefaultUiFontFamily);
    expect(read.dynamicColor, isTrue);
  });
}
