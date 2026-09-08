/// Bubble geometry shared by every message bubble.
///
/// One rule: big rounding everywhere, and a small radius only where another
/// bubble of the same sender is stacked directly above or below, so a run of
/// messages reads as ONE connected group. The outer corner on the sender's own
/// side stays fully round.
library;

import 'package:flutter/material.dart';

/// Where a bubble sits inside a run of consecutive same-sender messages.
enum BubblePosition { single, first, middle, last }

/// The position of item [index] in a run of [length].
BubblePosition bubblePositionFor(int index, int length) {
  if (length <= 1) return BubblePosition.single;
  if (index == 0) return BubblePosition.first;
  if (index == length - 1) return BubblePosition.last;
  return BubblePosition.middle;
}

/// The position derived from the two flags the chat screens already carry.
BubblePosition bubblePositionFromFlags({
  required bool startsNewGroup,
  required bool endsGroup,
}) {
  if (startsNewGroup && endsGroup) return BubblePosition.single;
  if (startsNewGroup) return BubblePosition.first;
  if (endsGroup) return BubblePosition.last;
  return BubblePosition.middle;
}

/// The corner radii for a bubble at [pos]. [isMine] flips which side carries
/// the tail.
BorderRadius bubbleRadius(
  bool isMine,
  BubblePosition pos, {
  double big = 22,
  double small = 7,
}) {
  final Radius b = Radius.circular(big);
  final Radius s = Radius.circular(small);
  final bool connectedAbove =
      pos == BubblePosition.middle || pos == BubblePosition.last;
  final bool connectedBelow =
      pos == BubblePosition.first || pos == BubblePosition.middle;
  final Radius top = connectedAbove ? s : b;
  final Radius bottom = connectedBelow ? s : b;
  return BorderRadius.only(
    topLeft: isMine ? b : top,
    topRight: isMine ? top : b,
    bottomLeft: isMine ? b : bottom,
    bottomRight: isMine ? bottom : b,
  );
}

/// Formats seconds as `m:ss` (75 → "1:15"). Used for voice clips.
String formatClock(int seconds) =>
    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
