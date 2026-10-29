// Tests that AppThemeService persists and restores the new contrast and
// UI-font settings through SharedPreferences, and that buildTheme reflects
// them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/utils/chat_font_resolver.dart';
import 'package:chuk_chat/utils/color_extensions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = AppThemeService.instance;

  // Loads [values] as the stored prefs, through a fresh prefs instance.
  Future<void> loadWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    service.debugResetPrefsCache();
    await service.loadFromPrefs();
  }

  setUp(() async {
    await loadWith(<String, Object>{}); // resets to defaults
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

  test('setUiFontFamily normalises an unknown id to the default',
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
  group('legacy pack-font migration', () {
    // Cappuccino dark, as it shipped together with uiFont: merriweather.
    Map<String, Object> cappuccinoDark({
      String uiFont = kChatFontFamilyMerriweather,
      bool migrated = false,
    }) => <String, Object>{
      'themeMode': 'dark',
      'accentColor': const Color(0xFFC89B6A).toHexString(),
      'iconFgColor': const Color(0xFFE8DCC8).toHexString(),
      'bgColor': const Color(0xFF2A2320).toHexString(),
      'contrast': 0.55,
      'uiFontFamily': uiFont,
      if (migrated) 'uiFontPackMigrationV1': true,
    };

    test('a Merriweather that came with Cappuccino moves to Inter', () async {
      await loadWith(cappuccinoDark());
      expect(service.uiFontFamily, kChatFontFamilyInter);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('uiFontFamily'), kChatFontFamilyInter);
      // The palette itself is left alone.
      expect(service.bgColor, const Color(0xFF2A2320));
    });

    test('Merriweather next to another palette was chosen and stays',
        () async {
      final values = cappuccinoDark()..['bgColor'] =
          const Color(0xFF101010).toHexString();
      await loadWith(values);
      expect(service.uiFontFamily, kChatFontFamilyMerriweather);
    });

    test('runs only once: after the flag is set nothing changes', () async {
      await loadWith(cappuccinoDark(migrated: true));
      expect(service.uiFontFamily, kChatFontFamilyMerriweather);
    });

    test('a hand-picked Merriweather on Cappuccino survives a reload',
        () async {
      await loadWith(
        cappuccinoDark(uiFont: kChatFontFamilySystem),
      );
      await service.setUiFontFamily(kChatFontFamilyMerriweather);
      await service.loadFromPrefs();
      expect(service.uiFontFamily, kChatFontFamilyMerriweather);
    });

    test('explicit non-pack fonts are never touched', () async {
      for (final id in <String>[
        kChatFontFamilySystem,
        kChatFontFamilyArimo,
        kChatFontFamilyJetBrainsMono,
      ]) {
        await loadWith(cappuccinoDark(uiFont: id));
        expect(service.uiFontFamily, id);
      }
    });
  });

  test('fresh install: Inter for UI and chat, chat body 16 px', () async {
    expect(service.uiFontFamily, kChatFontFamilyInter);
    expect(service.chatFontFamily, kChatFontFamilyInter);
    expect(service.chatFontSize, 16.0);
    expect(service.buildTheme().textTheme.bodyMedium?.fontFamily,
        kFontFamilyInter);
  });

  test('a stored chat font stays the user\'s choice', () async {
    await loadWith(<String, Object>{
      'chatFontFamily': kChatFontFamilyJetBrainsMono,
    });
    expect(service.chatFontFamily, kChatFontFamilyJetBrainsMono);
  });
}
