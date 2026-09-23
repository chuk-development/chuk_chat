/// The small controls of the Agents desktop layout (docs/DESIGN.md §14): the
/// bar button, the pane divider that resizes, and the header row every pane
/// shares. Desktop only — the phone never builds any of these.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/ui/expressive/icon_map.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_metrics.dart';

/// One icon button in a desktop bar: a 32 px square with a 20 px glyph.
///
/// Every bar button is this one widget, so no button can arrive with a fill
/// or a size of its own (§14.2 — "no button has its own dark square"). It is
/// flat until the pointer is on it; [selected] marks a toggle that is on (the
/// details pane, for instance) with the same fill a selected roster row uses.
/// A [parked] button still reads and still answers a click — the caller says
/// why it cannot act — but its glyph is quiet.
class DeskIconButton extends StatefulWidget {
  const DeskIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.parked = false,
    this.color,
    this.size = kDeskButton,
    this.glyph = kDeskGlyph,
    this.semanticsId,
  });

  final IconData icon;

  /// Names the action and, where there is one, its shortcut.
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final bool parked;

  /// The glyph colour. Defaults to `onSurfaceVariant`.
  final Color? color;
  final double size;
  final double glyph;
  final String? semanticsId;

  @override
  State<DeskIconButton> createState() => _DeskIconButtonState();
}

class _DeskIconButtonState extends State<DeskIconButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fill = widget.selected
        ? scheme.secondaryContainer
        : ((_hovered || _focused) && widget.onPressed != null
              ? scheme.surfaceContainerHigh
              : Colors.transparent);
    final Color base = widget.selected
        ? scheme.onSecondaryContainer
        : (widget.color ?? scheme.onSurfaceVariant);
    final Color glyph = widget.parked ? base.withValues(alpha: 0.45) : base;
    return Semantics(
      identifier: widget.semanticsId,
      button: true,
      toggled: widget.selected ? true : null,
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 400),
        // Keyboard: Tab reaches the button, Enter or Space presses it, and a
        // ring shows where the focus is. The pointer path below is as it was.
        child: DeskFocusable(
          onActivate: widget.onPressed,
          onFocusHighlight: (bool on) => setState(() => _focused = on),
          child: MouseRegion(
            cursor: widget.onPressed == null
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPressed,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOutCubic,
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(kDeskControlRadius),
                  border: _focused
                      ? Border.all(color: scheme.primary, width: 2)
                      : null,
                ),
                alignment: Alignment.center,
                child: AppIcon(widget.icon, size: widget.glyph, color: glyph),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens a context menu from the keyboard (the Menu key, Shift+F10).
class DeskContextMenuIntent extends Intent {
  const DeskContextMenuIntent();
}

/// The keyboard half of a desktop control: a focus stop that Enter and Space
/// activate (the app's [ActivateIntent] shortcuts), and that reports when its
/// focus ring should show — only while the keyboard is driving, never after a
/// click. [onContextMenu] adds the Menu key and Shift+F10.
///
/// It does not take the pointer: the caller keeps its own hover and tap
/// handling, so a mouse behaves exactly as before.
class DeskFocusable extends StatelessWidget {
  const DeskFocusable({
    super.key,
    required this.child,
    required this.onActivate,
    required this.onFocusHighlight,
    this.onContextMenu,
  });

  final Widget child;
  final VoidCallback? onActivate;
  final ValueChanged<bool> onFocusHighlight;
  final VoidCallback? onContextMenu;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      enabled: onActivate != null,
      mouseCursor: MouseCursor.defer,
      onShowFocusHighlight: onFocusHighlight,
      shortcuts: onContextMenu == null
          ? null
          : const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.contextMenu):
                  DeskContextMenuIntent(),
              SingleActivator(LogicalKeyboardKey.f10, shift: true):
                  DeskContextMenuIntent(),
            },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent _) {
            onActivate?.call();
            return null;
          },
        ),
        if (onContextMenu != null)
          DeskContextMenuIntent: CallbackAction<DeskContextMenuIntent>(
            onInvoke: (DeskContextMenuIntent _) {
              onContextMenu!.call();
              return null;
            },
          ),
      },
      child: child,
    );
  }
}

/// A 1 px hairline in `outlineVariant`, horizontal or vertical.
class DeskHairline extends StatelessWidget {
  const DeskHairline({super.key, this.vertical = false});

  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.outlineVariant;
    return vertical
        ? SizedBox(width: 1, child: ColoredBox(color: color))
        : SizedBox(height: 1, child: ColoredBox(color: color));
  }
}

/// The drag target on a pane border. It paints nothing of its own — the
/// hairline is the pane's — and is wider than the line so the pointer finds
/// it: the column-resize cursor shows over [hitWidth] pixels centred on the
/// border. [onDrag] gets the horizontal delta; the owner clamps.
class PaneResizeHandle extends StatefulWidget {
  const PaneResizeHandle({
    super.key,
    required this.onDrag,
    this.onDragEnd,
    this.onDoubleTap,
    this.hitWidth = 8,
    this.semanticLabel = 'Resize pane',
  });

  final ValueChanged<double> onDrag;
  final VoidCallback? onDragEnd;

  /// Back to the default width.
  final VoidCallback? onDoubleTap;
  final double hitWidth;
  final String semanticLabel;

  @override
  State<PaneResizeHandle> createState() => _PaneResizeHandleState();
}

class _PaneResizeHandleState extends State<PaneResizeHandle> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _active = true),
        onExit: (_) => setState(() => _active = false),
        // Raw pointer moves, not a drag recogniser: the border follows the
        // pointer from the first pixel, with no slop to swallow the start.
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerMove: (PointerMoveEvent e) => widget.onDrag(e.delta.dx),
          onPointerUp: (_) => widget.onDragEnd?.call(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: widget.onDoubleTap,
            child: SizedBox(
              width: widget.hitWidth,
              child: Center(
                // While the pointer is on it the border thickens a little, so
                // the reader sees what they are about to drag.
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: _active ? 3 : 0,
                  color: _active
                      ? scheme.outline.withValues(alpha: 0.6)
                      : Colors.transparent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The 48 px header row of a side pane, lined up with the thread's title bar:
/// a title on the left, the pane's own buttons on the right, a hairline under
/// it.
class DeskPaneHeader extends StatelessWidget {
  const DeskPaneHeader({
    super.key,
    required this.title,
    this.leading,
    this.actions = const <Widget>[],
    this.padding = const EdgeInsets.fromLTRB(16, 0, 8, 0),
  });

  final String title;
  final Widget? leading;
  final List<Widget> actions;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: kDeskBarHeight - 1,
          child: Padding(
            padding: padding,
            child: Row(
              children: <Widget>[
                if (leading != null) ...<Widget>[
                  leading!,
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (int i = 0; i < actions.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(width: kDeskButtonGap),
                  actions[i],
                ],
              ],
            ),
          ),
        ),
        const DeskHairline(),
      ],
    );
  }
}

/// The platform's name for the primary modifier: Cmd on a Mac, Ctrl
/// elsewhere. Used in tooltips and menu rows.
String deskShortcutLabel(String keys) {
  final bool mac = defaultTargetPlatform == TargetPlatform.macOS;
  return mac ? keys.replaceAll('Ctrl+', '⌘') : keys;
}

/// Whether the platform's primary modifier is down (Cmd on a Mac).
bool deskPrimaryModifierPressed() {
  final HardwareKeyboard keyboard = HardwareKeyboard.instance;
  return defaultTargetPlatform == TargetPlatform.macOS
      ? keyboard.isMetaPressed
      : keyboard.isControlPressed;
}
