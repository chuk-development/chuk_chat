// lib/widgets/menu_tile_group.dart
//
// The one menu surface of the app. Every dropdown and every long-press
// action sheet is drawn with it, so they all read the same.
//
// Material 3 Expressive draws a menu the way it draws a settings group: one
// filled tile per row, large corners at the ends of a run, small corners
// where two tiles meet, and a thin gap instead of a divider. There is no
// frame around the whole menu — the tiles carry the grouping on their own.

import 'package:flutter/material.dart';

/// Corner radius at the outer edges of a run.
const double kMenuOuterRadius = 26;

/// Corner radius where two tiles meet.
const double kMenuInnerRadius = 6;

/// Gap between the tiles of a run.
const double kMenuTileGap = 3;

/// Gap between two runs — what a divider turns into.
const double kMenuGroupGap = 10;

/// A run of menu rows as separate filled tiles.
///
/// [groups] holds the runs: the rows inside one run are tight together and
/// only the first and the last corner of the run round outwards; between two
/// runs sits [kMenuGroupGap] instead of a divider line.
class MenuTileGroup extends StatelessWidget {
  const MenuTileGroup({
    super.key,
    required this.groups,
    required this.color,
    this.outerRadius = kMenuOuterRadius,
  });

  /// One run of rows.
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

  final List<List<Widget>> groups;

  /// Fill of a tile. The gaps stay open, so whatever is behind the menu
  /// shows through them.
  final Color color;

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
            // Without a clip the ink of a tapped row is a plain rectangle
            // and its corners stick out of the tile.
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
