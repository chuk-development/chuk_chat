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

/// The outer corner radius: every corner that does not touch another block of
/// the same run.
const double kBubbleRadiusBig = 22;

/// The inner corner radius: the corners where two blocks of one run touch.
const double kBubbleRadiusSmall = 7;

/// The vertical gap between two blocks of the SAME run. Small enough that the
/// two read as one body of text, big enough to keep the two fills apart.
const double kBubbleGapInGroup = 3;

/// The vertical gap between two runs — a different sender, a new day, or a
/// long pause. Roughly five times the gap inside a run, so the eye sorts the
/// thread into groups before it reads a word.
const double kBubbleGapBetweenGroups = 14;

/// A pause this long ends a run: two messages further apart than this are two
/// separate thoughts, even from the same sender.
const Duration kBubbleGroupPause = Duration(minutes: 15);

/// The gap above a block, from the flag the chat screens already carry.
double bubbleGapAbove({required bool startsNewGroup}) =>
    startsNewGroup ? kBubbleGapBetweenGroups : kBubbleGapInGroup;

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

/// Where one block of a message sits in the run, when the message draws more
/// than one block — an answer with a document under it, an image over a
/// caption. The blocks of one message always touch each other; only the first
/// and the last can carry an outer corner, and only when the message itself
/// opens or closes the run.
BubblePosition bubblePositionInStack({
  required int index,
  required int length,
  required bool startsNewGroup,
  required bool endsGroup,
}) => bubblePositionFromFlags(
  startsNewGroup: index == 0 && startsNewGroup,
  endsGroup: index == length - 1 && endsGroup,
);

/// The corner radii for a bubble at [pos]. [isMine] flips which side carries
/// the tail.
BorderRadius bubbleRadius(
  bool isMine,
  BubblePosition pos, {
  double big = kBubbleRadiusBig,
  double small = kBubbleRadiusSmall,
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
