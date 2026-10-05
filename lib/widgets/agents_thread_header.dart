import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart'; // own browser
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/platform_specific/chat/voice/chat_voice_binding.dart';
import 'package:chuk_chat/platform_specific/chat/voice/chat_voice_call_button.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_chat_chrome.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// How the relay looks to the reader. Not the phase enum: the header only
/// cares about the three states that read differently, so a new transport
/// phase never forces a change here.
enum AgentsThreadConnection { live, connecting, down }

/// One entry of the header's "…" menu.
@immutable
class AgentsThreadAction {
  const AgentsThreadAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  /// A toggle that is on (the details pane): its glyph takes the accent.
  final bool selected;

  final IconData icon;

  /// The label of the menu row, and what a screen reader reads — so it has to
  /// name the action, not describe the glyph.
  final String tooltip;

  final VoidCallback onPressed;
}

/// The top bar of a desktop Agents thread: the phone's chat top bar
/// (`mobile_chat_chrome.dart`) on a desktop window, built from the same
/// widgets ([AgentChromePill], [ChromeChip]) so the two layouts read alike.
///
/// From left to right:
///
///  * the coworker pill — face, name and status line ("Active now", three
///    dots while it works, "Offline · Reconnect"). A tap opens the details
///    pane. A desktop window has no back chip: the roster is beside it;
///  * the running automation, when there is one;
///  * the three primary chips, in the phone's order: Documents, Call,
///    Screen;
///  * one "…" chip for everything else ([menuActions]: details, copy full
///    chat, profile, rename).
///
/// The row floats on a fade from the page colour, as on the phone: solid
/// behind the chips, clear by its lower edge. The transcript scrolls up
/// under the fade, so no message text ever runs into a chip, or into the
/// Chat | Agents switch that the desktop shell floats on the same line.
class AgentsThreadHeader extends StatelessWidget {
  const AgentsThreadHeader({
    super.key,
    this.agent,
    this.onOpenAgent,
    this.profiles,
    this.automationLabel,
    this.automationPaused = false,
    this.automationExpanded = false,
    this.onToggleAutomations,
    this.onOpenDocuments,
    this.menuActions = const <AgentsThreadAction>[],
    this.showScreenTarget = false,
    this.onOpenScreen,
    this.connection = AgentsThreadConnection.live,
    this.onReconnect,
    this.agentName,
    this.usesUserBrowser = false, // own browser
  });

  // ── own browser ──
  /// The coworker drives the user's own browser (`run_state.browser_target`).
  /// That browser has no screen here: the parked target says so, and is
  /// never lit for it.
  final bool usesUserBrowser;
  // ── end own browser ──

  /// The coworker whose thread this is. Null (no thread open) leaves the
  /// left side empty.
  final AgentsAgent? agent;

  /// Tap on the coworker pill: the details pane. Null renders it flat.
  final VoidCallback? onOpenAgent;

  final AgentProfileStore? profiles;

  /// The coworker's display name, for the voice call's greeting. Falls back
  /// to [agent]'s name.
  final String? agentName;

  /// The relay. A live socket, and one on its way back, are not news: only a
  /// relay that is down shows, as "Offline · Reconnect" in the pill's status
  /// line — the words the phone's pill uses.
  final AgentsThreadConnection connection;

  /// Tap on "Offline". Null keeps it a plain "Offline".
  final VoidCallback? onReconnect;

  /// The running automation as one short line ("Wahlradar · Active", or
  /// "3 automations"). Null hides the chip entirely.
  final String? automationLabel;

  /// Colours the chip's dot: a paused automation is not a live one.
  final bool automationPaused;

  /// Whether the automation cards under the row are open. Drives the chevron
  /// only; the caller owns the state.
  final bool automationExpanded;

  /// Tap on the chip. Null renders the chip flat (nothing to open).
  final VoidCallback? onToggleAutomations;

  /// The thread's shared files. Null hides the chip (no thread open).
  final VoidCallback? onOpenDocuments;

  /// Everything that is not one of the three primary chips. Shown behind
  /// "…"; the chip is hidden when there is nothing to show.
  final List<AgentsThreadAction> menuActions;

  /// Whether the coworker's screen target (and with it the call target) is
  /// shown: only while a thread is open.
  final bool showScreenTarget;

  /// Opens the live view of the coworker's screen (its sandbox VNC). Null
  /// keeps the target in place but parked — there is no screen open.
  final VoidCallback? onOpenScreen;

  /// One chip's box: 42 px painted, a 48 px press. The phone's chip.
  static const double chipBox = 48;

  /// How far a chip's press reaches past its paint on each side.
  static const double _reach = (chipBox - kMobileChromeChip) / 2;

  /// Space between the pane's edges and what is painted at them.
  static const double edge = 12;

