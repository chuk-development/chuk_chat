// Tests that applying a ThemePreset routes to the right AppShellConfig
// setters, and that matches() recognises the applied look.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/theme/theme_presets.dart';

/// Captures every setter call so a test can assert what a preset applied.
class _Recorder {
  Brightness? themeMode;
  Color? accent;
  Color? iconFg;
  Color? bg;
  double? contrast;
  String? uiFont;
  final List<bool> dynamicCalls = <bool>[];
}

AppShellConfig _config(
  _Recorder r, {
  Brightness currentThemeMode = Brightness.dark,
  Color currentAccent = kDefaultAccentColor,
  Color currentIconFg = kDefaultIconFgColor,
  Color currentBg = kDefaultBgColor,
  double currentContrast = kDefaultContrast,
  String currentUiFont = kDefaultUiFontFamily,
  bool dynamicColorEnabled = false,
}) {
  return AppShellConfig(
    currentThemeMode: currentThemeMode,
    currentAccentColor: currentAccent,
    currentIconFgColor: currentIconFg,
    currentBgColor: currentBg,
    setThemeMode: (m) => r.themeMode = m,
    setAccentColor: (c) => r.accent = c,
    setIconFgColor: (c) => r.iconFg = c,
    setBgColor: (c) => r.bg = c,
    dynamicColorEnabled: dynamicColorEnabled,
    setDynamicColorEnabled: (v) async => r.dynamicCalls.add(v),
    contrast: currentContrast,
    setContrast: (v) async => r.contrast = v,
    uiFontFamily: currentUiFont,
    setUiFontFamily: (v) async => r.uiFont = v,
    showReasoningTokens: false,
    setShowReasoningTokens: (_) {},
    showModelInfo: false,
    setShowModelInfo: (_) {},
    showTps: false,
    setShowTps: (_) {},
    autoSendVoiceTranscription: false,
    setAutoSendVoiceTranscription: (_) {},
    imageGenEnabled: false,
    setImageGenEnabled: (_) {},
    imageGenDefaultSize: 'landscape_4_3',
    setImageGenDefaultSize: (_) {},
    imageGenCustomWidth: 1024,
    setImageGenCustomWidth: (_) {},
    imageGenCustomHeight: 768,
    setImageGenCustomHeight: (_) {},
    imageGenUseCustomSize: false,
    setImageGenUseCustomSize: (_) {},
    includeRecentImagesInHistory: true,
    setIncludeRecentImagesInHistory: (_) {},
    includeAllImagesInHistory: false,
    setIncludeAllImagesInHistory: (_) {},
    includeReasoningInHistory: false,
    setIncludeReasoningInHistory: (_) {},
    includeToolResultsInHistory: true,
    setIncludeToolResultsInHistory: (_) {},
    toolCallingEnabled: true,
    setToolCallingEnabled: (_) {},
    toolDiscoveryMode: true,
    setToolDiscoveryMode: (_) {},
    showToolCalls: true,
    setShowToolCalls: (_) {},
    uiLocale: 'en',
    setUiLocale: (_) {},
    chatFontSize: kDefaultChatFontSize,
    setChatFontSize: (_) {},
    chatFontFamily: kDefaultChatFontFamily,
    setChatFontFamily: (_) {},
    uiScale: kDefaultUiScale,
    setUiScale: (_) async {},
  );
}

void main() {
  test('kThemePresets is non-empty and includes the Aya default', () {
    expect(kThemePresets, isNotEmpty);
    final aya = kThemePresets.first;
    expect(aya.name, 'Aya');
    expect(aya.brightness, kDefaultThemeMode);
    expect(aya.accent, kDefaultAccentColor);
    expect(aya.iconFg, kDefaultIconFgColor);
    expect(aya.bg, kDefaultBgColor);
    expect(aya.contrast, kDefaultContrast);
    expect(aya.uiFont, kDefaultUiFontFamily);
  });

  test('every preset uses a supported UI font id', () {
    for (final p in kThemePresets) {
      expect(
        kSupportedUiFontFamilies.contains(p.uiFont),
        isTrue,
        reason: '${p.name} has an unsupported uiFont ${p.uiFont}',
      );
      expect(p.contrast, inInclusiveRange(kMinContrast, kMaxContrast));
    }
  });

  test('applyTo routes every field to the matching setter', () {
    final r = _Recorder();
    final config = _config(r);
    const preset = ThemePreset(
      name: 'Test',
      brightness: Brightness.light,
      accent: Color(0xFF112233),
      iconFg: Color(0xFF445566),
      bg: Color(0xFF778899),
      contrast: 0.7,
      uiFont: kChatFontFamilyMerriweather,
    );

    preset.applyTo(config);

    expect(r.themeMode, Brightness.light);
    expect(r.accent, const Color(0xFF112233));
    expect(r.iconFg, const Color(0xFF445566));
    expect(r.bg, const Color(0xFF778899));
    expect(r.contrast, 0.7);
    expect(r.uiFont, kChatFontFamilyMerriweather);
  });

  test('applyTo always disables dynamic colour, regardless of the snapshot',
      () {
    // The snapshot flag may be stale, so a preset must unconditionally clear
    // dynamic colour or Material You would keep overriding its palette.
    final rOn = _Recorder();
    ThemePreset(
      name: 'X',
      brightness: Brightness.dark,
      accent: kDefaultAccentColor,
      iconFg: kDefaultIconFgColor,
      bg: kDefaultBgColor,
    ).applyTo(_config(rOn, dynamicColorEnabled: true));
    expect(rOn.dynamicCalls, [false]);

    final rOff = _Recorder();
    ThemePreset(
      name: 'X',
      brightness: Brightness.dark,
      accent: kDefaultAccentColor,
      iconFg: kDefaultIconFgColor,
      bg: kDefaultBgColor,
    ).applyTo(_config(rOff, dynamicColorEnabled: false));
    expect(rOff.dynamicCalls, [false]);
  });

}
