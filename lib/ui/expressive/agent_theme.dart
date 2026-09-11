/// One coworker, one colour — through the whole conversation, not only on the
/// face.
///
/// A roster of coworkers that all talk in the same green is a roster you read
/// by name alone. Each agent already owns a stable accent ([agentAccent]: the
/// colour the user picked, else the hue derived from the agent id), so the
/// thread simply adopts it: the bubbles, the send button, the header pill and
/// every accent inside the chat take the colour of the coworker who is talking.
///
/// Only the accent roles are replaced. Surfaces, text and the scaffold stay
/// exactly as the app theme set them — a per-agent background would fight the
/// dark theme and cost legibility for no gain, and the point is recognition,
/// not decoration.
library;

import 'package:flutter/material.dart';

import 'package:cowork/services/cowork/agent_profile_store.dart';
import 'package:cowork/ui/expressive/agent_face.dart';

/// The app theme with the accent roles re-seeded from [agentId]'s colour.
ThemeData agentTintedTheme(
  BuildContext context,
  String agentId, {
  AgentProfileStore? store,
}) {
  final ThemeData base = Theme.of(context);
  final Color accent = agentAccent(context, agentId, store: store);
  final ColorScheme seeded = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: base.brightness,
  );
  return base.copyWith(
    colorScheme: base.colorScheme.copyWith(
      primary: seeded.primary,
      onPrimary: seeded.onPrimary,
      primaryContainer: seeded.primaryContainer,
      onPrimaryContainer: seeded.onPrimaryContainer,
      secondary: seeded.secondary,
      onSecondary: seeded.onSecondary,
      secondaryContainer: seeded.secondaryContainer,
      onSecondaryContainer: seeded.onSecondaryContainer,
      tertiary: seeded.tertiary,
      onTertiary: seeded.onTertiary,
      inversePrimary: seeded.inversePrimary,
    ),
  );
}

/// [child] under the colour of [agentId], rebuilt when the user edits that
/// coworker's colour in the profile editor.
class AgentTheme extends StatelessWidget {
  const AgentTheme({
    super.key,
    required this.agentId,
    required this.child,
    this.store,
  });

  final String agentId;
  final Widget child;
  final AgentProfileStore? store;

  @override
  Widget build(BuildContext context) {
    final AgentProfileStore profiles = store ?? AgentProfileStore.instance;
    return AnimatedBuilder(
      animation: profiles,
      builder: (BuildContext context, Widget? built) => Theme(
        data: agentTintedTheme(context, agentId, store: profiles),
        child: built!,
      ),
      child: child,
    );
  }
}
