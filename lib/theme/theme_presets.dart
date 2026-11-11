// lib/theme/theme_presets.dart
//
// Named theme packs for the theme editor. A pack now bundles TWO complete
// looks — a light variant and a dark variant — so the dark-mode toggle flips
// between them without leaving the pack. Selecting a pack applies the variant
// that matches the current brightness; flipping the toggle re-applies the
// sibling variant.
//
// Each variant carries the full look: the three palette colours and the
// contrast strength. Everything is applied through the existing
// [AppShellConfig] setters. A pack never sets a font: colour and font are two
// separate choices, and a pack that silently swapped the font (Cappuccino used
// to set Merriweather) changed something the user never picked.
//
// Colours are the well-known published palette values of each look (palettes
// are not copyrightable and the names are descriptive). The two app-inspired
// packs — Clawed (Claude) and Chagivity (ChatGPT) — carry altered names on
// purpose: a colour scheme is free to reuse, but the product name and logo are
// trademarks, so we do not use those.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/theme/theme_palette.dart';

/// One complete look: palette + contrast, for a single brightness.
@immutable
class ThemeVariant {
  const ThemeVariant({
    required this.accent,
    required this.iconFg,
    required this.bg,
    this.contrast = kDefaultContrast,
    this.palette,
  });

  /// Accent / primary colour.
  final Color accent;

  /// Icon and foreground text colour.
  final Color iconFg;

  /// Scaffold background colour.
  final Color bg;

  /// Surface/outline separation strength (see [buildAppTheme]).
  final double contrast;

  /// Exact surface colours, for a pack copied from a real product. Null
  /// means the ladder is derived from [bg] and [contrast].
  final ThemePalette? palette;
}

/// A named pack with a light and a dark variant.
@immutable
class ThemePreset {
  const ThemePreset({
    required this.name,
    required this.light,
    required this.dark,
  });

  /// Display name shown in the preset dropdown.
  final String name;

  /// The look used while the app is in light mode.
  final ThemeVariant light;

  /// The look used while the app is in dark mode.
  final ThemeVariant dark;

