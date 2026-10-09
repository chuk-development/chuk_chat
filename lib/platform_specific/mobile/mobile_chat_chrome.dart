/// The floating top bar of a phone chat: chuk_chat's phone top bar
/// (`root_wrapper_mobile.dart`, `_buildFloatingTopBar`) with a coworker in it.
///
/// No app bar. Over the messages, on a fade from the page colour, float
///
///  * a round back chip where chuk has its menu chip;
///  * chuk's title pill, carrying the coworker's face, its name and its
///    status line — "Active now", three dots while it works, or "Offline ·
///    Reconnect". Tapping the pill opens the coworker's profile;
///  * round chips for the shared files and the coworker's screen. The screen
///    chip is lit (chuk's accent fill) when there is a screen to take over,
///    parked when there is none — and a parked tap says why, so the chip is
///    never a dead button;
///  * an optional "more" chip.
///
/// The chips are drawn at chuk's 42 px, and each one takes a 48 px press, so
/// nothing is hard to hit. The bar reads only `paddingOf`, so it never
/// rebuilds on a keyboard frame. The body under it reserves
/// [MobileLayout.chromeInset]; [MobileChatScreen] does that.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart'; // own browser
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/platform_specific/chat/voice/chat_voice_binding.dart';
import 'package:chuk_chat/platform_specific/chat/voice/chat_voice_call_button.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/ui/expressive/agent_status.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/ui/expressive/working_dots.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Diameter of a round chip: chuk's floating chip.
const double kMobileChromeChip = 42;

/// Height of the bar's row: chuk's top bar row.
const double kMobileChromeRow = 48;

/// Corner radius of the title pill: chuk's title pill.
const double kMobileChromePillRadius = 18;

/// How far a 48 px press reaches past a 42 px chip on each side. The row's
/// padding and gaps take it back, so the chips land where chuk's land.
const double _kReach = (MobileLayout.minTouchTarget - kMobileChromeChip) / 2;

/// The coworker's face inside the pill. 30 leaves the two text lines their
/// room and keeps air above and below the face inside the 42 px pill.
const double _kPillFaceSize = 30;

/// The status line's font size. The presence dot is derived from it.
const double _kPillStatusFontSize = 11;

