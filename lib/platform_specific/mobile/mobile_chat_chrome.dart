/// The floating top bar of a phone chat, in the expressive design language.
///
/// Nothing sits in an app bar. Over the messages, on a soft fade, float
///
///  * a back target that springs and morphs on press;
///  * an outlined pill with the coworker's blob face, its name and its live
///    state — "working" with pulsing dots while a run is open, "Scheduled" when
///    a schedule is armed, "Waiting" otherwise. Tapping the pill opens the
///    coworker's profile;
///  * a PARKED voice-call target. The reference messenger has calls; CoWork has
///    no voice channel to an agent, so the button is there and disabled, and it
///    says why when it is tapped. It is never wired to a fake call;
///  * the coworker's browser, only while it really has one open;
///  * the "more" target with the shell's secondary actions.
///
/// The bar reads only `paddingOf`, so it never rebuilds on a keyboard frame. The
/// body under it reserves [MobileLayout.chromeInset]; [MobileChatScreen] does
/// that.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/platform_specific/mobile/mobile_chips.dart';
import 'package:cowork/platform_specific/mobile/mobile_layout.dart';
import 'package:cowork/services/cowork/agent_profile_store.dart';
import 'package:cowork/ui/expressive/agent_face.dart';
import 'package:cowork/ui/expressive/feedback.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/ui/expressive/working_dots.dart';

class MobileChatChrome extends StatelessWidget {
  const MobileChatChrome({
    super.key,
    required this.agent,
    required this.onBack,
    this.onOpenProfile,
    this.onOpenBrowser,
    this.onMore,
    this.showCallButton = true,
    this.profiles,
  });

  final CoworkAgent agent;

  /// Back to the coworker list.
  final VoidCallback onBack;

  /// Tap on the coworker pill — its profile page. Null renders the pill flat.
  final VoidCallback? onOpenProfile;

  /// The "computer" target: the coworker's browser. Null hides it.
  final VoidCallback? onOpenBrowser;

  /// The "more" target: the shell's secondary actions. Null hides it.
  final VoidCallback? onMore;

  /// Whether the parked voice-call target is shown at all.
  final bool showCallButton;

  final AgentProfileStore? profiles;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return MobileBarFade(
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: SizedBox(
            height: MobileLayout.chipDiameter,
            child: Row(
              children: <Widget>[
                ExpressiveIconButton(
                  icon: Icons.arrow_back_rounded,
                  onTap: onBack,
                  color: scheme.surface,
                  tooltip: 'Coworkers',
                  semanticsId: 'mobile_chat_back',
                ),
                const SizedBox(width: 8),
                // Expanded + left alignment: a long name ellipsises inside the
                // pill instead of pushing the targets off the right edge.
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _AgentPill(
                      agent: agent,
                      onTap: onOpenProfile,
                      profiles: profiles,
                    ),
                  ),
                ),
                if (showCallButton) ...<Widget>[
                  const SizedBox(width: 8),
                  // Parked: CoWork has no voice channel to a coworker. The
                  // target holds the place, it looks disabled, and it says why
                  // when it is pressed. It is never wired to a fake call.
                  ExpressiveIconButton(
                    icon: Icons.call_rounded,
                    parked: true,
                    color: scheme.surface,
                    tooltip: 'Voice call is not available yet',
                    semanticsId: 'mobile_chat_call',
                    onTap: () => pillToast(
                      context,
                      'Voice calls with a coworker are not available yet',
                      icon: Icons.call_end_rounded,
                    ),
                  ),
                ],
                if (onOpenBrowser != null) ...<Widget>[
                  const SizedBox(width: 8),
                  ExpressiveIconButton(
                    icon: Icons.desktop_windows_rounded,
                    onTap: onOpenBrowser,
                    color: scheme.tertiaryContainer,
                    onColor: scheme.onTertiaryContainer,
                    tooltip: "Agent's browser",
                    semanticsId: 'mobile_chat_browser',
                  ),
                ],
                if (onMore != null) ...<Widget>[
                  const SizedBox(width: 8),
                  ExpressiveIconButton(
                    icon: Icons.more_horiz_rounded,
                    onTap: onMore,
                    color: scheme.surface,
                    tooltip: 'More',
                    semanticsId: 'mobile_chat_more',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The coworker pill: face, name, live state. As tall as a chip, so the whole
/// row is one line of touch targets.
class _AgentPill extends StatelessWidget {
  const _AgentPill({required this.agent, required this.onTap, this.profiles});

  final CoworkAgent agent;
  final VoidCallback? onTap;
  final AgentProfileStore? profiles;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AgentProfileStore store = profiles ?? AgentProfileStore.instance;
    final String? role = _roleOf(store);
    return Semantics(
      identifier: 'mobile_chat_bot_pill',
      button: onTap != null,
      label: agent.name,
      child: Tooltip(
        message: role == null ? agent.name : '${agent.name} · $role',
        child: MorphTap(
          onTap: onTap,
          color: scheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              MobileLayout.chipDiameter / 2,
            ),
            side: BorderSide(color: scheme.outlineVariant, width: 1.2),
          ),
          pressedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: scheme.outlineVariant, width: 1.2),
          ),
          pressedScale: 0.97,
          padding: const EdgeInsets.fromLTRB(5, 5, 14, 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AgentFace(agent: agent, size: 36, store: store),
              const SizedBox(width: 9),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      agent.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 1),
                    _StateLine(agent: agent, scheme: scheme),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _roleOf(AgentProfileStore store) {
    final String? stored = store.profileOf(agent.id).role?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    final String? own = agent.role?.trim();
    return (own == null || own.isEmpty) ? null : own;
  }
}

/// The line under the name: the coworker's own activity, nothing invented.
class _StateLine extends StatelessWidget {
  const _StateLine({required this.agent, required this.scheme});

  final CoworkAgent agent;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    switch (agent.activity) {
      case AgentActivity.working:
        return WorkingDots(color: scheme.primary);
      case AgentActivity.scheduled:
        return Text(
          'Scheduled',
          style: TextStyle(
            color: scheme.tertiary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        );
      case AgentActivity.waiting:
        return Text(
          'Waiting',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        );
    }
  }
}
