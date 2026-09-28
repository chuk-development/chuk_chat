import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// One button in the thread's floating row.
///
/// The row owns the look (glyph size, hit box, spacing, tooltip); the caller
/// owns the meaning. That is what keeps a button that moved in from somewhere
/// else from arriving with its own sizing.
/// How the relay looks to the reader. Not the phase enum: the row only cares
/// about the three states that read differently, so a new transport phase
/// never forces a change here.
enum AgentsThreadConnection { live, connecting, down }

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

  /// Shown on hover, read aloud by a screen reader, and used as the label when
  /// the button folds into the "…" menu — so it has to name the action, not
  /// describe the glyph.
  final String tooltip;

  final VoidCallback onPressed;
}

/// The actions of a desktop thread, as chuk_chat draws the buttons over its
/// chat: bare icon buttons floating at the top right of the chat area
/// (`root_wrapper_desktop.dart`, "Copy full chat"). No bar, no title and no
/// rule under it — the roster already says whose thread this is.
///
/// From left to right: the relay's state while it is down, the running
/// automation (when there is one), the coworker's screen, the caller's
/// [actions], and the "…" menu for [menuActions] and for whatever does not
/// fit. At a narrow width actions fold into that menu, so nothing is ever
/// dropped and nothing overflows.
class AgentsThreadHeader extends StatelessWidget {
  const AgentsThreadHeader({
    super.key,
    this.automationLabel,
    this.automationPaused = false,
    this.automationExpanded = false,
    this.onToggleAutomations,
    this.actions = const <AgentsThreadAction>[],
    this.menuActions = const <AgentsThreadAction>[],
    this.showScreenTarget = false,
    this.onOpenScreen,
    this.connection = AgentsThreadConnection.live,
    this.onReconnect,
  });

  /// The relay. A live socket, and one on its way back, are not news: only a
  /// relay that is down shows, as "Offline · Reconnect", the words the phone's
  /// title pill uses.
  final AgentsThreadConnection connection;

  /// Tap on the offline chip. Null keeps it a plain "Offline".
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

  final List<AgentsThreadAction> actions;

  /// Actions that are not worth a button of their own. Anything from
  /// [actions] that does not fit joins them behind "…".
  final List<AgentsThreadAction> menuActions;

  /// Whether the coworker's screen target is shown: only while a thread is
  /// open.
  final bool showScreenTarget;

  /// Opens the live view of the coworker's screen (its sandbox VNC). Null keeps
  /// the target in place but parked — there is no screen open.
  final VoidCallback? onOpenScreen;

  /// One button's footprint: a 20 px glyph with 10 px of ink around it, the
  /// size of chuk's icon button.
  static const double slot = 40;

