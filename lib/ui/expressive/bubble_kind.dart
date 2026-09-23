/// The colour of a coworker's bubble, by what the message IS.
///
/// A coworker does not only talk: it works (tool runs), it hands over files
/// (artifacts, images), and sometimes it breaks off. In the reference messenger
/// every message kind — text, voice, media, poll — reads differently at a
/// glance, and this is the same idea with the kinds Agents actually has:
///
///  * [AgentBubbleKind.answer] — plain text: the neutral surface bubble;
///  * [AgentBubbleKind.work] — the turn is mostly tool runs: the secondary tint,
///    so a long working turn does not look like prose;
///  * [AgentBubbleKind.delivery] — it produced images or files: the tertiary
///    tint;
///  * [AgentBubbleKind.problem] — the stream broke off or the send failed: the
///    error tint.
///
/// The kind is derived from what the bubble already carries. Nothing new has to
/// be persisted, and nothing is guessed.
library;

import 'package:flutter/material.dart';

enum AgentBubbleKind { answer, work, delivery, problem }

/// The fill and the foreground for a coworker's bubble.
@immutable
class AgentBubbleColors {
  const AgentBubbleColors(this.fill, this.onFill);

  final Color fill;
  final Color onFill;
}

AgentBubbleColors agentBubbleColors(ColorScheme scheme, AgentBubbleKind kind) {
  switch (kind) {
    case AgentBubbleKind.answer:
      return AgentBubbleColors(scheme.surfaceContainerHigh, scheme.onSurface);
    case AgentBubbleKind.work:
      return AgentBubbleColors(
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      );
    case AgentBubbleKind.delivery:
      return AgentBubbleColors(
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      );
    case AgentBubbleKind.problem:
      return AgentBubbleColors(scheme.errorContainer, scheme.onErrorContainer);
  }
}

/// Picks the kind from the facts a bubble has.
///
/// [textLength] is the length of the visible answer text; a turn with tool runs
/// and a real answer under them is still an answer, because that is what the
/// reader reads.
AgentBubbleKind agentBubbleKindFor({
  required bool hasProblem,
  required bool hasMedia,
  required bool hasToolRuns,
  required int textLength,
}) {
  if (hasProblem) return AgentBubbleKind.problem;
  if (hasMedia) return AgentBubbleKind.delivery;
  if (hasToolRuns && textLength < 200) return AgentBubbleKind.work;
  return AgentBubbleKind.answer;
}
