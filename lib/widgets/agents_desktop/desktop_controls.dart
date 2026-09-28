/// The small pieces of the Agents desktop layout that chuk_chat has no
/// counterpart for: the pane divider that resizes, and the names of the
/// keyboard's primary modifier. Desktop only — the phone never builds them.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';


/// The drag target on a pane border, drawn as chuk_chat draws the divider in
/// front of its artifact panel (`root_wrapper_desktop.dart`): a 6 px zone with
/// the column-resize cursor and, when [lineColor] is set, a 1 px line in its
/// middle. A border that needs no line (the roster's, where the panel colour
/// already changes) passes none. [onDrag] gets the horizontal delta; the
/// owner clamps.
class PaneResizeHandle extends StatelessWidget {
  const PaneResizeHandle({
    super.key,
    required this.onDrag,
    this.onDragEnd,
    this.onDoubleTap,
    this.hitWidth = 6,
    this.lineColor,
    this.semanticLabel = 'Resize pane',
  });

  final ValueChanged<double> onDrag;
  final VoidCallback? onDragEnd;

  /// Back to the default width.
  final VoidCallback? onDoubleTap;
  final double hitWidth;
  final Color? lineColor;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        // Raw pointer moves, not a drag recogniser: the border follows the
        // pointer from the first pixel, with no slop to swallow the start.
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerMove: (PointerMoveEvent e) => onDrag(e.delta.dx),
          onPointerUp: (_) => onDragEnd?.call(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: onDoubleTap,
            child: SizedBox(
              width: hitWidth,
              child: lineColor == null
                  ? null
                  : Center(child: Container(width: 1, color: lineColor)),
            ),
          ),
        ),
      ),
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
