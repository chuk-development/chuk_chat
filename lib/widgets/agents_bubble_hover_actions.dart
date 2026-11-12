// lib/widgets/agents_bubble_hover_actions.dart
//
// Desktop Agents thread: a few quiet actions beside a bubble while the mouse
// is over it (react, reply, more), like a desktop messenger. The phone keeps
// the long-press menu. See docs/DESIGN.md §9 (CHAT-52).

import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/icons/huge_icon.dart';

/// Wraps [child] (a bubble) and shows its actions beside it on hover.
///
/// The actions always take their room, so the bubble never moves when they
/// appear. [alignEnd] puts them on the left of a right-aligned user bubble.
class AgentsBubbleHoverActions extends StatefulWidget {
  const AgentsBubbleHoverActions({
    super.key,
    required this.child,
    required this.alignEnd,
    required this.onMore,
    this.onReact,
    this.onReply,
  });

  final Widget child;
  final bool alignEnd;

  /// Opens the reaction choice; null hides the target.
  final void Function(Offset globalPosition)? onReact;

  /// Quotes the message in the composer; null hides the target.
  final VoidCallback? onReply;

  /// Opens the full message menu (copy and the rest).
  final void Function(Offset globalPosition) onMore;

  @override
  State<AgentsBubbleHoverActions> createState() =>
      _AgentsBubbleHoverActionsState();
}

class _AgentsBubbleHoverActionsState extends State<AgentsBubbleHoverActions> {
  bool _hover = false;

  Widget _target(
    String tooltip,
    HugeIconData icon,
    void Function(Offset globalPosition) onTap,
    Key key,
  ) {
    final Color color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        key: key,
        radius: 16,
        onTapUp: (TapUpDetails d) => onTap(d.globalPosition),
        child: SizedBox.square(
          dimension: 32,
          child: Center(child: HugeIcon(icon, size: 17, color: color)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> targets = <Widget>[
      if (widget.onReact case final void Function(Offset) react)
        _target(
          'React',
          HugeIcons.smile,
          react,
          const ValueKey<String>('bubble-hover-react'),
        ),
      if (widget.onReply case final VoidCallback reply)
        _target(
          'Reply',
          HugeIcons.undo02,
          (_) => reply(),
          const ValueKey<String>('bubble-hover-reply'),
        ),
      _target(
        'More',
        HugeIcons.moreHorizontal,
        widget.onMore,
        const ValueKey<String>('bubble-hover-more'),
      ),
    ];
    final Widget actions = AnimatedOpacity(
      opacity: _hover ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      child: IgnorePointer(
        ignoring: !_hover,
        child: Row(mainAxisSize: MainAxisSize.min, children: targets),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: widget.alignEnd
            ? <Widget>[
                actions,
                const SizedBox(width: 6),
                Flexible(child: widget.child),
              ]
            : <Widget>[
                Flexible(child: widget.child),
                const SizedBox(width: 6),
                actions,
              ],
      ),
    );
  }
}
