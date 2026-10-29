# lib/theme · Signaturen

## lib/theme/legacy_pack_font_migration.dart  (90 Z.)
- L22 `@immutable class _LegacyFontVariant`  — Palette + contrast of one legacy pack variant that set a UI font.
  - L24 `const _LegacyFontVariant(this.accent, this.iconFg, this.bg, this.contrast)`
  - L26 `final Color accent`
  - L27 `final Color iconFg`
  - L28 `final Color bg`
  - L29 `final double contrast`
- L33 `_kLegacyMerriweatherVariants = <_LegacyFontVariant>[ _LegacyFontVariant( Color(0xFFB07B4F), Color(0xFF4B3B2F), Color(0xF`  — Cappuccino light and dark, as they shipped with `uiFont: merriweather`.
- L52 `bool uiFontCameFromLegacyPack({ required String uiFont, required Color accent, required Color iconFg, required Color bg, required double contrast, })`  — Whether [uiFont] was most likely set by the legacy Cappuccino pack and
- L73 `String migrateLegacyPackUiFont({ required String uiFont, required Color accent, required Color iconFg, required Color bg, required double contrast, })`  — The UI font after the migration: [kDefaultUiFontFamily] when the pack set

## lib/theme/theme_presets.dart  (358 Z.)
- L29 `@immutable class ThemeVariant`  — One complete look: palette + contrast, for a single brightness.
  - L31 `const ThemeVariant({ required this.accent, required this.iconFg, required this.bg, this.contrast = kDefaultContrast, })`
  - L39 `final Color accent`  — Accent / primary colour.
  - L42 `final Color iconFg`  — Icon and foreground text colour.
  - L45 `final Color bg`  — Scaffold background colour.
  - L48 `final double contrast`  — Surface/outline separation strength (see [buildAppTheme]).
- L52 `@immutable class ThemePreset`  — A named pack with a light and a dark variant.
  - L54 `const ThemePreset({ required this.name, required this.light, required this.dark, })`
  - L61 `final String name`  — Display name shown in the preset dropdown.
  - L64 `final ThemeVariant light`  — The look used while the app is in light mode.
  - L67 `final ThemeVariant dark`  — The look used while the app is in dark mode.
  - L70 `ThemeVariant variantFor(Brightness brightness)`  — The variant for a given brightness.
  - L74 `bool matches({ required Brightness brightness, required Color accent, required Color iconFg, required Color bg, required double contrast, })`  — Whether the pack's variant for [brightness] equals the passed-in look.
  - L91 `void applyTo(AppShellConfig config, Brightness brightness)`  — Applies the pack's variant for [brightness] through the shell config
- L106 `kThemePresets = <ThemePreset>[ ThemePreset( name: 'Aya', light: ThemeVariant( accent: Color(0xFF2F5EA8), iconFg: Color(0`  — The built-in packs, in dropdown order. Aya (the app default) is first.
