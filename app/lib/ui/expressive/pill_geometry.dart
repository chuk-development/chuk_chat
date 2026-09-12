/// The numbers every pill-shaped group of segments in the app is built from:
/// the bottom navigation and the filter switches above the lists.
///
/// One capsule inside another capsule. The outer radius is the inner radius
/// plus the inset, so the two curves are concentric: the ring of background
/// around a selected segment is as thick at the corners as it is along the
/// edges, and the first and the last segment follow the outer curve instead of
/// cutting across it. The same inset is the gap between two neighbours, so the
/// rhythm is even from one end to the other.
///
/// The ring is wider than the segment is short of a touch target, and the
/// segment takes the difference back: [tapSlop] of the ring above and below a
/// segment belongs to that segment's tap area, so a capsule that PAINTS
/// [segmentHeight] is [tapHeight] tall to a finger. The shell therefore pads
/// less at the top and the bottom than it does at the ends — see
/// [shellPadding] — and the ring still reads the same thickness all the way
/// round.
///
/// Nothing here is a rounded rectangle. A segment is an oval at rest and it
/// stays an oval while it is held: a press springs, it never squares the
/// corners off. A press also selects at once, on pointer down, so a segment
/// never has to hint at a selection that has not happened yet.
library;

import 'package:flutter/widgets.dart';

abstract final class PillGeometry {
  const PillGeometry._();

  /// The background that shows around the segments: above, below, at both ends
  /// and between two neighbours.
  static const double inset = 8;

  /// The height of one segment, and so the height of the filled capsule.
  static const double segmentHeight = 44;

  /// How far a segment's tap area reaches into the ring, above and below.
  /// Transparent: it takes presses, it paints nothing.
  static const double tapSlop = 4;

  /// What a finger hits: the capsule plus the ring it reaches into. At or
  /// above the smallest touch target the layout suite accepts.
  static const double tapHeight = segmentHeight + tapSlop * 2;

  /// The height of the whole pill.
  static const double height = segmentHeight + inset * 2;

  /// The padding of the shell that holds the segments. Short of [inset] top
  /// and bottom by exactly the [tapSlop] each segment carries itself.
  static const EdgeInsets shellPadding = EdgeInsets.symmetric(
    horizontal: inset,
    vertical: inset - tapSlop,
  );

  /// The corner of a segment: half its height, which is a stadium.
  static const double segmentRadius = segmentHeight / 2;

  /// The corner of the pill that holds the segments.
  static const double radius = segmentRadius + inset;

  // -- the switch above a list -------------------------------------------
  //
  // Not the same control as the navigation, and not the same shape. The
  // navigation floats over content, so it keeps a ring of background around
  // its capsule. The switch belongs to the list under it, sits over the whole
  // width and is read at a glance: it is flatter, and its fill all but fills
  // it, with a hairline of background left around the capsule.

  /// The hairline of background around the switch's capsule.
  static const double filterInset = 3;

  /// The height of one switch segment, and so of its filled capsule. Short of
  /// the touch minimum on purpose — the switch is a strip over a list, not a
  /// bar — so a segment takes the hairline around it as tap slop and a finger
  /// still gets its 48.
  static const double filterSegmentHeight = 32;

  /// How far a switch segment's tap area reaches past the capsule, into the
  /// hairline and the air above and below the strip. Transparent: it takes
  /// presses, it paints nothing, and it is what keeps a 32 tall capsule at a
  /// 48 target.
  /// 8, which is what a 32 tall capsule needs to reach the 48 the layout
  /// suite enforces.
  static const double filterTapSlop = 8;

  /// What a finger hits on the switch: the whole strip.
  static const double filterTapHeight =
      filterSegmentHeight + filterTapSlop * 2;

  /// The height of the whole switch.
  static const double filterHeight = filterSegmentHeight + filterInset * 2;

  /// The corner of a switch segment: a stadium.
  static const double filterSegmentRadius = filterSegmentHeight / 2;

  /// The corner of the shell that holds them, concentric with the capsule.
  static const double filterRadius = filterSegmentRadius + filterInset;

  /// The padding of that shell.
  static const EdgeInsets filterShellPadding = EdgeInsets.all(filterInset);
}
