/// The floating top bar of a phone chat, in the expressive design language.
///
/// Nothing sits in an app bar. Over the messages, on a soft fade, float
///
///  * a back target that springs and morphs on press;
///  * an outlined pill with the coworker's blob face, its name and its status
///    line — a quiet role label when idle, three dots while working.
///    Tapping the pill opens the
///    coworker's settings;
///  * a stable screen target. It is lit when the coworker has a screen to take
///    over, parked when it has none — and a parked tap says why, so the target
///    is never a dead button.
///
/// The bar reads only `paddingOf`, so it never rebuilds on a keyboard frame. The
/// body under it reserves [MobileLayout.chromeInset]; [MobileChatScreen] does
/// that.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/ui/expressive/agent_status.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/ui/expressive/top_veil.dart';
import 'package:chuk_chat/ui/expressive/working_dots.dart';

class MobileChatChrome extends StatelessWidget {
  const MobileChatChrome({
    super.key,
    required this.agent,
    required this.onBack,
    this.onOpenProfile,
    this.onOpenBrowser,
    this.browserAvailable = false,
    this.onOpenFiles,
    this.onReconnect,
    this.onMore,
    this.profiles,
  });

  final AgentsAgent agent;

  /// Back to the coworker list.
  final VoidCallback onBack;

  /// Tap on the coworker pill — its profile page. Null renders the pill flat.
  final VoidCallback? onOpenProfile;

  /// The "computer" target: the coworker's screen. Called whether or not a
  /// screen is open — when none is, it is expected to say so, which is why the
  /// target is never silently dead (bead cowork-egrg).
  final VoidCallback? onOpenBrowser;

  /// Is a screen open right now? False draws the target parked: visibly not
  /// ready, still answering a tap with the reason.
  final bool browserAvailable;
  final VoidCallback? onOpenFiles;
  final VoidCallback? onReconnect;

  /// The "more" target: the shell's secondary actions. Null hides it.
  final VoidCallback? onMore;

