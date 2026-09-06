import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:cowork/utils/theme_extensions.dart';
import 'package:cowork/widgets/anchored_menu.dart';

/// How the relay looks to the reader. Not the phase enum: the header only
/// cares about the three states that read differently, so a new transport
/// phase never forces a change here.
enum CoworkThreadConnection { live, connecting, down }

/// One button in the header's trailing group.
///
/// The header owns the look (glyph size, hit box, spacing, tooltip); the
/// caller owns the meaning. That is what keeps a button that moved in from
/// somewhere else — the shell's floating row — from arriving with its own
/// sizing.
@immutable
class CoworkThreadAction {
  const CoworkThreadAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;

  /// Shown on hover, read aloud by a screen reader, and used as the label when
  /// the button folds into the overflow menu — so it has to name the action,
  /// not describe the glyph.
  final String tooltip;

  final VoidCallback onPressed;
}

/// The one bar above a CoWork thread: who you are talking to on the left, what
/// is running on its own in the middle, what you can do to the thread on the
/// right.
///
/// Before this widget the same band held three unrelated things — a labelled
/// "Documents" button the thread view drew, a floating row of icons the shell
/// drew over it, and the automations strip on a line of its own — with nothing
/// to say which mattered. They are one row now, and every action goes through
/// [CoworkThreadAction] so none of them can drift apart again.
///
/// Two shapes:
///
///  * the **bar** (desktop): title, connection, automation chip and actions,
///    on the surface colour with a hairline under it. [leadingInset] is the
///    room the shell's floating hamburger and mini rail need, since they are
///    painted over this widget and the widget cannot see them.
///  * **[dense]** (phone): no title — the floating chrome above already
///    carries the coworker, its face and its presence — and no fill, so the
///    row reads as chips over the chat. [topInset] pushes it clear of that
///    chrome; the chat below then reserves nothing of its own.
///
/// At a narrow width the title ellipsises first and the actions that no longer
/// fit fold into an overflow menu, so nothing is ever dropped and nothing ever
/// overflows.
class CoworkThreadHeader extends StatelessWidget {
  const CoworkThreadHeader({
    super.key,
    this.title,
    this.subtitle,
    this.connection = CoworkThreadConnection.live,
    this.automationLabel,
    this.automationPaused = false,
    this.automationExpanded = false,
    this.onToggleAutomations,
    this.actions = const <CoworkThreadAction>[],
    this.leadingInset = 0,
    this.topInset = 0,
    this.dense = false,
  });

  /// The coworker this thread belongs to. Null before one is selected: the row
  /// then carries the state and the actions alone rather than inventing a name.
  /// Ignored while [dense].
  final String? title;

  /// A second, quieter line — the coworker's role, or the thread. Dropped
  /// while the connection has something to say, which matters more.
  final String? subtitle;

  final CoworkThreadConnection connection;

  /// The running automation as one short line ("Wahlradar · Active", or
  /// "3 automations"). Null hides the chip entirely.
  final String? automationLabel;

  /// Colours the chip's dot: a paused automation is not a live one.
  final bool automationPaused;

  /// Whether the automation cards under the header are open. Drives the
  /// chevron only; the caller owns the state.
  final bool automationExpanded;

  /// Tap on the chip. Null renders the chip flat (nothing to open).
  final VoidCallback? onToggleAutomations;

  final List<CoworkThreadAction> actions;

  /// Left room for chrome painted OVER this widget by the shell.
  final double leadingInset;

  /// Top room for the same reason — the phone's floating bar.
  final double topInset;

  final bool dense;

  /// One action's footprint: Material's 40 px hit box, the size chuk's own
  /// icon rows use.
  static const double _slot = 40;

