/// A coworker's face, in the expressive shape language.
///
/// The face is a scalloped blob ([expressiveShapeFor]) cut from the agent id, so
/// one coworker keeps one silhouette everywhere: the inbox row, the chat header,
/// the profile page and the desktop roster. Inside the blob is
///
///  * the picture the user set for this coworker ([AgentProfileStore]), or
///  * the monogram on a colour, which is the accent the user picked, or the
///    stable hue derived from the agent id — the same rule [AgentAvatar] used
///    before, so a coworker without a profile does not change colour.
///
/// A presence dot rides at the bottom right: green while a run is in flight,
/// amber when a schedule is armed, nothing while the coworker waits. That is
/// read from [CoworkAgent.activity], which the app actually observes.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_profile_store.dart';
import 'package:cowork/ui/expressive/face_image.dart';
import 'package:cowork/ui/expressive/shapes.dart';
import 'package:cowork/widgets/agent_avatar.dart';

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

/// The accent colour of a coworker: the picked colour, else the stable hue from
/// the agent id.
Color agentAccent(
  BuildContext context,
  String agentId, {
  AgentProfileStore? store,
}) {
  final AgentProfile profile = (store ?? AgentProfileStore.instance).profileOf(
    agentId,
  );
  final int? picked = profile.colorValue;
  if (picked != null) return Color(picked);
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  // The hue is taken from the offered palette instead of straight from the
  // hash. A raw hash spreads over the full circle, which sounds fair and in
  // practice put two of three coworkers within a few degrees of each other —
  // both read as "the teal one". The palette's hues are already spaced apart,
  // so picking one of those keeps the colours tellable. Saturation and
  // lightness stay fixed: the hue does the identifying, and every face keeps
  // the same weight and the same contrast against a white monogram.
  final double hue = HSLColor.fromColor(
    kAgentAccents[_paletteIndex(agentId)],
  ).hue;
  return HSLColor.fromAHSL(1, hue, 0.45, dark ? 0.42 : 0.62).toColor();
}

/// A stable index into [kAgentAccents] from the agent id. Its own hash, so a
/// coworker's colour and its silhouette are not picked by the same number and
/// two coworkers that share one do not automatically share the other.
int _paletteIndex(String agentId) {
  int hash = 0x811c9dc5;
  for (final int unit in agentId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash % kAgentAccents.length;
}

/// The palette the profile editor offers for a coworker's colour.
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
/// member, a room turn, a picker row. Same blob, same colour rule, same stored
/// picture as [AgentFace]; there is simply no activity to show a dot for.
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
  Widget build(BuildContext context) {
    final AgentProfileStore profiles = store ?? AgentProfileStore.instance;
    return AnimatedBuilder(
      animation: profiles,
      builder: (BuildContext context, Widget? _) {
        final ShapeBorder shape = agentAvatarShape(
          id,
          profiles.profileOf(id).shape,
          size,
        );
        final Color color = agentAccent(context, id, store: profiles);
        final ImageProvider<Object>? photo = faceImageProvider(
          profiles.profileOf(id).photoPath,
        );
        return Opacity(
          opacity: dimmed ? 0.4 : 1.0,
          child: Container(
            width: size,
            height: size,
            decoration: ShapeDecoration(
              color: photo == null ? color : null,
              shape: shape,
              image: photo == null
                  ? null
                  : DecorationImage(image: photo, fit: BoxFit.cover),
            ),
            child: photo != null
                ? null
                : Center(
                    child: Transform.translate(
                      offset: Offset(0, size * monogramDrop(shape)),
                      child: Text(
                        AgentAvatar.monogramOf(label),
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: size * 0.38,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

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

  final CoworkAgent agent;
  final double size;
  final bool showPresence;

  /// Injectable for tests; defaults to the app-wide store.
  final AgentProfileStore? store;

  /// A hidden coworker is shown faded in the "show hidden" list.
  final bool dimmed;

  /// An unsaved editor preview; normal app surfaces always read the store.
  final AgentProfile? profileOverride;

  /// The presence dot colour for an activity, or null for no dot.
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
    final AgentProfileStore profiles = store ?? AgentProfileStore.instance;
    return AnimatedBuilder(
      animation: profiles,
      builder: (BuildContext context, Widget? _) => _build(context, profiles),
    );
  }

  Widget _build(BuildContext context, AgentProfileStore profiles) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final profile = profileOverride ?? profiles.profileOf(agent.id);
    final ShapeBorder shape = agentAvatarShape(agent.id, profile.shape, size);
    final Color color = profileOverride == null
        ? agentAccent(context, agent.id, store: profiles)
        : profile.colorValue != null
        ? Color(profile.colorValue!)
        : HSLColor.fromAHSL(
            1,
            AgentAvatar.hueOf(agent.id),
            0.45,
            Theme.of(context).brightness == Brightness.dark ? 0.42 : 0.62,
          ).toColor();
    final ImageProvider<Object>? photo = faceImageProvider(profile.photoPath);
    final bool hasPhoto = photo != null;
    final Color? dot = showPresence ? presenceColor(agent.activity) : null;
    final double opacity = dimmed ? 0.4 : 1.0;

    return SizedBox(
      width: size,
      height: size,
      child: Opacity(
        opacity: opacity,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: size,
              height: size,
              // The picture is painted into the blob itself, so the colour
              // cannot bleed out as a rim at the scalloped edges.
              decoration: ShapeDecoration(
                color: hasPhoto ? null : color,
                shape: shape,
                image: photo == null
                    ? null
                    : DecorationImage(image: photo, fit: BoxFit.cover),
              ),
              child: hasPhoto
                  ? null
                  : Center(
                      child: Transform.translate(
                        offset: Offset(0, size * monogramDrop(shape)),
                        child: Text(
                          AgentAvatar.monogramOf(agent.name),
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: size * 0.38,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                    ),
            ),
            if (dot != null)
              Positioned(
                right: -2,
                bottom: -2,
                child: Semantics(
                  label: agent.activity == AgentActivity.working
                      ? 'working'
                      : 'scheduled',
                  child: Container(
                    width: (size * 0.30).clamp(9.0, 18.0),
                    height: (size * 0.30).clamp(9.0, 18.0),
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.surface, width: 2.5),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