class MobileChatChrome extends StatelessWidget {
  const MobileChatChrome({
    super.key,
    required this.agent,
    required this.onBack,
    this.onOpenProfile,
    this.onOpenBrowser,
    this.browserAvailable = false,
    this.usesUserBrowser = false, // own browser
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

  // ── own browser ──
  /// The coworker works in the user's own browser (`run_state.browser_target`).
  /// With no screen open, the parked screen target says "Works in your
  /// browser", like the desktop header, not "No screen open yet".
  final bool usesUserBrowser;
  // ── end own browser ──

  /// The "computer" chip: the coworker's screen. Called whether or not a
  /// screen is open — when none is, it is expected to say so, which is why the
  /// chip is never silently dead (bead cowork-egrg).
  final VoidCallback? onOpenBrowser;

  /// Is a screen open right now? False draws the chip parked: visibly not
  /// ready, still answering a tap with the reason.
  final bool browserAvailable;
  final VoidCallback? onOpenFiles;
  final VoidCallback? onReconnect;

  /// The "more" chip: the shell's secondary actions. Null hides it.
  final VoidCallback? onMore;

  final AgentProfileStore? profiles;

  @override
  Widget build(BuildContext context) {
    final Color pageColor = Theme.of(context).scaffoldBackgroundColor;
    return TickerMode(
      enabled: !MediaQuery.disableAnimationsOf(context),
      child: DecoratedBox(
        // The chat runs on underneath this bar, so the bar holds the page
        // down behind it: page colour at the status bar, nothing at all by
        // its lower edge. chuk's phone top bar, stop for stop.
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              pageColor,
              pageColor,
              pageColor.withValues(alpha: 0),
            ],
            stops: const <double>[0.0, 0.62, 1.0],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            // chuk's 10 / 8 / 10 / 6, less the reach of the 48 px presses.
            padding: const EdgeInsets.fromLTRB(
              10 - _kReach,
              8,
              10 - _kReach,
              6,
            ),
            child: ConstrainedBox(
              // chuk's 48 px row. Larger text grows the pill, and the row
              // with it, instead of clipping the name.
              constraints: const BoxConstraints(minHeight: kMobileChromeRow),
              child: Row(
                children: <Widget>[
                  ChromeChip(
                    icon: Icons.arrow_back_rounded,
                    onTap: onBack,
                    tooltip: 'Agents',
                    semanticsId: 'mobile_chat_back',
                  ),
                  const SizedBox(width: 8 - _kReach),
                  // Expanded + left alignment, as chuk's title: a long name
                  // ellipsises inside the pill instead of pushing the chips
                  // off the right edge.
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      heightFactor: 1,
                      child: AgentChromePill(
                        agent: agent,
                        onTap: onOpenProfile,
                        onReconnect: onReconnect,
                        profiles: profiles,
                      ),
                    ),
                  ),
                  if (onOpenFiles != null) ...<Widget>[
                    const SizedBox(width: 8 - _kReach),
                    ChromeChip(
                      icon: Icons.folder_open_rounded,
                      tooltip: 'Shared files',
                      semanticsId: 'mobile_chat_files',
                      onTap: onOpenFiles,
                    ),
                  ],
                  SizedBox(
                    width: onOpenFiles != null ? 8 - 2 * _kReach : 8 - _kReach,
                  ),
                  // The messenger's voice call, beside the video call's slot
                  // (the screen). Only in a build that offers calls.
                  if (voiceCallUiEnabled) ...<Widget>[
                    ChatVoiceCallButton.agentsThread(
                      style: ChatVoiceCallStyle.chip,
                      agentName: agent.name,
                      semanticsId: 'mobile_chat_call',
                    ),
                    const SizedBox(width: 8 - 2 * _kReach),
                  ],
                  ChromeChip(
                    icon: Icons.desktop_windows_rounded,
                    accent: browserAvailable,
                    parked: !browserAvailable,
                    tooltip: browserAvailable
                        ? 'Take over the screen'
                        : usesUserBrowser // own browser
                        ? (AppLocalizations.of(context)?.ubScreenTooltip ??
                              'Works in your browser')
                        : 'No screen open yet',
                    semanticsId: 'mobile_chat_browser',
                    onTap: onOpenBrowser,
                  ),
                  if (onMore != null) ...<Widget>[
                    const SizedBox(width: 8 - 2 * _kReach),
                    ChromeChip(
                      icon: Icons.more_horiz_rounded,
                      onTap: onMore,
                      tooltip: 'More',
                      semanticsId: 'mobile_chat_more',
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color fill = accent
        ? theme.colorScheme.primary
        : FloatingChromeSurface.fillOf(context);
    final Color glyph = accent
        ? theme.accentButtonForeground(fill)
        : theme.resolvedIconColor;
    // A parked chip still answers a tap with the reason, so it stays enabled.
    final bool enabled = onTap != null;
    return Semantics(
      identifier: semanticsId,
      button: true,
      enabled: enabled,
      child: Tooltip(
        message: tooltip,
        child: Material(
          type: MaterialType.transparency,
          child: InkResponse(
            onTap: onTap,
            // Not contained: the press covers 48 px, the ink only the chip.
            containedInkWell: false,
            highlightShape: BoxShape.circle,
            radius: kMobileChromeChip / 2,
            child: SizedBox.square(
              dimension: MobileLayout.minTouchTarget,
              child: Center(
                // Painted on the Material, so the ink lands on top of it.
                child: Ink(
                  width: kMobileChromeChip,
                  height: kMobileChromeChip,
                  decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
                  child: Center(
                    child: AppIcon(
                      icon,
                      size: 22,
                      color: parked ? glyph.withValues(alpha: 0.45) : glyph,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The coworker pill: chuk's title pill with the face, the name and the live
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
          AgentFace(
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
          pressedShape: RoundedRectangleBorder(
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

  /// What the coworker is doing: offline with a way back, working, or here.
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
    if (agent.running && paired) {
      return Semantics(
        label: 'Working',
        child: SizedBox(
          height:
              MediaQuery.textScalerOf(context).scale(_kPillStatusFontSize) *
              1.3,
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
                        height: 1.3,
                      ),
                    )
                  : WorkingDots(color: scheme.primary, label: ''),
            ),
          ),
        ),
      );
    }
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
    return store.profileOf(agent.id).roleOver(agent.role);
  }
}
