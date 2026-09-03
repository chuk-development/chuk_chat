// lib/theme/theme_presets.dart
//
// Named theme packs for the theme editor. A preset bundles the full look —
// brightness, the three palette colours, the contrast strength and the app
// font — so selecting one applies everything at once through the existing
// [AppShellConfig] setters. Colours are hand-picked to fit the app; none are
// copied from an external screenshot.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/app_shell_config.dart';

/// A complete, named theme look.
@immutable
class ThemePreset {
  const ThemePreset({
    required this.name,
    required this.brightness,
    required this.accent,
    required this.iconFg,
    required this.bg,
    this.contrast = kDefaultContrast,
    this.uiFont = kDefaultUiFontFamily,
  });

  /// Display name shown in the preset dropdown.
  final String name;

  final Brightness brightness;

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

  bool get isDark => brightness == Brightness.dark;

  /// Applies the whole look through the shell config setters. Dynamic colour
  /// is turned off first, because it would otherwise override the explicit
  /// palette a preset defines.
  void applyTo(AppShellConfig config) {
    // Always turn dynamic colour off — the passed-in flag may be a stale
    // snapshot, and the service ignores an unchanged value anyway. Leaving it
    // on would let Material You keep overriding the preset's palette.
    unawaited(config.setDynamicColorEnabled(false));
    config.setThemeMode(brightness);
    config.setAccentColor(accent);
    config.setIconFgColor(iconFg);
    config.setBgColor(bg);
    unawaited(config.setContrast(contrast));
    unawaited(config.setUiFontFamily(uiFont));
  }
}

/// The built-in preset packs, in the order they appear in the dropdown. Aya
/// (the app default) is first.
const List<ThemePreset> kThemePresets = <ThemePreset>[
  ThemePreset(
    name: 'Aya',
    brightness: Brightness.dark,
    accent: kDefaultAccentColor,
    iconFg: kDefaultIconFgColor,
    bg: kDefaultBgColor,
  ),
  ThemePreset(
    name: 'Material',
    brightness: Brightness.dark,
    accent: Color(0xFFD0BCFF),
    iconFg: Color(0xFFE6E0E9),
    bg: Color(0xFF141218),
  ),
  ThemePreset(
    name: 'Xcode',
    brightness: Brightness.dark,
    accent: Color(0xFF6699FF),
    iconFg: Color(0xFFDFDFE5),
    bg: Color(0xFF1F1F24),
    contrast: 0.55,
  ),
  ThemePreset(
    name: 'Nord',
    brightness: Brightness.dark,
    accent: Color(0xFF88C0D0),
    iconFg: Color(0xFFD8DEE9),
    bg: Color(0xFF2E3440),
    contrast: 0.45,
  ),
  ThemePreset(
    name: 'Solarized Dark',
    brightness: Brightness.dark,
    accent: Color(0xFF268BD2),
    iconFg: Color(0xFF93A1A1),
    bg: Color(0xFF002B36),
  ),
  ThemePreset(
    name: 'Cappuccino',
    brightness: Brightness.light,
    accent: Color(0xFFB07B4F),
    iconFg: Color(0xFF4B3B2F),
    bg: Color(0xFFF2E8DC),
    contrast: 0.55,
    uiFont: kChatFontFamilyMerriweather,
  ),
  ThemePreset(
    name: 'GitHub',
    brightness: Brightness.light,
    accent: Color(0xFF0969DA),
    iconFg: Color(0xFF1F2328),
    bg: Color(0xFFFFFFFF),
    contrast: 0.6,
  ),
  ThemePreset(
    name: 'Solarized Light',
    brightness: Brightness.light,
    accent: Color(0xFF268BD2),
    iconFg: Color(0xFF586E75),
    bg: Color(0xFFFDF6E3),
  ),
];
