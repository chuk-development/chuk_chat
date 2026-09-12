import 'package:flutter/material.dart';

/// The one surface every floating piece of chrome uses: the chat composer,
/// the two bars of the phone sidebar, and the chips and title pill of the
/// chat top bar.
///
/// It is the composer's own treatment, lifted out so the pieces cannot drift
/// apart: the page background at [_fillAlpha] rather than a lighter card
/// fill, and a rounded shape. Nothing else — no blur, no tint, no outline
/// and no shadow. The composer can carry a shadow because its own 2 px
/// border hides it; on a borderless card the same shadow becomes a dark
/// halo at the edge, which reads as exactly the outline this surface is
/// supposed to not have.
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

  /// The colour of whatever this floats over. Defaults to the page
  /// background, which is right for the composer and the chat top bar. The
  /// sidebar paints its panel in a colour of its own, and a bar floating
  /// there has to be filled in *that* colour — otherwise the card is a patch
  /// of the wrong shade and its rounded edge draws a line across the panel.
  final Color? baseColor;

  static Color fillOf(BuildContext context, {Color? baseColor}) =>
      (baseColor ?? Theme.of(context).scaffoldBackgroundColor)
          .withValues(alpha: _fillAlpha);

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
