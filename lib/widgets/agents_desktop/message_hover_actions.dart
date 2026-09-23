/// Message actions on hover (docs/DESIGN.md §14.4): copy, retry, branch and
/// the rest sit in a small toolbar at the top right of the message while the
/// pointer is on it — not as a permanent pill under every message.
///
/// The keyboard and a screen reader reach them too: the message is a focus
/// stop, the toolbar shows while the message or one of its buttons has the
/// focus (Tab moves on into the buttons), and every enabled action is also a
/// custom semantics action on the message.
///
/// Desktop only: the Agents desktop transcript wraps each row in this; the
/// phone keeps its long-press menu and never builds one.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

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

  /// The message or one of its toolbar buttons has the focus.
  bool _focusWithin = false;

  /// The message itself has the focus and the keyboard is driving: the ring.
  bool _focusRing = false;

  final FocusNode _node = FocusNode(debugLabel: 'message-row');

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocus);
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    _node.removeListener(_onFocus);
    _node.dispose();
    super.dispose();
  }

  void _onHighlightMode(FocusHighlightMode _) => _onFocus();

  void _onFocus() {
    if (!mounted) return;
    final bool within = _node.hasFocus;
    final bool ring =
        _node.hasPrimaryFocus &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (within == _focusWithin && ring == _focusRing) return;
    setState(() {
      _focusWithin = within;
      _focusRing = ring;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.actions.isEmpty) return widget.child;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool show = _hovered || _focusWithin;
    return Semantics(
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        for (final MessageBubbleAction action in widget.actions)
          if (action.isEnabled)
            CustomSemanticsAction(label: action.tooltip): action.onPressed,
      },
      child: Focus(
        focusNode: _node,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              widget.child,
              if (_focusRing)
                Positioned.fill(
                  key: const ValueKey<String>('message-focus-ring'),
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: scheme.primary.withValues(alpha: 0.7),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              // Kept in the tree while the focus is inside it, so Tab can
              // walk from the message into its buttons.
              if (show)
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
                          for (final MessageBubbleAction action
                              in widget.actions)
                            DeskIconButton(
                              icon: action.icon,
                              tooltip: action.tooltip,
                              size: 28,
                              glyph: 16,
                              parked: !action.isEnabled,
                              onPressed: action.isEnabled
                                  ? action.onPressed
                                  : null,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
