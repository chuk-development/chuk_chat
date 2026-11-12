/// The chips and the agent pill of chuk_chat's floating top bar, with an
/// agent in it: [ChromeChip] (chuk's 42 px round chip with a 48 px press) and
/// [AgentChromePill] (chuk's title pill carrying the agent's face, its name
/// and its status line — "Active now" (also while it works) or
/// "Offline · Reconnect").
///
/// The desktop thread header (`agents_thread_header.dart`) draws them. The
/// phone's old floating chat bar that also used them is gone: the phone has
/// one top bar for both halves now (`mobile_top_bar.dart`).
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/ui/agent_avatar/agent_avatar.dart';
import 'package:chuk_chat/ui/expressive/agent_status.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';

/// Diameter of a round chip: chuk's floating chip.
const double kMobileChromeChip = 42;

/// Height of the bar's row: chuk's top bar row.
const double kMobileChromeRow = 48;

/// Corner radius of the title pill: chuk's title pill.
const double kMobileChromePillRadius = 18;

/// The agent's face inside the pill. 30 leaves the two text lines their
/// room and keeps air above and below the face inside the 42 px pill.
const double _kPillFaceSize = 30;

/// The status line's font size. The presence dot is derived from it.
const double _kPillStatusFontSize = 11;

/// One round chip of the bar: chuk's floating chip — the chrome surface, a
/// 22 px glyph in the icon colour — or, with [accent], chuk's accent-filled
/// one. The chip paints 42 px and takes a 48 px press; the ink stays on the
/// chip.
///
/// Public because the desktop thread header (`agents_thread_header.dart`)
/// draws the same chips, so the two layouts share one look.
class ChromeChip extends StatelessWidget {
  const ChromeChip({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.semanticsId,
    required this.onTap,
    this.accent = false,
    this.parked = false,
  });

  final IconData icon;
  final String tooltip;
  final String semanticsId;

  /// Null disables the chip.
  final VoidCallback? onTap;

  /// chuk's accent-filled chip: the one thing on the bar that is ready.
  final bool accent;

  /// Not ready yet: a quieter glyph, and a tap still reaches [onTap], which
  /// is expected to say why.
  final bool parked;

  @override
  Widget build(BuildContext context) => FloatingHeaderButton(
    icon: icon,
    tooltip: tooltip,
    semanticsId: semanticsId,
    onPressed: onTap,
    accent: accent,
    parked: parked,
  );
}

/// The agent pill: chuk's title pill with the face, the name and the live
/// state in it. It paints at the chips' height and takes a 48 px press.
///
/// Public because the desktop thread header draws the same pill.
class AgentChromePill extends StatelessWidget {
  const AgentChromePill({
    super.key,
    required this.agent,
    required this.onTap,
    this.profiles,
    this.onReconnect,
    this.paired,
    this.semanticsId = 'mobile_chat_bot_pill',
  });

  final AgentsAgent agent;
  final VoidCallback? onTap;
  final VoidCallback? onReconnect;
  final AgentProfileStore? profiles;

  /// The link state when the caller already knows it (the desktop thread
  /// owns its transport). Null reads the shared [AgentsRelayLink].
  final bool? paired;

  final String semanticsId;

  @override
  Widget build(BuildContext context) {
    final bool? known = paired;
    if (known != null) return _surface(context, paired: known);
    return ValueListenableBuilder<AgentsRelayController?>(
      valueListenable: AgentsRelayLink.instance.controller,
      builder: (context, controller, _) => controller == null
          ? _surface(context, paired: false)
          : ValueListenableBuilder<AgentsRelayState>(
              valueListenable: controller.state,
              builder: (context, state, _) =>
                  _surface(context, paired: state.isPaired),
            ),
    );
  }

  Widget _surface(BuildContext context, {required bool paired}) {
    final ThemeData theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;
    final AgentProfileStore store = profiles ?? AgentProfileStore.instance;
    final String? role = _roleOf(store);
    final Widget pill = FloatingChromeSurface(
      key: const ValueKey('mobile_contact_surface'),
      radius: kMobileChromePillRadius,
      padding: const EdgeInsets.fromLTRB(6, 5, 16, 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AgentAvatar(
            agent: agent,
            size: _kPillFaceSize,
            store: store,
            showPresence: false,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // chuk's title: 15, heavy, the icon colour.
                Text(
                  agent.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: iconFg.withValues(alpha: 0.92),
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
                ),
                _status(context, paired: paired),
              ],
            ),
          ),
        ],
      ),
    );
    return Semantics(
      identifier: semanticsId,
      button: onTap != null,
      label: agent.name,
      child: Tooltip(
        message: role == null ? agent.name : '${agent.name} · $role',
        child: MorphTap(
          onTap: onTap,
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kMobileChromePillRadius),
          ),
          pressedScale: 0.97,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: MobileLayout.minTouchTarget,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              widthFactor: 1,
              heightFactor: 1,
              child: pill,
            ),
          ),
        ),
      ),
    );
  }

  /// What the agent is doing: offline with a way back, working, or here.
  Widget _status(BuildContext context, {required bool paired}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (!paired && onReconnect != null) {
      return GestureDetector(
        onTap: onReconnect,
        behavior: HitTestBehavior.opaque,
        child: Semantics(
          button: true,
          label: 'Offline. Reconnect',
          child: _statusLine(
            context,
            paired: paired,
            child: Flexible(
              child: Text(
                'Offline · Reconnect',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.primary,
                  fontSize: _kPillStatusFontSize,
                  height: 1.3,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      );
    }
    // A run in flight shows no dots here: the face's work animation says
    // it, and the line keeps the normal status (CHAT-74).
    return _statusLine(
      context,
      paired: paired,
      child: Flexible(
        child: Text(
          paired ? 'Active now' : 'Offline',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: paired ? scheme.primary : scheme.onSurfaceVariant,
            fontSize: _kPillStatusFontSize,
            height: 1.3,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  /// The bottom line of the pill: the presence dot and whatever says what the
  /// agent is doing. The dot is the shared [StatusDot], so it is as tall as
  /// the x-height of the words and its bottom rides the alphabetic baseline —
  /// one optical line, at every text scale.
  Widget _statusLine(
    BuildContext context, {
    required bool paired,
    required Widget child,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        StatusDot(
          color: paired
              ? const Color(0xFF34C759)
              : scheme.onSurfaceVariant.withValues(alpha: 0.5),
          fontSize: _kPillStatusFontSize,
        ),
        const SizedBox(width: kStatusDotGap),
        child,
      ],
    );
  }

  String? _roleOf(AgentProfileStore store) {
    return store.profileOf(agent.id).roleOver(agent.role);
  }
}
