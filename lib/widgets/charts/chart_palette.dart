// lib/widgets/charts/chart_palette.dart
//
// Every colour a chart paints with, resolved once from the theme and handed
// to the painter. Nothing below is a hard-coded hex except the series hues,
// which are the app's own coworker palette — the same thirteen the profile
// editor offers, so a chart sits in the same colour world as the faces.

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/agent_face.dart' show kAgentAccents;

/// The resolved colours for one chart in one theme.
@immutable
class ChartPalette {
  const ChartPalette({
    required this.text,
    required this.muted,
    required this.faint,
    required this.grid,
    required this.baseline,
    required this.border,
    required this.surface,
    required this.accent,
    required this.up,
    required this.down,
    required this.series,
    required this.isDark,
  });

  /// Reads everything off the theme. [accent] overrides the scheme's primary,
  /// which is what an open thread does: the chart takes the coworker's colour.
  factory ChartPalette.of(BuildContext context, {Color? accent}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = scheme.brightness == Brightness.dark;
    final Color onSurface = scheme.onSurface;
    return ChartPalette(
      text: onSurface,
      muted: onSurface.withValues(alpha: 0.62),
      faint: onSurface.withValues(alpha: 0.40),
      grid: onSurface.withValues(alpha: dark ? 0.10 : 0.08),
      baseline: onSurface.withValues(alpha: dark ? 0.26 : 0.20),
      border: onSurface.withValues(alpha: 0.12),
      surface: scheme.surface,
      accent: accent ?? scheme.primary,
      // The up/down pair is derived, not invented. The red takes the HUE of
      // the theme's error role and the green takes the hue of the app's own
      // green accent; both are then given the app's fixed saturation and a
      // lightness picked for the theme — the same rule `agentAccent` uses, so
      // a loss bar and a coworker's face carry the same kind of colour. The
      // raw roles are unusable as they stand: M3's dark error is a pale pink
      // that reads as "disabled", not as "down 19 points".
      up: _fixed(kAgentAccents[8], dark ? 0.52 : 0.36),
      down: _fixed(scheme.error, dark ? 0.62 : 0.46),
      series: <Color>[
        for (final Color c in kAgentAccents) _legible(c, dark: dark),
      ],
      isDark: dark,
    );
  }

  final Color text;
  final Color muted;
  final Color faint;
  final Color grid;
  final Color baseline;
  final Color border;
  final Color surface;
  final Color accent;
  final Color up;
  final Color down;
  final List<Color> series;
  final bool isDark;

  /// The colour for series [index] when nothing was asked for.
  Color seriesColor(int index) => series[index % series.length];

  /// The colour of a bar: what the agent asked for wins; otherwise the sign
  /// decides for a delta chart and the palette decides for everything else.
  Color barColor({
    required Color? asked,
    required int index,
    required double value,
    required bool bySign,
  }) {
    if (asked != null) return legible(asked);
    if (bySign) return value < 0 ? down : up;
    return seriesColor(index);
  }

  /// Pulls a colour far enough from the card behind it to be seen. A party
  /// colour is often near-black (CDU) or near-white, and a bar that matches
  /// the card is an invisible bar.
  Color legible(Color c) => _legible(c, dark: isDark);

  /// The hue of [seed] at the app's fixed saturation and a chosen lightness.
  static Color _fixed(Color seed, double lightness) {
    final HSLColor hsl = HSLColor.fromColor(seed);
    return HSLColor.fromAHSL(1, hsl.hue, 0.72, lightness).toColor();
  }

  static Color _legible(Color c, {required bool dark}) {
    final HSLColor hsl = HSLColor.fromColor(c);
    if (dark) {
      // Nothing darker than 28 % lightness on a dark card.
      if (hsl.lightness < 0.30) {
        return hsl.withLightness(0.62).withSaturation(
          hsl.saturation < 0.12 ? 0.0 : hsl.saturation.clamp(0.25, 1.0),
        ).toColor();
      }
      return c;
    }
    // Nothing brighter than 86 % lightness on a light card.
    if (hsl.lightness > 0.86) {
      return hsl.withLightness(0.62).toColor();
    }
    return c;
  }

  /// [c] pushed until TEXT in it is readable on the card.
  ///
  /// A bar may be any colour and still work — it is a big filled shape. The
  /// number above it is four thin glyphs, and FDP yellow on a white card is
  /// not a number, it is a smudge. This walks the lightness until the contrast
  /// ratio against [surface] clears 3:1, which is the floor for large text.
  Color ink(Color c) {
    Color out = legible(c);
    HSLColor hsl = HSLColor.fromColor(out);
    for (int guard = 0; guard < 14 && _contrast(out, surface) < 3.0; guard++) {
      hsl = hsl.withLightness(
        (isDark ? hsl.lightness + 0.05 : hsl.lightness - 0.05).clamp(0.0, 1.0),
      );
      out = hsl.toColor();
    }
    return out;
  }

  static double _contrast(Color a, Color b) {
    final double la = a.computeLuminance() + 0.05;
    final double lb = b.computeLuminance() + 0.05;
    return la > lb ? la / lb : lb / la;
  }

  /// A readable colour to print ON a filled bar of [fill].
  Color onFill(Color fill) {
    final double luminance = fill.computeLuminance();
    return luminance > 0.55 ? const Color(0xFF101014) : const Color(0xFFFFFFFF);
  }
}