  final AgentProfileStore? profiles;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return TickerMode(
      enabled: !MediaQuery.disableAnimationsOf(context),
      // The shared veil: heaviest behind the status bar, gone below the row.
      child: TopVeil(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MobileLayout.headerContentHeight(context),
            ),
            child: Row(
              children: <Widget>[
                ExpressiveIconButton(
                  icon: Icons.arrow_back_rounded,
                  onTap: onBack,
                  size: MobileLayout.controlHeight,
                  color: scheme.surfaceContainerHighest,
                  tooltip: 'Agents',
                  semanticsId: 'mobile_chat_back',
                ),
                const SizedBox(width: 10),
                // Expanded + left alignment: a long name ellipsises inside the
                // pill instead of pushing the targets off the right edge.
                Expanded(
                  child: _AgentPill(
                    agent: agent,
                    onTap: onOpenProfile,
                    onReconnect: onReconnect,
                    profiles: profiles,
                  ),
                ),
                if (onOpenFiles != null) ...<Widget>[
                  const SizedBox(width: 8),
                  ExpressiveIconButton(
                    icon: Icons.folder_open_rounded,
                    size: MobileLayout.controlHeight,
                    color: scheme.surfaceContainerHighest,
                    onColor: scheme.onSurface,
                    tooltip: 'Shared files',
                    semanticsId: 'mobile_chat_files',
                    onTap: onOpenFiles,
                  ),
                ],
                const SizedBox(width: 8),
                ExpressiveIconButton(
                  icon: Icons.desktop_windows_rounded,
                  size: MobileLayout.controlHeight,
                  color: browserAvailable
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest,
                  onColor: browserAvailable
                      ? scheme.onPrimaryContainer
                      : scheme.onSurface,
                  tooltip: browserAvailable
                      ? 'Take over the screen'
                      : 'No screen open yet',
                  semanticsId: 'mobile_chat_browser',
                  parked: !browserAvailable,
                  onTap: onOpenBrowser,
                ),
                if (onMore != null) ...<Widget>[
                  const SizedBox(width: 8),
                  ExpressiveIconButton(
                    icon: Icons.more_horiz_rounded,
                    onTap: onMore,
                    size: MobileLayout.controlHeight,
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

/// The coworker's face inside the header pill.
///
/// The pill's height is set by its two lines of text — the name at 16 × 1.5 and
/// the status at 11 × 1.45, so 40 px of inner height. 32 is the app's small
/// face (the default of `ExpressiveFace`, and the nearest step below the 34 of
/// the desktop roster): it leaves 4 px of air above and below inside that
/// column, so the silhouette sits IN the capsule instead of filling it. At 38
/// the face had a single pixel of air and read as an oversized square.
const double _kPillFaceSize = 32;

/// The status line's font size. The presence dot is derived from it.
const double _kPillStatusFontSize = 11;

/// The coworker pill: face, name, live state. As tall as a chip, so the whole
/// row is one line of touch targets.
class _AgentPill extends StatelessWidget {
  const _AgentPill({
    required this.agent,
    required this.onTap,
    this.profiles,
    this.onReconnect,
  });

  final AgentsAgent agent;
  final VoidCallback? onTap;
  final VoidCallback? onReconnect;
  final AgentProfileStore? profiles;

  @override
  Widget build(BuildContext context) {
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
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
            side: BorderSide(color: scheme.outlineVariant, width: 1.2),
          ),
          pressedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: scheme.outlineVariant, width: 1.2),
          ),
          pressedScale: 0.97,
          // A ShapeBorder on MorphTap clips but does not paint an outline.
          // Paint the reference's translucent surface AND border explicitly.
          child: Container(
            key: const ValueKey('mobile_contact_surface'),
            // The pill takes the row's height rather than growing one out of
            // its own padding: it stood 6 taller than the buttons beside it,
            // and a capsule that overhangs its neighbours is the first thing
            // the eye picks out of a header. Its two lines are centred in
            // whatever height the row has. 9 on the left: the capsule's end is
            // a half circle, so a face set at 6 read as pressed against the
            // curve.
            height: MobileLayout.headerContentHeight(context),
            padding: const EdgeInsets.fromLTRB(9, 0, 14, 0),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: scheme.outlineVariant, width: 1.2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.max,
              children: <Widget>[
                // The face is sized to the pill, not the other way round: the
                // two text lines are 40 px of inner height, so a 32 px face
                // (the app's small-face size, as in ExpressiveFace) keeps even
                // air above and below and never drives the pill's height. The
                // presence dot is NOT parked on its corner any more — it
                // belongs to the status line, and sits on that line.
                AgentFace(
                  agent: agent,
                  size: _kPillFaceSize,
                  store: store,
                  showPresence: false,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        agent.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // Tight line height: the name and the state line share
                        // the pill's 36 px of inner height.
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          height: 1.5,
                        ),
                      ),
                      if (!paired && onReconnect != null)
                        GestureDetector(
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
                                    height: 1.45,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                      else if (agent.running && paired)
                        Semantics(
                          label: 'Working',
                          child: SizedBox(
                            height:
                                MediaQuery.textScalerOf(
                                  context,
                                ).scale(_kPillStatusFontSize) *
                                1.45,
                            child: ExcludeSemantics(
                              child: _statusLine(
                                context,
                                paired: paired,
                                child: MediaQuery.disableAnimationsOf(context)
                                    ? Text(
                                        '…',
                                        style: TextStyle(
                                          color: scheme.primary,
                                          fontSize: _kPillStatusFontSize,
                                          height: 1.45,
                                        ),
                                      )
                                    : WorkingDots(
                                        color: scheme.primary,
                                        label: '',
                                      ),
                              ),
                            ),
                          ),
                        )
                      else
                        _statusLine(
                          context,
                          paired: paired,
                          child: Flexible(
                            child: Text(
                              paired ? 'Active now' : 'Offline',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: paired
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                                fontSize: _kPillStatusFontSize,
                                height: 1.45,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The bottom line of the pill: the presence dot and whatever says what the
  /// coworker is doing. The dot is the shared [StatusDot], so it is as tall as
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
    final String? stored = store.profileOf(agent.id).role?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    final String? own = agent.role?.trim();
    return (own == null || own.isEmpty) ? null : own;
  }
}
