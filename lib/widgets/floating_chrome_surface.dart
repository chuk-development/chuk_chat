import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/color_extensions.dart';

/// One step off the page background — the colour a floating card takes so it
/// separates from whatever scrolls underneath it. The sidebar panel is
/// painted in the same colour, which is why a bar floating *there* has to
/// step down to the page background instead.
Color floatingChromeBase(BuildContext context) =>
    Theme.of(context).cardColor.darken(0.02);

/// The one surface every floating piece of chrome uses: the two bars of the
/// phone sidebar, and the chips and title pill of the chat top bar.
///
/// A fill one step off whatever it floats over, at [_fillAlpha], and a
/// rounded shape. Nothing else — no blur, no tint, no outline and no shadow.
/// The composer can carry a shadow because its own 2 px border hides it; on a
/// borderless card the same shadow becomes a dark halo at the edge, which
/// reads as exactly the outline this surface is supposed to not have.
class FloatingChromeSurface extends StatelessWidget {
  const FloatingChromeSurface({
    super.key,
    required this.child,
    this.radius = 26,
    this.padding,
    this.shape,
    this.baseColor,
  });

  /// Alpha of the background fill. The composer's value.
  static const double _fillAlpha = 0.98;

  final Widget child;

  /// Corner radius. Ignored when [shape] is a circle.
  final double radius;
  final EdgeInsetsGeometry? padding;

  /// A circle for the round chips; null takes the rounded rectangle.
  final BoxShape? shape;

  /// The fill, before [_fillAlpha]. Defaults to [floatingChromeBase] — one
  /// step off the page, so the card is visible as an object floating over
  /// the chat rather than as a patch of the same colour.
  ///
  /// The sidebar passes its own: its panel is already painted in this
  /// colour, so a bar filled the same way would vanish into it. There the
  /// step goes the other way, down to the page background.
  final Color? baseColor;

  static Color fillOf(BuildContext context, {Color? baseColor}) =>
      (baseColor ?? floatingChromeBase(context)).withValues(alpha: _fillAlpha);

  @override
  Widget build(BuildContext context) {
    final bool circular = shape == BoxShape.circle;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: fillOf(context, baseColor: baseColor),
        shape: circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circular ? null : BorderRadius.circular(radius),
      ),
      child: child,
    );
  }
}
