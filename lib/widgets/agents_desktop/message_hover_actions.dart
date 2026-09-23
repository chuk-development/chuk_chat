/// Message actions on hover (docs/DESIGN.md §14.4): copy, retry, branch and
/// the rest sit in a small toolbar at the top right of the message while the
/// pointer is on it — not as a permanent pill under every message.
///
/// Desktop only: the Agents desktop transcript wraps each row in this; the
/// phone keeps its long-press menu and never builds one.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/agents_desktop/desktop_controls.dart';
import 'package:chuk_chat/widgets/message_bubble.dart' show MessageBubbleAction;

class MessageHoverActions extends StatefulWidget {
  const MessageHoverActions({
    super.key,
    required this.actions,
    required this.child,
  });

  final List<MessageBubbleAction> actions;
  final Widget child;

  @override
  State<MessageHoverActions> createState() => _MessageHoverActionsState();
}

class _MessageHoverActionsState extends State<MessageHoverActions> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (widget.actions.isEmpty) return widget.child;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          widget.child,
          if (_hovered)
            Positioned(
              key: const ValueKey<String>('message-hover-toolbar'),
              top: 0,
              right: 0,
              child: Material(
                color: scheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (final MessageBubbleAction action in widget.actions)
                        DeskIconButton(
                          icon: action.icon,
                          tooltip: action.tooltip,
                          size: 28,
                          glyph: 16,
                          parked: !action.isEnabled,
                          onPressed: action.isEnabled ? action.onPressed : null,
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