  /// Width the automation chip keeps for itself before buttons fold.
  static const double _automationReserve = 160;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double maxWidth = box.maxWidth.isFinite ? box.maxWidth : 1e6;
        final bool down = connection == AgentsThreadConnection.down;
        final double reserve =
            (automationLabel == null ? 0 : _automationReserve) +
            (down ? _automationReserve : 0);
        final int fixed = showScreenTarget ? 1 : 0;
        final int room = math.max(
          0,
          ((maxWidth - reserve) / slot).floor() - fixed,
        );
        final bool needsMenu =
            menuActions.isNotEmpty || actions.length > room;
        final int inline = needsMenu
            ? math.max(0, math.min(actions.length, room - 1))
            : actions.length;
        final List<AgentsThreadAction> folded = <AgentsThreadAction>[
          ...actions.skip(inline),
          ...menuActions,
        ];
        return Align(
          alignment: Alignment.topRight,
          heightFactor: 1,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (down) ...<Widget>[
                Flexible(
                  child: _OfflineChip(
                    key: const ValueKey<String>('thread-offline'),
                    onReconnect: onReconnect,
                  ),
                ),
                const SizedBox(width: 4),
              ],
              if (automationLabel != null) ...<Widget>[
                Flexible(
                  child: _AutomationChip(
                    label: automationLabel!,
                    paused: automationPaused,
                    expanded: automationExpanded,
                    onTap: onToggleAutomations,
                  ),
                ),
                const SizedBox(width: 4),
              ],
              if (showScreenTarget) _screenButton(context),
              for (final AgentsThreadAction action in actions.take(inline))
                ChromeIconButton(
                  icon: action.icon,
                  tooltip: action.tooltip,
                  selected: action.selected,
                  onPressed: action.onPressed,
                ),
              if (folded.isNotEmpty) _menuButton(context, folded),
            ],
          ),
        );
      },
    );
  }

  /// The coworker's screen. Parked while it has none open: a quieter glyph
  /// that still answers a tap with the reason.
  Widget _screenButton(BuildContext context) {
    final bool open = onOpenScreen != null;
    return ChromeIconButton(
      icon: Icons.desktop_windows_rounded,
      parked: !open,
      tooltip: open ? "Agent's screen" : 'No screen open right now',
      semanticsId: 'thread_header_screen',
      onPressed:
          onOpenScreen ??
          () => AppNotifications.show(
            context,
            'The coworker has no screen open right now',
          ),
    );
  }

  /// What no longer fits, in chuk's popup menu under the button — folded,
  /// never dropped.
  Widget _menuButton(BuildContext context, List<AgentsThreadAction> folded) {
    return Builder(
      builder: (BuildContext anchor) => ChromeIconButton(
        icon: Icons.more_horiz,
        tooltip: 'More actions',
        onPressed: () async {
          final Color iconFg = Theme.of(anchor).resolvedIconColor;
          final RenderBox? overlay =
              Overlay.of(anchor).context.findRenderObject() as RenderBox?;
          final RenderBox? button = anchor.findRenderObject() as RenderBox?;
          if (overlay == null || button == null) return;
          final Offset topLeft = button.localToGlobal(
            Offset.zero,
            ancestor: overlay,
          );
          final AgentsThreadAction? picked =
              await showMenu<AgentsThreadAction>(
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
                  for (final AgentsThreadAction action in folded)
                    PopupMenuItem<AgentsThreadAction>(
                      value: action,
                      child: Row(
                        children: <Widget>[
                          AppIcon(action.icon, color: iconFg, size: 20),
                          const SizedBox(width: 12),
                          Text(action.tooltip),
                        ],
                      ),
                    ),
                ],
              );
          picked?.onPressed();
        },
      ),
    );
  }
}

/// chuk's icon button over the chat: a 20 px glyph in the icon colour, round
/// ink, a tooltip.
///
/// Built from a Material and an InkWell rather than Material's [IconButton]:
/// the thread view moves between parents by its [GlobalKey] when the window
/// crosses the phone breakpoint, and an IconButton in a moved subtree trips a
/// framework assertion while the semantics tree is rebuilt. The look is the
/// same — chuk's floating chips are built this way too.
class ChromeIconButton extends StatelessWidget {
  const ChromeIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.parked = false,
    this.semanticsId,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// A toggle that is on: the glyph takes the accent.
  final bool selected;

  /// Not ready: the glyph is quieter, and a tap still reaches [onPressed],
  /// which is expected to say why.
  final bool parked;

  final String? semanticsId;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color base = selected
        ? theme.colorScheme.primary
        : theme.resolvedIconColor;
    final Color glyph = parked ? base.withValues(alpha: 0.45) : base;
    return Semantics(
      identifier: semanticsId,
      button: true,
      toggled: selected ? true : null,
      // Parked still answers a tap with the reason; the glyph and the
      // tooltip carry the parked state.
      enabled: onPressed != null,
      child: Tooltip(
        message: tooltip,
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: AgentsThreadHeader.slot,
              height: AgentsThreadHeader.slot,
              child: Center(child: AppIcon(icon, size: 20, color: glyph)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The relay is down: a quiet dot and "Offline", with the way back when there
/// is one. chuk's chrome surface, like the automation chip beside it.
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
        radius: 18,
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onReconnect,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
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
/// on chuk's chrome surface, like the chat's title pill.
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
      radius: 18,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
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
