import 'package:flutter/material.dart';

/// A menu drawn as a run of filled tiles instead of one boxed card.
///
/// No frame, no elevation, no dividers: each row is its own filled tile, the
/// outward corners of a run stay large and the joints between neighbours
/// tighten, and what used to be a divider becomes a wider gap that starts a
/// new run. The 3 px between tiles is left open, so whatever the menu sits on
/// shows through — that gap is what makes the grouping readable.
///
/// The rows themselves are unchanged; this only gives them their shape.
const double kMenuOuterRadius = 26;

/// Where two tiles of one run meet.
const double kMenuInnerRadius = 6;

/// Air between two tiles of one run.
const double kMenuTileGap = 3;

/// Air instead of a divider, between two runs.
const double kMenuGroupGap = 10;

class MenuTileGroup extends StatelessWidget {
  const MenuTileGroup({
    super.key,
    required this.groups,
    required this.color,
    this.outerRadius = kMenuOuterRadius,
  });

  /// One run of rows that belong together.
  MenuTileGroup.single({
    Key? key,
    required List<Widget> children,
    required Color color,
    double outerRadius = kMenuOuterRadius,
  }) : this(
          key: key,
          groups: <List<Widget>>[children],
          color: color,
          outerRadius: outerRadius,
        );

  /// Each list is one connected run; the gap between runs replaces a divider.
  final List<List<Widget>> groups;

  /// Tile fill. It has to be a step above whatever is behind the menu, or the
  /// gaps disappear and the run reads as one block again.
  final Color color;

  /// 26 is nearly a capsule on a 48 px row; take 20 for shorter rows.
  final double outerRadius;

  @override
  Widget build(BuildContext context) {
    final List<Widget> out = <Widget>[];
    for (final List<Widget> run in groups) {
      if (run.isEmpty) continue;
      if (out.isNotEmpty) out.add(const SizedBox(height: kMenuGroupGap));
      for (int i = 0; i < run.length; i++) {
        if (i > 0) out.add(const SizedBox(height: kMenuTileGap));
        out.add(
          Material(
            color: color,
            // Without the clip the ink splash runs square over the corners.
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(i == 0 ? outerRadius : kMenuInnerRadius),
                bottom: Radius.circular(
                  i == run.length - 1 ? outerRadius : kMenuInnerRadius,
                ),
              ),
            ),
            child: run[i],
          ),
        );
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: out,
    );
  }
}
