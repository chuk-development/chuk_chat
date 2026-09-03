// lib/theme/theme_presets.dart
//
// Named theme packs for the theme editor. A pack now bundles TWO complete
// looks — a light variant and a dark variant — so the dark-mode toggle flips
// between them without leaving the pack. Selecting a pack applies the variant
// that matches the current brightness; flipping the toggle re-applies the
// sibling variant.
//
// Each variant carries the full look: the three palette colours, the contrast
// strength and the app font. Everything is applied through the existing
// [AppShellConfig] setters.
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

/// One complete look: palette + contrast + font, for a single brightness.
@immutable
class ThemeVariant {
  const ThemeVariant({
    required this.accent,
    required this.iconFg,
    required this.bg,
    this.contrast = kDefaultContrast,
    this.uiFont = kDefaultUiFontFamily,
  });

  /// Accent / primary colour.
  final Color accent;

  /// Icon and foreground text colour.
  final Color iconFg;

  /// Scaffold background colour.
  final Color bg;

  /// Surface/outline separation strength (see [buildAppTheme]).
  final double contrast;

  /// App-chrome font family id (see [kSupportedUiFontFamilies]).
  final String uiFont;
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
    required String uiFont,
  }) {
    final v = variantFor(brightness);
    return v.accent == accent &&
        v.iconFg == iconFg &&
        v.bg == bg &&
        v.contrast == contrast &&
        v.uiFont == uiFont;
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
    unawaited(config.setUiFontFamily(v.uiFont));
  }
}

/// The built-in packs, in dropdown order. Aya (the app default) is first.
const List<ThemePreset> kThemePresets = <ThemePreset>[
  ThemePreset(
    name: 'Aya',
    light: ThemeVariant(
      accent: Color(0xFF2F5EA8),
      iconFg: Color(0xFF1A1B1F),
      bg: Color(0xFFF7F9FF),
      contrast: 0.55,
    ),
    dark: ThemeVariant(
      accent: kDefaultAccentColor,
      iconFg: kDefaultIconFgColor,
      bg: kDefaultBgColor,
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
      uiFont: kChatFontFamilyMerriweather,
    ),
    dark: ThemeVariant(
      accent: Color(0xFFC89B6A),
      iconFg: Color(0xFFE8DCC8),
      bg: Color(0xFF2A2320),
      contrast: 0.55,
      uiFont: kChatFontFamilyMerriweather,
    ),
  ),
];
