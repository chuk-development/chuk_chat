/// A coworker's face with Grok Bot's presence dot.
///
/// Grok Bot puts a small green dot on the bottom-right of a bot's avatar when
/// the bot is online/working. CoWork already knows the activity of a coworker
/// (`AgentActivity`), so the dot reads straight from it: green while a run is
/// in flight, amber when a schedule is armed, no dot while it waits.
///
/// The face itself is the existing [AgentAvatar] (stable colour from the
/// agent id, one-letter monogram), so the same coworker looks the same in the
/// desktop sidebar, the phone list and the chat pill.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/widgets/agent_avatar.dart';

class MobilePresenceAvatar extends StatelessWidget {
  const MobilePresenceAvatar({
    super.key,
    required this.agent,
    this.radius = 22,
  });

  final CoworkAgent agent;

  /// Radius of the face. The dot scales with it.
  final double radius;

  /// The dot colour for an activity, or null for no dot.
  static Color? presenceColor(AgentActivity activity) {
    switch (activity) {
      case AgentActivity.working:
        return const Color(0xFF34C759);
      case AgentActivity.scheduled:
        return const Color(0xFFFF9F0A);
      case AgentActivity.waiting:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color? dot = presenceColor(agent.activity);
    final double dotSize = (radius * 0.55).clamp(10.0, 16.0);
    final Color ring = Theme.of(context).scaffoldBackgroundColor;
    return SizedBox.square(
      dimension: radius * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AgentAvatar(seed: agent.id, label: agent.name, radius: radius),
          if (dot != null)
            Positioned(
              right: -1,
              bottom: -1,
              child: Semantics(
                label: agent.activity == AgentActivity.working
                    ? 'working'
                    : 'scheduled',
                child: Container(
                  width: dotSize,
                  height: dotSize,
                  decoration: BoxDecoration(
                    color: dot,
                    shape: BoxShape.circle,
                    // A ring in the background colour separates the dot from
                    // the face, like the white ring in Grok Bot.
                    border: Border.all(color: ring, width: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
