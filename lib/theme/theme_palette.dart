// lib/theme/theme_palette.dart
//
// An exact surface palette for a theme pack. Most packs carry only three
// colours (accent, foreground, background) and [buildAppTheme] derives the
// surface ladder from the background. A pack copied from a real product
// (Plane) has its own hand-picked greys for every layer, and the derived
// ladder cannot hit them. Such a pack carries a [ThemePalette]; while the
// pack is active (its three colours and contrast still match), the theme
// uses these values instead of the derived ones.

import 'package:flutter/material.dart';

/// The hand-picked colours of one pack variant, from back to front.
@immutable
class ThemePalette {
  const ThemePalette({
    required this.surfaceLowest,
    required this.surfaceLow,
    required this.surface,
    required this.surfaceHigh,
    required this.surfaceHighest,
    required this.secondaryContainer,
    required this.selection,
    required this.onSelection,
    required this.selectedFill,
    required this.onSelectedFill,
    required this.outline,
    required this.outlineVariant,
    required this.onSurfaceVariant,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.error,
    required this.errorContainer,
    required this.onErrorContainer,
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.warningContainer,
    required this.onWarningContainer,
    this.userBubble,
    this.onUserBubble,
  });

  /// Behind the page: the frame around the panels.
  final Color surfaceLowest;

  /// Text fields, bottom sheets.
  final Color surfaceLow;

  /// Cards, the resting sidebar row, snack bars.
  final Color surface;

  /// Menus, dialogs, a hovered or pressed row.
  final Color surfaceHigh;

  /// Tooltips, switch tracks: the step in front of everything else.
  final Color surfaceHighest;

  /// The selected entry of a navigation list (settings sections).
  final Color secondaryContainer;

  /// The fill of a selected row (the open chat).
  final Color selection;

  /// Text and icons on [selection].
  final Color onSelection;

  /// The solid fill of a picked segment, chip or tab.
  final Color selectedFill;

  /// Label on [selectedFill].
  final Color onSelectedFill;

  final Color outline;
  final Color outlineVariant;

  /// Secondary text: hints, sub-labels, timestamps.
  final Color onSurfaceVariant;

  final Color primaryContainer;
  final Color onPrimaryContainer;

  final Color error;
  final Color errorContainer;
  final Color onErrorContainer;

  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;

  final Color warning;
  final Color warningContainer;
  final Color onWarningContainer;

  /// The user's own chat bubble. Null keeps the accent bubble.
  final Color? userBubble;

  /// Text on [userBubble].
  final Color? onUserBubble;
}
