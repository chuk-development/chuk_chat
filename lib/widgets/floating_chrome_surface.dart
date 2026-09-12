import 'package:flutter/material.dart';

/// The one surface every floating piece of chrome uses: the chat composer,
/// the two bars of the phone sidebar, and the chips and title pill of the
/// chat top bar.
///
/// It is the composer's own treatment, lifted out so the pieces cannot drift
/// apart: the page background at [_fillAlpha] rather than a lighter card
/// fill, a rounded shape and one soft shadow. No blur, no tint, and no
/// outline — plain transparency is what makes a floating element read as
/// floating instead of as a second surface stacked on the first.
class FloatingChromeSurface extends StatelessWidget {
  const FloatingChromeSurface({
    super.key,
    required this.child,
    this.radius = 26,
    this.padding,
    this.shape,
  });

  /// Alpha of the background fill. The composer's value.
  static const double _fillAlpha = 0.98;

  final Widget child;

  /// Corner radius. Ignored when [shape] is a circle.
  final double radius;
  final EdgeInsetsGeometry? padding;

  /// A circle for the round chips; null takes the rounded rectangle.
  final BoxShape? shape;

  static Color fillOf(BuildContext context) =>
      Theme.of(context).scaffoldBackgroundColor.withValues(alpha: _fillAlpha);

  @override
  Widget build(BuildContext context) {
    final bool circular = shape == BoxShape.circle;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: fillOf(context),
        shape: circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circular ? null : BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}
