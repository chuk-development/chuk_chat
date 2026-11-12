/// Agent faces: the colour rule ([agentAccent], also the colour of the
/// agent's bubbles), the old expressive silhouettes ([agentAvatarShape],
/// still used for room-face gaps and the template and shape pickers), and
/// [AgentFace] / [ExpressiveFace], which now draw the cube figure through
/// [AgentAvatar] (`lib/ui/agent_avatar/agent_avatar.dart`).
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/ui/agent_avatar/agent_avatar.dart';
import 'package:chuk_chat/ui/expressive/shapes.dart';

export 'package:chuk_chat/ui/agent_avatar/agent_avatar.dart'
    show AgentAvatarFocus;

/// The selected silhouette, shared by monograms, photos and editor previews.
ShapeBorder agentAvatarShape(String id, AgentAvatarShape? shape, double size) =>
    switch (shape) {
      AgentAvatarShape.round => const CircleBorder(),
      AgentAvatarShape.oval => const _OvalAvatarBorder(),
      AgentAvatarShape.roundedSquare => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(size * 0.24),
      ),
      AgentAvatarShape.square => const RoundedRectangleBorder(),
      AgentAvatarShape.cookie => expressiveShape(0),
      AgentAvatarShape.clover => expressiveShape(1),
      AgentAvatarShape.flower => expressiveShape(3),
      AgentAvatarShape.diamond => expressiveShape(4),
      AgentAvatarShape.gem => expressiveShape(5),
      AgentAvatarShape.triangle => expressiveShape(6),
      AgentAvatarShape.burst => expressiveShape(7),
      AgentAvatarShape.expressive || null => expressiveShapeFor(id),
    };

class _OvalAvatarBorder extends ShapeBorder {
  const _OvalAvatarBorder();
  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => Path()
    ..addOval(
      Rect.fromCenter(
        center: rect.center,
        width: rect.width * 0.78,
        height: rect.height,
      ),
    );
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}
  @override
  ShapeBorder scale(double t) => this;
}

/// The accent colour of an agent: the picked colour, else the stable hue from
/// the agent id.
Color agentAccent(
  BuildContext context,
  String agentId, {
  AgentProfileStore? store,
}) {
  return agentAccentFor(
    agentId,
    dark: Theme.of(context).brightness == Brightness.dark,
    store: store,
  );
}

/// [agentAccent] without a [BuildContext], for faces painted outside the
/// widget tree (the share sheet's Direct Share icons).
Color agentAccentFor(
  String agentId, {
  required bool dark,
  AgentProfileStore? store,
}) {
  final AgentProfile profile = (store ?? AgentProfileStore.instance).profileOf(
    agentId,
  );
  final int? picked = profile.colorValue;
  if (picked != null) return Color(picked);
  // The hue is taken from the offered palette instead of straight from the
  // hash. A raw hash spreads over the full circle, which sounds fair and in
  // practice put two of three agents within a few degrees of each other —
  // both read as "the teal one". The palette's hues are already spaced apart,
  // so picking one of those keeps the colours tellable. Saturation and
  // lightness stay fixed: the hue does the identifying, and every face keeps
  // the same weight and the same contrast against a white monogram.
  final double hue = HSLColor.fromColor(
    kAgentAccents[_paletteIndex(agentId)],
  ).hue;
  return HSLColor.fromAHSL(1, hue, 0.45, dark ? 0.42 : 0.62).toColor();
}

/// A stable index into [kAgentAccents] from the agent id. Its own hash, so an
/// agent's colour and its silhouette are not picked by the same number and
/// two agents that share one do not automatically share the other.
int _paletteIndex(String agentId) {
  int hash = 0x811c9dc5;
  for (final int unit in agentId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash % kAgentAccents.length;
}

/// The palette the profile editor offers for an agent's colour.
const List<Color> kAgentAccents = <Color>[
  Color(0xFF2962FF),
  Color(0xFF7C4DFF),
  Color(0xFFAA00FF),
  Color(0xFFFF4081),
  Color(0xFFFF1744),
  Color(0xFFFF6E40),
  Color(0xFFFF9100),
  Color(0xFFFFC400),
  Color(0xFF00C853),
  Color(0xFF00BFA5),
  Color(0xFF00B8D4),
  Color(0xFF40C4FF),
  Color(0xFF607D8B),
];

/// A face for an identity the caller only knows as an id and a label — a room
/// member, a room turn, a picker row. The same figure and colour as
/// [AgentFace]; there is no activity to show.
class ExpressiveFace extends StatelessWidget {
  const ExpressiveFace({
    super.key,
    required this.id,
    required this.label,
    this.size = 32,
    this.store,
    this.dimmed = false,
  });

  final String id;
  final String label;
  final double size;
  final AgentProfileStore? store;
  final bool dimmed;

  @override
  Widget build(BuildContext context) => AgentAvatar.id(
    id: id,
    label: label,
    size: size,
    store: store,
    dimmed: dimmed,
  );
}

/// An agent's face with its live state. Kept as the name the existing call
/// sites use; it is [AgentAvatar].
class AgentFace extends StatelessWidget {
  const AgentFace({
    super.key,
    required this.agent,
    this.size = 56,
    this.showPresence = true,
    this.store,
    this.dimmed = false,
    this.profileOverride,
  });

  final AgentsAgent agent;
  final double size;
  final bool showPresence;

  /// Injectable for tests; defaults to the app-wide store.
  final AgentProfileStore? store;

  /// A hidden agent is shown faded in the "show hidden" list.
  final bool dimmed;

  /// An unsaved editor preview; normal app surfaces always read the store.
  final AgentProfile? profileOverride;

  /// The presence dot colour for an activity, or null for no dot.
  static Color? presenceColor(AgentActivity activity) =>
      AgentAvatar.presenceColor(activity);

  @override
  Widget build(BuildContext context) => AgentAvatar(
    agent: agent,
    size: size,
    showPresence: showPresence,
    store: store,
    dimmed: dimmed,
    profileOverride: profileOverride,
  );
}
