// Shared design tokens for the OpenUI components.
//
// Every component reads its spacing, radii and surface colours from
// here, so the components look like one family and like the chat
// around them. Rules: docs/DESIGN.md (Material 3 Expressive, one
// button family, no glow, no coloured BoxShadow, no gradient on a
// control). See docs/OPENUI.md, "Theme tokens".

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/utils/chat_font_resolver.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/// Fixed sizes: spacing, radii, paddings.
abstract final class OpenUiTokens {
  /// The upstream gap scale (`Stack`/`Card` `gap`): none 0, xs 4,
  /// s 8, m 12, l 16, xl 24, 2xl 32. An unknown name gives [gapDefault].
  static double gap(String? name) => switch (name) {
    'none' => 0,
    'xs' => 4,
    's' => 8,
    'm' => 12,
    'l' => 16,
    'xl' => 24,
    '2xl' => 32,
    _ => gapDefault,
  };

  /// The default gap between the blocks of a card or stack ("m").
  static const double gapDefault = 12;

  /// The gap between the blocks of the chat root `Card`.
  static const double rootGap = 14;

  /// Corner of a card surface (`Card` variant card/sunk, card blocks).
  /// docs/DESIGN.md section 6: cards are 14 to 18.
  static const double radiusCard = 16;

  /// Corner of a tile inside a card (a sunk row, a code block, an
  /// image inside a card, a callout).
  static const double radiusInner = 12;

  /// Corner of a small chip or tag that is not a full pill.
  static const double radiusChip = 8;

  /// Stadium corner for pills (buttons, chips, tags).
  static const double radiusPill = 999;

  /// Inner padding of a card surface.
  static const EdgeInsets cardPadding = EdgeInsets.all(14);

  /// Inner padding of a tile inside a card.
  static const EdgeInsets innerPadding = EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 10,
  );

  /// The width of the 1 px hairline border on card surfaces.
  static const double borderWidth = 1;

  /// The chat column width that the gallery uses (bubble width on a
  /// phone; the reading measure on desktop is 720).
  static const double chatColumnWidth = 420;
}

/// Colours and text styles, taken from the app theme.
///
/// ```dart
/// final t = OpenUiTheme.of(context);
/// DecoratedBox(decoration: t.cardDecoration(), child: …);
/// ```
@immutable
class OpenUiTheme {
  const OpenUiTheme._(this._theme);

  /// The tokens for the current app theme.
  factory OpenUiTheme.of(BuildContext context) =>
      OpenUiTheme._(Theme.of(context));

  final ThemeData _theme;

  /// The color scheme of the app.
  ColorScheme get scheme => _theme.colorScheme;

  /// The text theme of the app.
  TextTheme get text => _theme.textTheme;

  /// Whether the app is in dark mode.
  bool get isDark => _theme.brightness == Brightness.dark;

  /// Fill of a raised card (`variant: "card"`, the default).
  Color get cardColor => scheme.surfaceContainerLow;

  /// Fill of a recessed card or tile (`variant: "sunk"`).
  Color get sunkColor =>
      scheme.surfaceContainerHighest.withValues(alpha: isDark ? 0.55 : 0.7);

  /// Hairline border of a card surface. In light mode a quiet line, as
  /// on the app's own cards; `outlineVariant` there is near black.
  Color get borderColor => isDark
      ? scheme.outlineVariant.withValues(alpha: 0.5)
      : scheme.onSurface.withValues(alpha: 0.12);

  /// Divider between rows (table rows, list rows, accordion items).
  Color get hairline => isDark
      ? scheme.outlineVariant.withValues(alpha: 0.5)
      : scheme.onSurface.withValues(alpha: 0.10);

  /// The rule under a table header: a little stronger than [hairline].
  Color get headerRule => isDark
      ? scheme.outlineVariant.withValues(alpha: 0.8)
      : scheme.onSurface.withValues(alpha: 0.22);

  /// The strip behind a segmented switch (Tabs). In light mode a
  /// neutral tint; the tinted surface ladder there is close to the
  /// pastel accent, so the selected segment would hardly show.
  /// Opaque: the switch sets its own alpha on it.
  Color get segmentStripColor => isDark
      ? scheme.surfaceContainerHighest
      : Color.alphaBlend(
          scheme.onSurface.withValues(alpha: 0.07),
          scheme.surface,
        );

  /// The filled capsule of the selected segment. In light mode the
  /// accent is darkened until it stands clear of the strip.
  Color get segmentSelectedColor => isDark
      ? scheme.primary
      : accentForegroundFor(
          scheme.primary,
          segmentStripColor,
          minContrast: 2.2,
        );

  /// The label on [segmentSelectedColor].
  Color get onSegmentSelectedColor => isDark
      ? scheme.onPrimary
      : readableOnFill(segmentSelectedColor, scheme.onPrimary, minContrast: 4.5);

  /// The user's chat font family (the AI answer font), as in the
  /// message bubble. Arimo when the user picked the system font.
  String get chatFontFamily =>
      resolveChatFontFamily(AppThemeService.instance.chatFontFamily) ??
      kFontFamilyArimo;

  /// The user's chat font size, as in the message bubble.
  double get chatFontSize => AppThemeService.instance.chatFontSize;

  /// Main text colour.
  Color get textColor => scheme.onSurface;

  /// Quieter text (subtitles, hints, captions).
  Color get mutedColor => scheme.onSurfaceVariant;

  /// The accent (links, selected states, the primary button fill).
  Color get accent => scheme.primary;

  /// A positive value or state.
  Color get success => _theme.m3.success;

  /// A warning.
  Color get warning => _theme.m3.warning;

  /// An error or a negative value.
  Color get danger => scheme.error;

  /// Info (the accent).
  Color get info => scheme.primary;

  /// The colour of an upstream status variant name: info, success,
  /// warning, error/danger; anything else is the muted colour.
  Color statusColor(String? variant) => switch (variant) {
    'info' => info,
    'success' => success,
    'warning' => warning,
    'error' || 'danger' => danger,
    _ => mutedColor,
  };

  /// A soft fill for a status colour (callouts, tags). Never a glow.
  Color statusFill(String? variant) => switch (variant) {
    'info' ||
    'success' ||
    'warning' ||
    'error' ||
    'danger' => statusColor(variant).withValues(alpha: isDark ? 0.16 : 0.12),
    _ => sunkColor,
  };

  /// The decoration of a card surface. [variant] is the upstream
  /// `card` / `sunk` / `clear`. No shadow: cards are flat.
  BoxDecoration cardDecoration({String variant = 'card', double? radius}) {
    final r = BorderRadius.circular(radius ?? OpenUiTokens.radiusCard);
    return switch (variant) {
      'sunk' => BoxDecoration(color: sunkColor, borderRadius: r),
      'clear' => BoxDecoration(borderRadius: r),
      _ => BoxDecoration(
        color: cardColor,
        borderRadius: r,
        border: Border.all(color: borderColor, width: OpenUiTokens.borderWidth),
      ),
    };
  }

  /// Title text inside a card (`CardHeader` title, block headings).
  TextStyle get titleStyle => (text.titleMedium ?? const TextStyle()).copyWith(
    color: textColor,
    fontWeight: FontWeight.w700,
  );

  /// Body text.
  TextStyle get bodyStyle =>
      (text.bodyMedium ?? const TextStyle()).copyWith(color: textColor);

  /// Small, quiet text (subtitles, captions, hints).
  TextStyle get captionStyle =>
      (text.bodySmall ?? const TextStyle()).copyWith(color: mutedColor);
}