  /// The top of the row: its centre sits on the line of the desktop's chrome
  /// buttons (the menu button, the Chat | Agents switch).
  static const double rowTop =
      kTopInitialSpacing + (kButtonVisualHeight - chipBox) / 2;

  /// The bottom of the row: the transcript's first message starts below it.
  static const double rowBottom = rowTop + chipBox;

  /// The fade under the row, where the scrolling transcript disappears.
  static const double fade = 16;

  /// The whole band, fade included.
  static const double height = rowBottom + fade;

  /// The widest the left side (pill and automation chip) grows. The desktop
  /// shell keeps the Chat | Agents switch clear of this much.
  static const double leadingMaxWidth = 280;

  /// What the trailing chips take from the right edge of the pane, edge
  /// included: Documents, Call (when the build offers calls), Screen and
  /// "…". The desktop shell keeps the switch clear of it.
  static double trailingExtent({bool? call}) {
    final int chips = 3 + ((call ?? voiceCallUiEnabled) ? 1 : 0);
    return edge - _reach + chips * chipBox;
  }

  /// The narrowest the pill is squeezed before Documents folds into "…".
  static const double _pillMin = 140;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double maxWidth = box.maxWidth.isFinite ? box.maxWidth : 1e6;
        final AgentsAgent? who = agent;
        final bool down = connection == AgentsThreadConnection.down;
        // The call target rides with the screen target: both only while a
        // thread is open, and the call only when the build offers calls.
        final bool showCall = showScreenTarget && voiceCallUiEnabled;
        final bool hasDocuments = onOpenDocuments != null;
        final int fixedChips =
            (showScreenTarget ? 1 : 0) + (showCall ? 1 : 0) + 1;
        // A pane too narrow for the pill and every chip folds Documents into
        // the menu: folded, never dropped.
        final bool foldDocuments =
            hasDocuments &&
            maxWidth - 2 * edge - (fixedChips + 1) * chipBox < _pillMin;
        final List<AgentsThreadAction> menu = <AgentsThreadAction>[
          if (foldDocuments)
            AgentsThreadAction(
              icon: Icons.folder_open_rounded,
              tooltip: 'Documents',
              onPressed: onOpenDocuments!,
            ),
          ...menuActions,
        ];
        final List<Widget> leading = <Widget>[
          if (who != null)
            Flexible(
              flex: 3,
              child: AgentChromePill(
                key: const ValueKey<String>('thread-header-pill'),
                agent: who,
                onTap: onOpenAgent,
                profiles: profiles,
                paired: !down,
                onReconnect: onReconnect,
                semanticsId: 'thread_header_pill',
              ),
            )
          else if (down)
            Flexible(
              child: _OfflineChip(
                key: const ValueKey<String>('thread-offline'),
                onReconnect: onReconnect,
              ),
            ),
          if (automationLabel != null) ...<Widget>[
            const SizedBox(width: 6),
            Flexible(
              flex: 2,
              child: _AutomationChip(
                label: automationLabel!,
                paused: automationPaused,
                expanded: automationExpanded,
                onTap: onToggleAutomations,
              ),
            ),
          ],
        ];
        return AgentsHeaderBand(
          leading: leading.isEmpty
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: leading),
          trailing: <Widget>[
            if (hasDocuments && !foldDocuments)
              ChromeChip(
                icon: Icons.folder_open_rounded,
                tooltip: 'Documents',
                semanticsId: 'thread_header_documents',
                onTap: onOpenDocuments,
              ),
            if (showCall)
              ChatVoiceCallButton.agentsThread(
                style: ChatVoiceCallStyle.chip,
                agentName: agentName ?? who?.name,
                semanticsId: 'thread_header_call',
              ),
            if (showScreenTarget) _screenChip(context),
            if (menu.isNotEmpty) _menuChip(context, menu),
          ],
        );
      },
    );
  }

  /// The coworker's screen: lit when there is one to take over, parked when
  /// there is none — and a parked tap says why, so it is never a dead
  /// button. The phone's screen chip.
  Widget _screenChip(BuildContext context) {
    final bool open = onOpenScreen != null;
    // ── own browser ──
    if (!open && usesUserBrowser) {
      final AppLocalizations? l = AppLocalizations.of(context);
      return ChromeChip(
        icon: Icons.desktop_windows_rounded,
        parked: true,
        tooltip: l?.ubScreenTooltip ?? 'Works in your browser',
        semanticsId: 'thread_header_screen',
        onTap: () => AppNotifications.show(
          context,
          l?.ubScreenExplain ??
              'This coworker works in your own browser. There is no screen '
                  'to show here.',
        ),
      );
    }
    // ── end own browser ──
    return ChromeChip(
      icon: Icons.desktop_windows_rounded,
      accent: open,
      parked: !open,
      tooltip: open ? "Agent's screen" : 'No screen open right now',
      semanticsId: 'thread_header_screen',
      onTap:
          onOpenScreen ??
          () => AppNotifications.show(
            context,
            'The coworker has no screen open right now',
          ),
    );
  }

  /// The "…" chip, with chuk's popup menu under it.
  Widget _menuChip(BuildContext context, List<AgentsThreadAction> menu) {
    return Builder(
      builder: (BuildContext anchor) => ChromeChip(
        icon: Icons.more_horiz_rounded,
        tooltip: 'More actions',
        semanticsId: 'thread_header_more',
        onTap: () => _openMenu(anchor, menu),
      ),
    );
  }

  Future<void> _openMenu(
    BuildContext anchor,
    List<AgentsThreadAction> menu,
  ) async {
    final ThemeData theme = Theme.of(anchor);
    final Color iconFg = theme.resolvedIconColor;
    final RenderBox? overlay =
        Overlay.of(anchor).context.findRenderObject() as RenderBox?;
    final RenderBox? button = anchor.findRenderObject() as RenderBox?;
    if (overlay == null || button == null) return;
    final Offset topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final AgentsThreadAction? picked = await showMenu<AgentsThreadAction>(
      context: anchor,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(
          topLeft.dx,
          topLeft.dy + button.size.height,
          button.size.width,
          1,
        ),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<AgentsThreadAction>>[
        for (final AgentsThreadAction action in menu)
          PopupMenuItem<AgentsThreadAction>(
            value: action,
            child: Row(
              children: <Widget>[
                AppIcon(
                  action.icon,
                  color: action.selected
                      ? theme.accentForegroundOn(
                          theme.popupMenuTheme.color ??
                              theme.m3.surfaceContainer,
                        )
                      : iconFg,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    action.tooltip,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    picked?.onPressed();
  }
}

/// The band a desktop centre pane floats its top row on: the page colour
/// behind the row and a fade below it, so whatever scrolls underneath
/// disappears before it reaches a chip. [leading] sits at the left edge,
/// [trailing] chips at the right one.
///
/// The thread header and an open room both use it, so the two read as the
/// same bar.
class AgentsHeaderBand extends StatelessWidget {
  const AgentsHeaderBand({
    super.key,
    this.leading,
    this.trailing = const <Widget>[],
  });

  final Widget? leading;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final Color page = Theme.of(context).scaffoldBackgroundColor;
    const double reach = AgentsThreadHeader._reach;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // The page colour behind the row. It takes a click, so nothing hidden
        // under it is ever pressed by a miss of a chip.
        ColoredBox(
          color: page,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AgentsThreadHeader.edge,
              AgentsThreadHeader.rowTop,
              AgentsThreadHeader.edge - reach,
              0,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: AgentsThreadHeader.chipBox,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      heightFactor: 1,
                      child: leading == null
                          ? const SizedBox.shrink()
                          : ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: AgentsThreadHeader.leadingMaxWidth,
                              ),
                              child: leading,
                            ),
                    ),
                  ),
                  if (trailing.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 8 - reach),
                    ...trailing,
                  ],
                ],
              ),
            ),
          ),
        ),
        // The fade under it: the transcript disappears here on its way up.
        // It is only paint — a click goes through to the message under it.
        IgnorePointer(
          child: SizedBox(
            key: const ValueKey<String>('agents-header-fade'),
            height: AgentsThreadHeader.fade,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[page, page.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The relay is down and there is no coworker pill to say so: a quiet dot
/// and "Offline", with the way back when there is one.
class _OfflineChip extends StatelessWidget {
  const _OfflineChip({super.key, this.onReconnect});

  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;
    return Semantics(
      button: onReconnect != null,
      label: onReconnect == null ? 'Offline' : 'Offline. Reconnect',
      child: FloatingChromeSurface(
        radius: kMobileChromePillRadius,
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(kMobileChromePillRadius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onReconnect,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 11, 14, 11),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  AppIcon(
                    Icons.circle,
                    size: 7,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      onReconnect == null ? 'Offline' : 'Offline · Reconnect',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: iconFg.withValues(alpha: 0.92),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The running automation, as small as it can be and still be read: a state
/// dot, the name, and the chevron that opens the cards underneath. It floats
/// on chuk's chrome surface, beside the coworker pill.
class _AutomationChip extends StatelessWidget {
  const _AutomationChip({
    required this.label,
    required this.paused,
    required this.expanded,
    this.onTap,
  });

  final String label;
  final bool paused;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color iconFg = theme.resolvedIconColor;
    final Color dot = paused ? scheme.tertiary : scheme.primary;
    return FloatingChromeSurface(
      radius: kMobileChromePillRadius,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(kMobileChromePillRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                AppIcon(Icons.circle, size: 7, color: dot),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: iconFg.withValues(alpha: 0.92),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                AppIcon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: iconFg.withValues(alpha: 0.7),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
