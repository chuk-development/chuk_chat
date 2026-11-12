// lib/widgets/agent_thread_accent.dart
//
// The agent whose thread is on screen, for the bubbles under it: in an
// Agents thread the user's bubble takes that agent's colour, like a
// messenger gives every contact its own (docs/DESIGN.md §9, CHAT-52).

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/agent_face.dart';

/// Names the agent of the thread below it. The chat screen itself is shared
/// with chuk_chat and knows no agent, so the Agents thread view puts this
/// above it.
class AgentThreadAccent extends InheritedWidget {
  const AgentThreadAccent({
    super.key,
    required this.agentId,
    required super.child,
  });

  /// The agent's id; null when the thread belongs to no known agent.
  final String? agentId;

  /// The agent's colour for the thread around [context], or null outside
  /// an Agents thread.
  static Color? colorOf(BuildContext context) {
    final String? id = context
        .dependOnInheritedWidgetOfExactType<AgentThreadAccent>()
        ?.agentId;
    if (id == null || id.isEmpty) return null;
    return agentAccent(context, id);
  }

  @override
  bool updateShouldNotify(AgentThreadAccent oldWidget) =>
      oldWidget.agentId != agentId;
}
