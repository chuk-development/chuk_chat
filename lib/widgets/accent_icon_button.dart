import 'package:flutter/material.dart';

/// A round, accent-filled icon button — one shared widget so the "new chat"
/// control looks identical wherever it appears (the mobile sidebar row and
/// the floating top bar). Icon only, no label.
///
/// [accent] defaults to the theme's primary colour; the icon colour is picked
/// for contrast against it (black on a light accent, white on a dark one), so
/// callers only pass a colour when they have their own accent token.
class AccentIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final String? semanticsId;

  /// Fill colour. Null → theme primary.
  final Color? accent;

  /// Outer diameter of the circle.
  final double diameter;

  /// Icon glyph size.
  final double iconSize;

  const AccentIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.semanticsId,
    this.accent,
    this.diameter = 42,
    this.iconSize = 22,
  });

  @override
  Widget build(BuildContext context) {
    final Color fill = accent ?? Theme.of(context).colorScheme.primary;
    final Color on =
        ThemeData.estimateBrightnessForColor(fill) == Brightness.dark
            ? Colors.white
            : Colors.black;
    final double pad = (diameter - iconSize) / 2;

    final Widget button = Material(
      color: fill,
      shape: const CircleBorder(),
      // No elevation: the button ends hard at its edge, no soft shadow
      // bleeding into the background around it.
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(pad),
          child: Icon(icon, size: iconSize, color: on),
        ),
      ),
    );

    return Semantics(
      identifier: semanticsId,
      button: true,
      child: Tooltip(message: tooltip, child: button),
    );
  }
}
