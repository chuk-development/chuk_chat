// lib/theme/legacy_pack_font_migration.dart
//
// One-time migration for the UI font that a theme pack set without asking.
//
// Until 2026-10 the Cappuccino pack also set the app-chrome font to
// Merriweather. Packs no longer touch the font, but users who applied
// Cappuccino still carry that Merriweather. No pack id was ever stored, so
// the only trace of "the pack set it" is the look itself: the stored palette
// and contrast still equal one of Cappuccino's two variants exactly, and the
// UI font is Merriweather. Only that exact combination is moved to the
// default font. A Merriweather that sits next to any other palette was picked
// by hand and stays.
//
// The Cappuccino values are frozen here on purpose: if the pack's colours
// change later, the migration must still recognise what old installs stored.

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';

/// Palette + contrast of one legacy pack variant that set a UI font.
@immutable
class _LegacyFontVariant {
  const _LegacyFontVariant(this.accent, this.iconFg, this.bg, this.contrast);

  final Color accent;
  final Color iconFg;
  final Color bg;
  final double contrast;
}

/// Cappuccino light and dark, as they shipped with `uiFont: merriweather`.
const List<_LegacyFontVariant> _kLegacyMerriweatherVariants =
    <_LegacyFontVariant>[
      _LegacyFontVariant(
        Color(0xFFB07B4F),
        Color(0xFF4B3B2F),
        Color(0xFFF2E8DC),
        0.55,
      ),
      _LegacyFontVariant(
        Color(0xFFC89B6A),
        Color(0xFFE8DCC8),
        Color(0xFF2A2320),
        0.55,
      ),
    ];

/// Whether [uiFont] was most likely set by the legacy Cappuccino pack and
/// not chosen by hand: it is Merriweather and the stored look equals a
/// Cappuccino variant exactly.
bool uiFontCameFromLegacyPack({
  required String uiFont,
  required Color accent,
  required Color iconFg,
  required Color bg,
  required double contrast,
}) {
  if (uiFont != kChatFontFamilyMerriweather) return false;
  for (final v in _kLegacyMerriweatherVariants) {
    if (v.accent.toARGB32() == accent.toARGB32() &&
        v.iconFg.toARGB32() == iconFg.toARGB32() &&
        v.bg.toARGB32() == bg.toARGB32() &&
        (v.contrast - contrast).abs() < 1e-9) {
      return true;
    }
  }
  return false;
}

/// The UI font after the migration: [kDefaultUiFontFamily] when the pack set
/// it, otherwise [uiFont] unchanged.
String migrateLegacyPackUiFont({
  required String uiFont,
  required Color accent,
  required Color iconFg,
  required Color bg,
  required double contrast,
}) {
  return uiFontCameFromLegacyPack(
        uiFont: uiFont,
        accent: accent,
        iconFg: iconFg,
        bg: bg,
        contrast: contrast,
      )
      ? kDefaultUiFontFamily
      : uiFont;
}
