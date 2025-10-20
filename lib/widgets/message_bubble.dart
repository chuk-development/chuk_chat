// lib/widgets/message_bubble.dart
import 'package:flutter/material.dart';

class MessageBubbleAction {
  const MessageBubbleAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isEnabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool isEnabled;
}

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isUser,
    this.maxWidth,
    this.actions = const <MessageBubbleAction>[],
    this.reasoning,
  });

  final String message;
  final bool
  isUser; // true for bot, false for user in voice mode (to match image)
  // In regular chat, true for user, false for AI.
  final double? maxWidth; // Neue optionale Eigenschaft für responsive Breite
  final List<MessageBubbleAction> actions;
  final String? reasoning;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _isReasoningExpanded = false;

  bool get _hasReasoning =>
      widget.reasoning != null && widget.reasoning!.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    // Determine alignment based on whether it's a user message or not.
    // Historically voice mode inverted this flag, so we keep compatibility.
    final bool alignRight =
        widget.isUser; // User messages (regular chat) go right, bot messages go left.

    // Get colors from theme
    final Color accentColor = Theme.of(context).colorScheme.primary;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).iconTheme.color!;

    // Nutze die übergebene maxWidth, falls vorhanden, ansonsten den Standardwert von 70% der Bildschirmbreite
    final double effectiveMaxWidth =
        widget.maxWidth ?? MediaQuery.of(context).size.width * 0.7;

    final bool hasActions = widget.actions.isNotEmpty;

    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxWidth: effectiveMaxWidth,
        ), // Verwendet effectiveMaxWidth
        decoration: BoxDecoration(
          color: alignRight ? accentColor.withValues(alpha: .8) : bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: iconFgColor.withValues(alpha: .3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: alignRight
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (_hasReasoning) ...[
              _buildReasoningToggle(iconFgColor, alignRight),
              const SizedBox(height: 4),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: _isReasoningExpanded
                    ? Padding(
                        key: const ValueKey('reasoning-expanded'),
                        padding: const EdgeInsets.only(bottom: 6),
                        child: SelectableText(
                          widget.reasoning!,
                          style: TextStyle(
                            color: iconFgColor.withValues(alpha: 0.85),
                            fontStyle: FontStyle.italic,
                            height: 1.35,
                          ),
                        ),
                      )
                    : const SizedBox(
                        key: ValueKey('reasoning-collapsed'),
                      ),
              ),
            ],
            SelectableText(widget.message, style: TextStyle(color: iconFgColor)),
            if (hasActions) ...[
              const SizedBox(height: 8),
              Wrap(
                alignment: alignRight ? WrapAlignment.end : WrapAlignment.start,
                spacing: 4,
                runSpacing: 4,
                children: widget.actions
                    .map(
                      (action) => IconButton(
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        tooltip: action.tooltip,
                        onPressed: action.isEnabled ? action.onPressed : null,
                        icon: Icon(action.icon, color: iconFgColor),
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildReasoningToggle(Color iconFgColor, bool alignRight) {
    final bool expanded = _isReasoningExpanded;
    final IconData icon =
        expanded ? Icons.expand_less : Icons.expand_more;
    final String label = expanded ? 'Hide reasoning' : 'Show reasoning';

    return InkWell(
      onTap: () {
        setState(() => _isReasoningExpanded = !expanded);
      },
      child: Row(
        mainAxisAlignment:
            alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: iconFgColor.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: iconFgColor.withValues(alpha: 0.7),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
