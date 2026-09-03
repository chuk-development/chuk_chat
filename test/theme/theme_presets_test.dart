// Tests that a ThemePreset carries a light and a dark variant, that applying
// one routes to the right AppShellConfig setters for the chosen brightness,
// and that matches() recognises the applied look.
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

const _preset = ThemePreset(
  name: 'Test',
  light: ThemeVariant(
    accent: Color(0xFF112233),
    iconFg: Color(0xFF445566),
    bg: Color(0xFF778899),
    contrast: 0.7,
    uiFont: kChatFontFamilyMerriweather,
  ),
  dark: ThemeVariant(
    accent: Color(0xFFAABBCC),
    iconFg: Color(0xFFDDEEFF),
    bg: Color(0xFF101010),
    contrast: 0.3,
  ),
);

void main() {
  test('kThemePresets is non-empty and Aya default matches the dark defaults',
      () {
    expect(kThemePresets, isNotEmpty);
    final aya = kThemePresets.first;
    expect(aya.name, 'Aya');
    expect(aya.dark.accent, kDefaultAccentColor);
    expect(aya.dark.iconFg, kDefaultIconFgColor);
    expect(aya.dark.bg, kDefaultBgColor);
    // A light variant exists and differs from the dark one.
    expect(aya.light.bg, isNot(kDefaultBgColor));
  });

  test('every variant uses a supported UI font and an in-range contrast', () {
    for (final p in kThemePresets) {
      for (final v in [p.light, p.dark]) {
        expect(
          kSupportedUiFontFamilies.contains(v.uiFont),
          isTrue,
          reason: '${p.name} has an unsupported uiFont ${v.uiFont}',
        );
        expect(v.contrast, inInclusiveRange(kMinContrast, kMaxContrast));
      }
    }
  });

  test('variantFor returns the look for the requested brightness', () {
    expect(_preset.variantFor(Brightness.light), same(_preset.light));
    expect(_preset.variantFor(Brightness.dark), same(_preset.dark));
  });

  test('matches() is true for its own variant and false across brightness', () {
    expect(
      _preset.matches(
        brightness: Brightness.light,
        accent: _preset.light.accent,
        iconFg: _preset.light.iconFg,
        bg: _preset.light.bg,
        contrast: _preset.light.contrast,
        uiFont: _preset.light.uiFont,
      ),
      isTrue,
    );
    // The light look does not match while the app is in dark mode.
    expect(
      _preset.matches(
        brightness: Brightness.dark,
        accent: _preset.light.accent,
        iconFg: _preset.light.iconFg,
        bg: _preset.light.bg,
        contrast: _preset.light.contrast,
        uiFont: _preset.light.uiFont,
      ),
      isFalse,
    );
  });

  test('applyTo routes the chosen brightness variant to every setter', () {
    final r = _Recorder();
    _preset.applyTo(_config(r), Brightness.light);

    expect(r.themeMode, Brightness.light);
    expect(r.accent, const Color(0xFF112233));
    expect(r.iconFg, const Color(0xFF445566));
    expect(r.bg, const Color(0xFF778899));
    expect(r.contrast, 0.7);
    expect(r.uiFont, kChatFontFamilyMerriweather);

    final r2 = _Recorder();
    _preset.applyTo(_config(r2), Brightness.dark);
    expect(r2.themeMode, Brightness.dark);
    expect(r2.accent, const Color(0xFFAABBCC));
    expect(r2.bg, const Color(0xFF101010));
    expect(r2.contrast, 0.3);
  });

  test('applyTo always disables dynamic colour, regardless of the snapshot',
      () {
    final rOn = _Recorder();
    _preset.applyTo(_config(rOn, dynamicColorEnabled: true), Brightness.dark);
    expect(rOn.dynamicCalls, [false]);

    final rOff = _Recorder();
    _preset.applyTo(_config(rOff, dynamicColorEnabled: false), Brightness.dark);
    expect(rOff.dynamicCalls, [false]);
  });
}
