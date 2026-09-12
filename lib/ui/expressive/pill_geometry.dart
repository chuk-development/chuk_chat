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
  static const double inset = 4;

  /// The height of one segment, and so the height of the filled capsule.
  /// The capsule carries the pill: the ring around it is a hairline of
  /// background, not a margin, so the fill reads as the control and not as a
  /// sticker inside it.
  static const double segmentHeight = 52;

  /// How far a segment's tap area reaches into the ring, above and below.
  /// Transparent: it takes presses, it paints nothing. Zero while the capsule
  /// itself is over the touch minimum.
  static const double tapSlop = 0;

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
}