  /// The variant for a given brightness.
  ThemeVariant variantFor(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// Whether the pack's variant for [brightness] equals the passed-in look.
  bool matches({
    required Brightness brightness,
    required Color accent,
    required Color iconFg,
    required Color bg,
    required double contrast,
  }) {
    final v = variantFor(brightness);
    return v.accent == accent &&
        v.iconFg == iconFg &&
        v.bg == bg &&
        v.contrast == contrast;
  }

  /// Applies the pack's variant for [brightness] through the shell config
  /// setters, keeping the current brightness. Dynamic colour is turned off
  /// first, because it would otherwise override the explicit palette.
  void applyTo(AppShellConfig config, Brightness brightness) {
    final v = variantFor(brightness);
    // Always turn dynamic colour off — the passed-in flag may be a stale
    // snapshot, and the service ignores an unchanged value anyway. Leaving it
    // on would let Material You keep overriding the pack's palette.
    unawaited(config.setDynamicColorEnabled(false));
    config.setThemeMode(brightness);
    config.setAccentColor(v.accent);
    config.setIconFgColor(v.iconFg);
    config.setBgColor(v.bg);
    unawaited(config.setContrast(v.contrast));
  }
}

/// The exact palette of the pack whose [brightness] variant matches the given
/// look, or null. Used by the theme service: a pack's hand-picked greys stay
/// in force only while its colours and contrast are untouched.
ThemePalette? paletteForLook({
  required Brightness brightness,
  required Color accent,
  required Color iconFg,
  required Color bg,
  required double contrast,
}) {
  for (final preset in kThemePresets) {
    final v = preset.variantFor(brightness);
    if (v.palette == null) continue;
    if (preset.matches(
      brightness: brightness,
      accent: accent,
      iconFg: iconFg,
      bg: bg,
      contrast: contrast,
    )) {
      return v.palette;
    }
  }
  return null;
}

/// Plane's dark mode (the open-source project tracker), taken from its
/// design tokens (`@makeplane/propel`, `[data-theme="dark"]`): a canvas a
/// step below the panels, then one grey per layer in front of it, a neutral
/// grey for the selected row. Plane's blue (#2893CC) is left out on purpose:
/// it looked too loud on the many accent-coloured parts of this app (sidebar
/// icons, the send button), so the accent is Plane's mid grey #AFB3B6
/// (neutral-1000).
const ThemePalette kPlaneDarkPalette = ThemePalette(
  surfaceLowest: Color(0xFF0F0F10), // bg-canvas
  surfaceLow: Color(0xFF181A1B), // bg-layer-1
  surface: Color(0xFF1D1F20), // bg-layer-2
  surfaceHigh: Color(0xFF222425), // bg-layer-3
  surfaceHighest: Color(0xFF2C2E30), // bg-layer-3-hover
  secondaryContainer: Color(0xFF2B2B2C), // selected nav entry
  // Plane's selected row: bg-layer-transparent-selected (white at 10 %)
  // over the panel, measured as #2B2B2C in the running app.
  selection: Color(0xFF2B2B2C),
  onSelection: Color(0xFFE4E6E7), // txt-primary
  selectedFill: Color(0xFF2B2B2C),
  onSelectedFill: Color(0xFFE4E6E7),
  outline: Color(0xFF45484A), // border-strong-1
  outlineVariant: Color(0xFF2C2E30), // border-subtle-1
  onSurfaceVariant: Color(0xFFAFB3B6), // txt-tertiary
  primaryContainer: Color(0xFF2B2B2C), // neutral, like the selection
  onPrimaryContainer: Color(0xFFE4E6E7), // txt-primary
  error: Color(0xFFE8847D), // txt-danger-secondary
  errorContainer: Color(0xFF4E120E), // red-100
  onErrorContainer: Color(0xFFF6CECB), // red-900
  success: Color(0xFF6CD088), // txt-success-primary
  onSuccess: Color(0xFF0A1F10), // green-50
  successContainer: Color(0xFF11361C), // bg-success-subtle
  onSuccessContainer: Color(0xFFAAE4BA), // green-900
  warning: Color(0xFFFE9A00), // txt-warning-primary
  warningContainer: Color(0xFF501D01), // bg-warning-subtle
  onWarningContainer: Color(0xFFFEE685), // amber-900
);

/// The built-in packs, in dropdown order. Plane (the app default) is first;
/// [kDefaultThemePreset] is what "reset to default" applies.
const List<ThemePreset> kThemePresets = <ThemePreset>[
  ThemePreset(
    name: 'Plane',
    // Plane's light theme: white panels on a light grey canvas, grey accent.
    light: ThemeVariant(
      accent: Color(0xFF45484A),
      iconFg: Color(0xFF0F0F10),
      bg: Color(0xFFFFFFFF),
      contrast: 0.5,
    ),
    dark: ThemeVariant(
      accent: kDefaultAccentColor, // neutral-1000
      iconFg: kDefaultIconFgColor, // txt-primary
      bg: kDefaultBgColor, // bg-surface-1
      palette: kPlaneDarkPalette,
    ),
  ),
  ThemePreset(
    name: 'Aya',
    light: ThemeVariant(
      accent: Color(0xFF2F5EA8),
      iconFg: Color(0xFF1A1B1F),
      bg: Color(0xFFF7F9FF),
      contrast: 0.55,
    ),
    // The app default before Plane (Material You dark).
    dark: ThemeVariant(
      accent: Color(0xFFA8C7FA),
      iconFg: Color(0xFFE2E2E9),
      bg: Color(0xFF111318),
    ),
  ),
  ThemePreset(
    name: 'Material',
    light: ThemeVariant(
      accent: Color(0xFF6750A4),
      iconFg: Color(0xFF1D1B20),
      bg: Color(0xFFFEF7FF),
    ),
    dark: ThemeVariant(
      accent: Color(0xFFD0BCFF),
      iconFg: Color(0xFFE6E0E9),
      bg: Color(0xFF141218),
    ),
  ),
  ThemePreset(
    name: 'GitHub',
    light: ThemeVariant(
      accent: Color(0xFF0969DA),
      iconFg: Color(0xFF1F2328),
      bg: Color(0xFFFFFFFF),
      contrast: 0.6,
    ),
    dark: ThemeVariant(
      accent: Color(0xFF2F81F7),
      iconFg: Color(0xFFE6EDF3),
      bg: Color(0xFF0D1117),
      contrast: 0.6,
    ),
  ),
  ThemePreset(
    name: 'Xcode',
    light: ThemeVariant(
      accent: Color(0xFF007AFF),
      iconFg: Color(0xFF1D1D1F),
      bg: Color(0xFFFFFFFF),
      contrast: 0.6,
    ),
    dark: ThemeVariant(
      accent: Color(0xFF6699FF),
      iconFg: Color(0xFFDFDFE5),
      bg: Color(0xFF292A30),
      contrast: 0.55,
    ),
  ),
  ThemePreset(
    name: 'VS Code',
    light: ThemeVariant(
      accent: Color(0xFF007ACC),
      iconFg: Color(0xFF1F1F1F),
      bg: Color(0xFFFFFFFF),
      contrast: 0.6,
    ),
    dark: ThemeVariant(
      accent: Color(0xFF007ACC),
      iconFg: Color(0xFFD4D4D4),
      bg: Color(0xFF1E1E1E),
      contrast: 0.55,
    ),
  ),
  ThemePreset(
    name: 'Nord',
    light: ThemeVariant(
      accent: Color(0xFF5E81AC),
      iconFg: Color(0xFF2E3440),
      bg: Color(0xFFECEFF4),
      contrast: 0.5,
    ),
    dark: ThemeVariant(
      accent: Color(0xFF88C0D0),
      iconFg: Color(0xFFD8DEE9),
      bg: Color(0xFF2E3440),
      contrast: 0.45,
    ),
  ),
  ThemePreset(
    name: 'Solarized',
    light: ThemeVariant(
      accent: Color(0xFF268BD2),
      iconFg: Color(0xFF586E75),
      bg: Color(0xFFFDF6E3),
    ),
    dark: ThemeVariant(
      accent: Color(0xFF268BD2),
      iconFg: Color(0xFF93A1A1),
      bg: Color(0xFF002B36),
    ),
  ),
  ThemePreset(
    name: 'Clawed',
    light: ThemeVariant(
      accent: Color(0xFFD97757),
      iconFg: Color(0xFF1F1E1D),
      bg: Color(0xFFFAF9F5),
      contrast: 0.55,
    ),
    dark: ThemeVariant(
      accent: Color(0xFFD97757),
      iconFg: Color(0xFFE8E4D8),
      bg: Color(0xFF262624),
      contrast: 0.55,
    ),
  ),
  ThemePreset(
    name: 'Chagivity',
    light: ThemeVariant(
      accent: Color(0xFF10A37F),
      iconFg: Color(0xFF0D0D0D),
      bg: Color(0xFFFFFFFF),
      contrast: 0.55,
    ),
    dark: ThemeVariant(
      accent: Color(0xFF10A37F),
      iconFg: Color(0xFFECECEC),
      bg: Color(0xFF212121),
      contrast: 0.5,
    ),
  ),
  ThemePreset(
    name: 'Dracula',
    light: ThemeVariant(
      accent: Color(0xFF644AC9),
      iconFg: Color(0xFF1F1F1F),
      bg: Color(0xFFFFFBEB),
      contrast: 0.55,
    ),
    dark: ThemeVariant(
      accent: Color(0xFFBD93F9),
      iconFg: Color(0xFFF8F8F2),
      bg: Color(0xFF282A36),
      contrast: 0.5,
    ),
  ),
  ThemePreset(
    name: 'Gruvbox',
    light: ThemeVariant(
      accent: Color(0xFFD65D0E),
      iconFg: Color(0xFF3C3836),
      bg: Color(0xFFFBF1C7),
      contrast: 0.55,
    ),
    dark: ThemeVariant(
      accent: Color(0xFFFE8019),
      iconFg: Color(0xFFEBDBB2),
      bg: Color(0xFF282828),
      contrast: 0.55,
    ),
  ),
  ThemePreset(
    name: 'Tokyo Night',
    light: ThemeVariant(
      accent: Color(0xFF2E7DE9),
      iconFg: Color(0xFF3760BF),
      bg: Color(0xFFE1E2E7),
      contrast: 0.5,
    ),
    dark: ThemeVariant(
      accent: Color(0xFF7AA2F7),
      iconFg: Color(0xFFC0CAF5),
      bg: Color(0xFF1A1B26),
      contrast: 0.5,
    ),
  ),
  ThemePreset(
    name: 'Catppuccin',
    light: ThemeVariant(
      accent: Color(0xFF8839EF),
      iconFg: Color(0xFF4C4F69),
      bg: Color(0xFFEFF1F5),
      contrast: 0.5,
    ),
    dark: ThemeVariant(
      accent: Color(0xFFCBA6F7),
      iconFg: Color(0xFFCDD6F4),
      bg: Color(0xFF1E1E2E),
      contrast: 0.5,
    ),
  ),
  ThemePreset(
    name: 'One',
    light: ThemeVariant(
      accent: Color(0xFF4078F2),
      iconFg: Color(0xFF383A42),
      bg: Color(0xFFFAFAFA),
      contrast: 0.55,
    ),
    dark: ThemeVariant(
      accent: Color(0xFF61AFEF),
      iconFg: Color(0xFFABB2BF),
      bg: Color(0xFF282C34),
      contrast: 0.5,
    ),
  ),
  ThemePreset(
    name: 'Monokai',
    light: ThemeVariant(
      accent: Color(0xFFF92672),
      iconFg: Color(0xFF272822),
      bg: Color(0xFFFAFAFA),
      contrast: 0.55,
    ),
    dark: ThemeVariant(
      accent: Color(0xFFA6E22E),
      iconFg: Color(0xFFF8F8F2),
      bg: Color(0xFF272822),
      contrast: 0.5,
    ),
  ),
  ThemePreset(
    name: 'Ayu',
    light: ThemeVariant(
      accent: Color(0xFFF2951D),
      iconFg: Color(0xFF5C6166),
      bg: Color(0xFFFCFCFC),
      contrast: 0.6,
    ),
    dark: ThemeVariant(
      accent: Color(0xFFFFB454),
      iconFg: Color(0xFFBFBDB6),
      bg: Color(0xFF0B0E14),
      contrast: 0.6,
    ),
  ),
  ThemePreset(
    name: 'Cappuccino',
    light: ThemeVariant(
      accent: Color(0xFFB07B4F),
      iconFg: Color(0xFF4B3B2F),
      bg: Color(0xFFF2E8DC),
      contrast: 0.55,
    ),
    dark: ThemeVariant(
      accent: Color(0xFFC89B6A),
      iconFg: Color(0xFFE8DCC8),
      bg: Color(0xFF2A2320),
      contrast: 0.55,
    ),
  ),
];

/// The app's default pack: its dark variant is the kDefault* colours.
ThemePreset get kDefaultThemePreset => kThemePresets.first;
