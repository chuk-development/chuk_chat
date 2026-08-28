import 'package:flutter/material.dart';

/// The icon foreground colour the chat-mode selector and its menus paint with.
/// Ported from chuk_chat so the composer's pill matches it exactly.
extension ThemeDataIconColorX on ThemeData {
  Color get resolvedIconColor => iconTheme.color ?? colorScheme.onSurface;
}

/// The Material 3 surface-container and on-surface-variant roles the
/// expressive settings widgets paint with, read as `Theme.of(context).m3`.
///
/// chuk_chat carries these as a full [ThemeExtension] with lerp support; the
/// modern [ColorScheme] already exposes every role we use, so this is a thin
/// pass-through rather than a second copy of the palette.
extension ThemeDataM3X on ThemeData {
  M3Tokens get m3 => M3Tokens(colorScheme);
}

/// A small view over the [ColorScheme]'s Material 3 container tokens, so the
/// expressive settings kit reads `theme.m3.surfaceContainer` the same way it
/// did in chuk_chat.
class M3Tokens {
  const M3Tokens(this._cs);

  final ColorScheme _cs;

  Color get surfaceContainerLowest => _cs.surfaceContainerLowest;
  Color get surfaceContainerLow => _cs.surfaceContainerLow;
  Color get surfaceContainer => _cs.surfaceContainer;
  Color get surfaceContainerHigh => _cs.surfaceContainerHigh;
  Color get surfaceContainerHighest => _cs.surfaceContainerHighest;
  Color get onSurfaceVariant => _cs.onSurfaceVariant;
  Color get outlineVariant => _cs.outlineVariant;
}
