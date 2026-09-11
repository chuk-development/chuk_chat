/// The veil a floating top bar sits on.
///
/// Nothing in this app puts a solid band across the top of a scrolling surface:
/// a band has an edge, and the edge draws a line through the content. Instead
/// the bar floats on a gradient that is heaviest behind the status bar — where
/// the clock and the battery have to stay readable over whatever scrolls past —
/// and thins out to nothing below the row.
///
/// One widget, so the chat header and every full-screen reader wear the same
/// veil (docs/DESIGN.md §4).
library;

import 'package:flutter/material.dart';

/// The gradient itself, for surfaces that place their own bar (a pinned
/// `SliverAppBar` draws behind the status bar on its own).
BoxDecoration topVeilDecoration(ColorScheme scheme) => BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[
      scheme.surface.withValues(alpha: 0.78),
      scheme.surface.withValues(alpha: 0.58),
      scheme.surface.withValues(alpha: 0.26),
      scheme.surface.withValues(alpha: 0),
    ],
    stops: const <double>[0, 0.36, 0.74, 1],
  ),
);

class TopVeil extends StatelessWidget {
  const TopVeil({super.key, required this.child, this.fadeBelow = 26});

  /// The bar itself: the row of targets, the title, whatever floats.
  final Widget child;

  /// How much room the gradient gets under [child] to reach zero.
  final double fadeBelow;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: topVeilDecoration(scheme),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(height: MediaQuery.paddingOf(context).top),
          child,
          SizedBox(height: fadeBelow),
        ],
      ),
    );
  }
}

/// The veil under a floating bottom bar: nothing at the top, heaviest at the
/// very bottom, so a list scrolls out under the bar instead of stopping at it.
BoxDecoration bottomVeilDecoration(ColorScheme scheme) => BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[
      scheme.surface.withValues(alpha: 0),
      scheme.surface.withValues(alpha: 0.38),
      scheme.surface.withValues(alpha: 0.78),
      scheme.surface.withValues(alpha: 0.92),
    ],
    stops: const <double>[0, 0.28, 0.66, 1],
  ),
);

/// [child] on the bottom veil, with room above it for the gradient to fade in.
class BottomVeil extends StatelessWidget {
  const BottomVeil({super.key, required this.child, this.fadeAbove = 26});

  final Widget child;
  final double fadeAbove;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: bottomVeilDecoration(Theme.of(context).colorScheme),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(height: fadeAbove),
          child,
        ],
      ),
    );
  }
}
