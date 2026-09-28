// lib/widgets/pane_header.dart
//
// The header of a side pane on a wide window. chuk_chat's artifact panel
// draws it, and the Agents desktop draws its details and Control Rooms panes
// with the same widget, so there is one pane header in the app.

import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// A side pane's header: 56 px high, a quiet line under it, an 18 px glyph
/// and the title on the left, the pane's controls on the right.
class PaneHeader extends StatelessWidget {
  const PaneHeader({
    super.key,
    required this.icon,
    required this.title,
    this.actions = const <Widget>[],
  });

  /// A header whose title is plain text, one line, in [titleStyle].
  PaneHeader.text({
    super.key,
    required this.icon,
    required String text,
    this.actions = const <Widget>[],
  }) : title = Text(
         text,
         maxLines: 1,
         overflow: TextOverflow.ellipsis,
         style: titleStyle,
       );

  /// The style of a plain-text title.
  static const TextStyle titleStyle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );

  final IconData icon;

  /// Fills the room between the glyph and [actions].
  final Widget title;

  /// The controls on the right, in order.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final Color iconFg = Theme.of(context).resolvedIconColor;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: iconFg.withValues(alpha: 0.12)),
        ),
      ),
      child: Row(
        children: <Widget>[
          AppIcon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(child: title),
          ...actions,
        ],
      ),
    );
  }
}
