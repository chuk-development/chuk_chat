/// The floating top bar of a phone chat, in the expressive design language.
///
/// Nothing sits in an app bar. Over the messages, on a soft fade, float
///
///  * a back target that springs and morphs on press;
///  * an outlined pill with the coworker's blob face, its name and its status
///    line — the green dot plus what it is working on right now, or "Active
///    now" when it is idle (see [AgentStatusLine]). Tapping the pill opens the
///    coworker's profile;
///  * the messenger's two call targets, with CoWork's own meaning. The voice
///    call is PARKED — there is no voice channel to an agent, so the button
///    holds its place, looks disabled and says why. The video call's slot is
///    the coworker's SCREEN: it opens the live VNC view of its sandbox
///    ([BrowserViewPage]), which is the thing worth watching here. It is
///    parked in the same way while the coworker has no screen open;
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
import 'package:cowork/ui/expressive/agent_status.dart';
import 'package:cowork/ui/expressive/feedback.dart';
import 'package:cowork/ui/expressive/motion.dart';

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
                const SizedBox(width: 8),
                // The video-call slot, with the thing this app actually has to
                // show: the coworker's screen. Parked while none is open.
                ExpressiveIconButton(
                  icon: Icons.desktop_windows_rounded,
                  parked: onOpenBrowser == null,
                  color: onOpenBrowser == null
                      ? scheme.surface
                      : scheme.tertiaryContainer,
                  onColor: onOpenBrowser == null
                      ? null
                      : scheme.onTertiaryContainer,
                  tooltip: onOpenBrowser == null
                      ? 'No screen open right now'
                      : "Agent's screen",
                  semanticsId: 'mobile_chat_browser',
                  onTap:
                      onOpenBrowser ??
                      () => pillToast(
                        context,
                        'The coworker has no screen open right now',
                        icon: Icons.desktop_access_disabled_rounded,
                      ),
                ),
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
          // 36 face + 2 x 6 = the 48 dp touch target the chips have.
          padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
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
                      // Tight line height: the name and the state line share
                      // the pill's 36 px of inner height.
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                    AgentStatusLine(agent: agent),
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
