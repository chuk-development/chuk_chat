# test/theme · Signatures

## test/theme/theme_presets_test.dart  (194 Z.)

- L12 `class _Recorder`  — Captures every setter call so a test can assert what a preset applied.
  - L13 `Brightness? themeMode`
  - L14 `Color? accent`
  - L15 `Color? iconFg`
  - L16 `Color? bg`
  - L17 `double? contrast`
  - L18 `String? uiFont`
  - L19 `final List<bool> dynamicCalls = <bool>[]`
- L22 `AppShellConfig _config( _Recorder r, { Brightness currentThemeMode = Brightness.dark, Color currentAccent = kDefaultAccentColor, Color currentIconFg = kDefaultIconFgColor, Color currentBg = kDefaultBgColor, double currentContrast = kDefaultContrast, String currentUiFont = kDefaultUiFontFamily, bool dynamicColorEnabled = false, })`
- L90 `_preset = ThemePreset( name: 'Test', light: ThemeVariant( accent: Color(0xFF112233), iconFg: Color(0xFF445566), bg: Colo`
- L107 `void main()`
