// Tests that AppThemeService persists and restores the new contrast and
// UI-font settings through SharedPreferences, and that buildTheme reflects
// them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/utils/chat_font_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = AppThemeService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await service.loadFromPrefs(); // resets to defaults
  });

  test('defaults match the constants', () async {
    expect(service.contrast, kDefaultContrast);
    expect(service.uiFontFamily, kDefaultUiFontFamily);
  });

  test('contrast persists to prefs and restores on reload', () async {
    await service.setContrast(0.9);
    expect(service.contrast, 0.9);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('contrast'), 0.9);

    await service.loadFromPrefs();
    expect(service.contrast, 0.9);
  });

  test('contrast is clamped to the supported range', () async {
    await service.setContrast(5.0);
    expect(service.contrast, kMaxContrast);
    await service.setContrast(-1.0);
    expect(service.contrast, kMinContrast);
  });

  test('uiFontFamily persists to prefs and restores on reload', () async {
    await service.setUiFontFamily(kChatFontFamilyMerriweather);
    expect(service.uiFontFamily, kChatFontFamilyMerriweather);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('uiFontFamily'), kChatFontFamilyMerriweather);

    await service.loadFromPrefs();
    expect(service.uiFontFamily, kChatFontFamilyMerriweather);
  });

  test('setUiFontFamily normalises an unknown id to the system default',
      () async {
    await service.setUiFontFamily(kChatFontFamilyMerriweather);
    expect(service.uiFontFamily, kChatFontFamilyMerriweather);
    await service.setUiFontFamily('garbage');
    expect(service.uiFontFamily, kDefaultUiFontFamily);
  });

  test('buildTheme reflects the UI font and rebuilds when it changes',
      () async {
    // System font -> the platform default typography, never a bundled family.
    await service.setUiFontFamily(kChatFontFamilySystem);
    var theme = service.buildTheme();
    expect(
      theme.textTheme.bodyMedium?.fontFamily,
      isNot(kFontFamilyJetBrainsMono),
    );

    await service.setUiFontFamily(kChatFontFamilyJetBrainsMono);
    theme = service.buildTheme();
    expect(theme.textTheme.bodyMedium?.fontFamily, kFontFamilyJetBrainsMono);
  });

  test('buildTheme rebuilds when contrast changes', () async {
    // setUp already loaded the default dark brightness.
    await service.setContrast(kMinContrast);
    final low = service.buildTheme();
    await service.setContrast(kMaxContrast);
    final high = service.buildTheme();

    expect(
      HSLColor.fromColor(high.colorScheme.surfaceContainerHighest).lightness,
      greaterThan(
        HSLColor.fromColor(low.colorScheme.surfaceContainerHighest).lightness,
      ),
    );
  });
}