  /// Width the title keeps for itself before actions start folding away. Below
  /// it a header would be all buttons and no subject.
  static const double _minTitleWidth = 96;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final row = SizedBox(
      height: _slot,
      child: LayoutBuilder(
        builder: (context, constraints) =>
            _buildRow(context, constraints.maxWidth),
      ),
    );
    final padded = Padding(
      padding: EdgeInsets.fromLTRB(
        leadingInset + (dense ? 8 : 12),
        topInset + (dense ? 2 : 16),
        dense ? 4 : 8,
        dense ? 2 : 8,
      ),
      child: row,
    );
    if (dense) return padded;
    return Material(
      color: scheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: padded,
      ),
    );
  }

  Widget _buildRow(BuildContext context, double maxWidth) {
    // How many actions fit next to a title that keeps [_minTitleWidth]. One
    // slot goes back to the overflow button as soon as anything folds.
    final int room = math.max(
      0,
      ((maxWidth - _minTitleWidth) / _slot).floor(),
    );
    final bool overflows = actions.length > room;
    final int inline = overflows ? math.max(0, room - 1) : actions.length;
    return Row(
      children: [
        // One Expanded around the subject: it takes every pixel the buttons
        // leave, so the actions stay flush right whatever the title's length.
        Expanded(
          child: Row(
            children: [
              // The dense shape has no subject block at all: on a phone the
              // floating chrome above carries the coworker and its presence.
              if (!dense) Flexible(flex: 3, child: _buildTitle(context)),
              if (automationLabel != null)
                Flexible(
                  flex: 2,
                  child: Padding(
                    padding: EdgeInsets.only(left: dense ? 0 : 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _AutomationChip(
                        label: automationLabel!,
                        paused: automationPaused,
                        expanded: automationExpanded,
                        onTap: onToggleAutomations,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        for (final action in actions.take(inline))
          _buildAction(context, action),
        if (overflows) _buildOverflow(context, actions.skip(inline).toList()),
      ],
    );
  }

  Widget _buildTitle(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // The state is a colour and a tooltip, never a line of text. The socket
    // comes back on its own and re-pairing lives in the bottom bar, so a
    // running commentary on the connection would be chatter the reader can do
    // nothing with — the rule the whole view already follows.
    final String state = switch (connection) {
      CoworkThreadConnection.live => 'Connected',
      CoworkThreadConnection.connecting => 'Connecting…',
      CoworkThreadConnection.down => 'Offline',
    };
    final Color dot = switch (connection) {
      CoworkThreadConnection.live => scheme.primary,
      CoworkThreadConnection.connecting => scheme.tertiary,
      CoworkThreadConnection.down => scheme.error,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: state,
          child: Icon(Icons.circle, size: 8, color: dot),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (title != null)
                Text(
                  title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Every action is the same button, so a button that moved in from the
  /// shell cannot arrive with its own sizing.
  Widget _buildAction(BuildContext context, CoworkThreadAction action) =>
      _HeaderButton(
        icon: action.icon,
        tooltip: action.tooltip,
        onTap: action.onPressed,
      );

  /// What no longer fits, in a menu — folded, never dropped. The house
  /// [showAnchoredMenu] rather than a [PopupMenuButton]: the menu then opens
  /// where the button is instead of growing off the bottom of a phone.
  Widget _buildOverflow(BuildContext context, List<CoworkThreadAction> folded) {
    final theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;
    return Builder(
      builder: (anchorContext) => _HeaderButton(
        icon: Icons.more_horiz,
        tooltip: 'More actions',
        onTap: () async {
          final CoworkThreadAction? picked =
              await showAnchoredMenu<CoworkThreadAction>(
                anchorContext,
                items: <PopupMenuEntry<CoworkThreadAction>>[
                  for (final action in folded)
                    PopupMenuItem<CoworkThreadAction>(
                      value: action,
                      child: Row(
                        children: [
                          Icon(action.icon, size: 18, color: iconFg),
                          const SizedBox(width: 12),
                          Text(action.tooltip),
                        ],
                      ),
                    ),
                ],
                color: theme.scaffoldBackgroundColor.withValues(alpha: 0.94),
                borderColor: iconFg.withValues(alpha: 0.3),
              );
          picked?.onPressed();
        },
      ),
    );
  }
}

/// One header button: a 40 px round ink target with a tooltip.
///
/// Not Material's [IconButton]. The phone layout moves the whole thread view
/// between two parents by its [GlobalKey] on every back gesture, and an
/// IconButton in the moved subtree trips a framework assertion while the
/// semantics tree is rebuilt (`computeChildGeometry`). A plain Material and
/// InkWell — the shape the mobile chips already use — survives the move.
class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color iconFg = Theme.of(context).resolvedIconColor;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: CoworkThreadHeader._slot,
            height: CoworkThreadHeader._slot,
            child: Icon(icon, size: 20, color: iconFg),
          ),
        ),
      ),
    );
  }
}

/// The running automation, as small as it can be and still be read: a state
/// dot, the name, and the chevron that opens the cards underneath.
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Color dot = paused ? scheme.tertiary : scheme.primary;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 7, color: dot),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
