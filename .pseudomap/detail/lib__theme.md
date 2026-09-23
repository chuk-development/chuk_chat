# lib/theme · Signaturen

## lib/theme/theme_presets.dart  (365 Z.)
- L27 `@immutable class ThemeVariant`  — One complete look: palette + contrast + font, for a single brightness.
  - L29 `const ThemeVariant({ required this.accent, required this.iconFg, required this.bg, this.contrast = kDefaultContrast, this.uiFont = kDefaultUiFontFamily, })`
  - L38 `final Color accent`  — Accent / primary colour.
  - L41 `final Color iconFg`  — Icon and foreground text colour.
  - L44 `final Color bg`  — Scaffold background colour.
  - L47 `final double contrast`  — Surface/outline separation strength (see [buildAppTheme]).
  - L50 `final String uiFont`  — App-chrome font family id (see [kSupportedUiFontFamilies]).
- L54 `@immutable class ThemePreset`  — A named pack with a light and a dark variant.
  - L56 `const ThemePreset({ required this.name, required this.light, required this.dark, })`
  - L63 `final String name`  — Display name shown in the preset dropdown.
  - L66 `final ThemeVariant light`  — The look used while the app is in light mode.
  - L69 `final ThemeVariant dark`  — The look used while the app is in dark mode.
  - L72 `ThemeVariant variantFor(Brightness brightness)`  — The variant for a given brightness.
  - L76 `bool matches({ required Brightness brightness, required Color accent, required Color iconFg, required Color bg, required double contrast, required String uiFont, })`  — Whether the pack's variant for [brightness] equals the passed-in look.
  - L95 `void applyTo(AppShellConfig config, Brightness brightness)`  — Applies the pack's variant for [brightness] through the shell config
- L111 `kThemePresets = <ThemePreset>[ ThemePreset( name: 'Aya', light: ThemeVariant( accent: Color(0xFF2F5EA8), iconFg: Color(0`  — The built-in packs, in dropdown order. Aya (the app default) is first.
